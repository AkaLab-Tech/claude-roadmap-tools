---
description: Migrate task tracking between backends or layouts. v1 supports `files (single-file) → files (indexed)` and `files (any layout) → linear` (Linear via MCP, with optional offline mirror). Other directions error out as "not yet implemented".
---

# /migrate-roadmap

Migrate this repo's task tracking from one backend (or layout) to another. v1 supports two directions:

1. **`files (single-file) → files (indexed)`** — convert a single-file layout to indexed (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task).
2. **`files (any layout) → linear`** — push every existing task to Linear via the Linear MCP, write `backend: linear` + `backendId: <linear-id>` into each local task file's frontmatter, persist `.roadmap.json`, and either keep the local files as an offline mirror or delete them.

Other directions error out with `not yet implemented` — see the [Direction matrix](#direction-matrix).

## Context

Run this only at the **root of the target repository**.

## Behavior

1. **Verify preconditions.**
   - `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` must all exist at the repo root. If any is missing, tell the user to run `/create-roadmap` first and stop.
   - **Determine the source backend** by reading `.roadmap.json` if present:
     - File present + `backend: "linear"` → source backend is `linear`. This command refuses to migrate **away from `linear`** in v1 (see [Direction matrix](#direction-matrix)). Stop with a clear message.
     - File present + `backend: "files"` (explicit) → source backend is `files`.
     - File absent → source backend is `files` (implicit default).
   - **Determine the source layout** (only meaningful for `files` source): if a `roadmap/` directory exists at the root, source layout is `indexed`; otherwise `single-file`.
   - If the working tree has uncommitted changes to any tracking file or to `.roadmap.json`, ask the user whether to proceed. A clean working tree makes the migration diff easier to review.

2. **Resolve target backend (and layout).** Either from `$ARGUMENTS` (`--to <files|linear>`) or via interactive prompt. For `--to files`, the target layout is `indexed` (single-file → single-file is a no-op; indexed → indexed is a no-op).

3. **Validate direction.** Look up [Direction matrix](#direction-matrix). If the resolved direction is not supported in v1, error out with a clear message naming source and target.

4. **Branch by direction.**
   - **`files (single-file) → files (indexed)`** → step 5a.
   - **`files (any layout) → linear`** → step 5b.

### 5a. `files (single-file) → files (indexed)` _(current behavior preserved)_

1. **Parse `ROADMAP.md` and propose the migration plan.**
   - Treat each `##` and `###` heading as a candidate task. Use judgement: skip section headers that are clearly category buckets (`## High Priority`, `## Medium Priority`, `## Low Priority / Ideas`, `## Backlog`, etc.). Confirm with the user if ambiguous.
   - For each real task, derive:
     - `NNN` — sequential, zero-padded to three digits, starting at `001`.
     - `<slug>` — kebab-case, lowercase, ASCII, derived from the heading.
     - The body — everything from the heading down to the next heading at the same or higher level.
2. **Also surface tasks living in `IN_PROGRESS.md`.** If `IN_PROGRESS.md` contains task blocks (not just the standard header / workflow note), include them in the plan as candidate task files too. Mark them clearly as "currently in progress" so they get linked from `IN_PROGRESS.md` after migration, not from `ROADMAP.md`. Number these continuing the same sequence — do not restart numbering between roadmap and in-progress entries.
3. **Show the user the full plan before writing anything**: a numbered list of the proposed task files with their slugs and a one-line summary each. Ask for confirmation. Let the user rename, merge, drop, or split entries before proceeding.
4. **Apply the migration after the user approves.**
   - Create `roadmap/` if it does not exist.
   - Write each `roadmap/TASK_NNN_<slug>.md` with the parsed body. Add a small header at the top of each file matching the indexed-layout task template:
     ```markdown
     # TASK_NNN — <Original heading>

     <body extracted from ROADMAP.md or IN_PROGRESS.md>
     ```
     Preserve original markdown structure (sub-headings, lists, checkboxes, code blocks).
   - Rewrite `ROADMAP.md` as an index: keep the priority section headings, replace each task block with a single bullet line linking to `roadmap/TASK_NNN_<slug>.md`. Keep tasks under the same priority section they were in.
   - Rewrite `IN_PROGRESS.md`: replace each migrated in-progress task block with a single link line to its `roadmap/TASK_NNN_<slug>.md`. Keep the workflow header and any prose that is not a task block.
   - **Do not touch `HISTORY.md`** — completed entries stay as records of what was delivered. They do not get task files retroactively in this direction.
5. Continue to step 6 (report).

### 5b. `files (any layout) → linear` _(new in v1)_

1. **Run the Linear setup procedure** — identical to steps 5b.1–5b.4 of [`/create-roadmap`](create-roadmap.md):
   - Detect / install the Linear MCP via the canonical `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` (with OAuth heads-up).
   - Call the MCP team-list tool (this is what triggers OAuth on first ever use); abort if OAuth fails or is cancelled.
   - Interactive team picker, or validate the `--team <key-or-uuid>` flag against the MCP team list.
   - Ask whether to enable the offline mirror, or honor `--mirror` / `--no-mirror`.

2. **Parse every task from the source repo.**
   - `ROADMAP.md` → bucket `roadmap`. Headings under any priority section.
   - `IN_PROGRESS.md` → bucket `in_progress`. Task blocks (single-file) or links (indexed).
   - `HISTORY.md` → bucket `history`. Each historical entry. Yes, history is migrated too — Linear gains a complete audit trail of past work (decided with the maintainer for v1).
   - If the source layout is **single-file**, build a virtual indexed view in memory: assign each task a sequential `TASK_NNN` in document order (`ROADMAP.md` first, then `IN_PROGRESS.md`, then `HISTORY.md`), starting at `001`. This ordering is deterministic so a failed-and-retried migration produces the same numbering.
   - If the source layout is **indexed**, use the existing `roadmap/TASK_NNN_*.md` files as task records for roadmap + in_progress entries, plus history entries from `HISTORY.md` (which have no task files in indexed layout — that's expected).

3. **Show the full migration plan.** List every task that will be pushed, grouped by target bucket (`history` / `in_progress` / `roadmap`). For each task, show its proposed Linear initial state from `linear.stateMap[<bucket>][0]`. If the user picked `mirror: false`, **also list the four local artefacts that will be deleted at the end of the migration**: `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`. The user sees this destructive consequence in the plan and confirms or aborts here — do not re-prompt at deletion time.

4. **Push tasks to Linear** one by one, in bucket order: `history` first, then `in_progress`, then `roadmap`. For each task:
   1. Call the Linear MCP issue-create tool with `team` = `linear.teamId`, `title`, `description` (= the task body), and `state` = `linear.stateMap[<bucket>][0]`.
   2. Capture the assigned Linear id (e.g. `ENG-123`).
   3. **Write the id back** to the local task file's YAML frontmatter as `backend: linear` + `backendId: <linear-id>`:
      - **Indexed source**: update the existing `roadmap/TASK_NNN_*.md` in place.
      - **Single-file source**: create a new `roadmap/TASK_NNN_<slug>.md` at this point with the extracted body and the frontmatter set. This is the in-flight layout flip — the local mirror becomes indexed even if the source was single-file.
      - **History entries with no task file** (any source layout that keeps history flat in `HISTORY.md`): no task file is created. The Linear issue is the record going forward.

5. **On partial failure** (an individual push fails partway through the list): **stop immediately**. Surface the error with two lists: (a) Linear ids already created (so the user can clean them up via Linear's UI if they want to retry from scratch); (b) tasks not yet pushed. **Do not write `.roadmap.json`. Do not delete any local files.** Refuse to retry the migration with `.roadmap.json` absent and some `backendId`s already written; tell the user to reconcile manually and re-run a clean migration. Auto-resume is out of scope for v1.

6. **All pushes succeeded.** Write `.roadmap.json` at the repo root using the [`.roadmap.json` template in `/create-roadmap`](create-roadmap.md), with `linear.teamId` from step 5b.1, `offlineMirror` from step 5b.1, and the v1 `linear.stateMap` defaults (users edit later if their team's workflow states differ). `.roadmap.json` presence is the **atomic checkpoint** of a successful migration — its existence at this path means every task is in Linear.

7. **Branch on `offlineMirror`.**
   - **`true`** (mirror on): keep all the local files (they are now the active mirror). The single-file → indexed flip is already done; the indexed task files are written with the `backendId` frontmatter. **If `.gitignore` exists at the repo root**, append `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` to it (idempotent — do not duplicate entries). If `.gitignore` does not exist, do nothing — the user may be working without git.
   - **`false`** (mirror off): delete the four local artefacts (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` recursive). This deletion was previewed in step 5b.3's migration plan and confirmed there — do not re-prompt. Do not modify `.gitignore`.

8. Continue to step 6 (report).

### 6. Report

- For `files (single-file) → files (indexed)`:
  - List every file created (`roadmap/TASK_NNN_*.md`) and every file modified (`ROADMAP.md`, `IN_PROGRESS.md`). `HISTORY.md` is unchanged.
  - Remind the user that progress updates from now on go inside `roadmap/TASK_NNN_<slug>.md`, not in `IN_PROGRESS.md`.
  - Suggest reviewing the diff before committing, ideally on a feature branch (use the `git-wt` skill if applicable).
- For `files → linear`:
  - List every Linear id created, grouped by bucket (`history` / `in_progress` / `roadmap`). Cite the Linear team + project so the user can navigate.
  - Note `.roadmap.json` was written.
  - **`mirror: true`** report:
    - Local files kept as mirror: `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`.
    - `.gitignore` lines appended (list each line, or note "all four entries already present").
  - **`mirror: false`** report:
    - Local files deleted: list `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/` (recursive).
  - Remind the user that the next Linear MCP call (e.g. the next time the skill answers "what's in progress?") may trigger an OAuth browser prompt if it has not already been authorized.

## Direction matrix

| Source → Target | Status | Notes |
| :--- | :--- | :--- |
| `files (single-file) → files (indexed)` | ✅ Supported | Step 5a. Current behavior preserved verbatim. |
| `files (single-file) → linear` | ✅ Supported | Step 5b. Auto-flips to indexed layout on the local side as part of the migration. |
| `files (indexed) → linear` | ✅ Supported | Step 5b. Existing `roadmap/TASK_NNN_*.md` files get `backendId` frontmatter written in place. |
| `linear → files` | ❌ Not yet implemented | Reverse migration is out of scope for v1. Run manually if needed: read every Linear issue, write each into a `roadmap/TASK_NNN_*.md` (or back into single-file `ROADMAP.md`), then delete `.roadmap.json`. |
| `linear → linear` | ❌ No-op | Detected at step 1; refuse with a clear message. Use `/create-roadmap` on a fresh repo if you want to switch teams. |
| `files (indexed) → files (single-file)` | ❌ Not yet implemented | The skill's rule is one-way (single-file → indexed); reverse is unsupported. |

When the user invokes an unsupported direction, error out with a message naming source and target and pointing at this table. **Do not silently fall back to a different behavior.**

## Templates

The `.roadmap.json` template used by step 5b.6 is documented in [`/create-roadmap`](create-roadmap.md). This command reuses it verbatim so there is exactly one source of truth for the config schema.

## Numbering convention

Same as `/create-roadmap`:

- `TASK_NNN_<slug>.md` with `NNN` zero-padded to three digits.
- Numbers assigned sequentially and never reused.
- After migration, the next new task picks the number after the highest existing `TASK_NNN_*.md`.

For `files (single-file) → linear`, the `TASK_NNN` assignment is computed once at the start of step 5b.2 in document order (`ROADMAP.md` first, then `IN_PROGRESS.md`, then `HISTORY.md`). This ordering is deterministic so the same source state always produces the same numbering — important when the user re-runs a clean migration after a partial-failure cleanup.

## Safety rules

- **Never rewrite or overwrite an existing `roadmap/TASK_NNN_*.md` file** during a `files (single-file) → files (indexed)` migration. If the `roadmap/` directory exists at all when running 5a, abort at step 1 (preconditions). This is the legacy single-direction rule preserved.
- **Never delete content** during migration. If a heading is ambiguous, prefer creating an over-specified task file (the user can collapse it later) over silently dropping the text.
- The migration must be reviewable as a single git diff (5a) or a single coherent change set (5b). Do not split it across multiple commits before the user has approved the plan.
- **For `files → linear`, never write `.roadmap.json` until every Linear push has succeeded.** `.roadmap.json` presence is the atomic checkpoint of a successful migration.
- **For `files → linear` with `mirror: false`, the deletion of the four local artefacts is destructive.** It must be previewed in step 5b.3's migration plan and confirmed there — do not re-prompt at deletion time, because the user already saw and approved it.
- If the user wants to abort mid-plan (before approving in step 5a.3 or 5b.3), do not leave partial state — no created Linear issues, no written task files, no modified `.roadmap.json`.

## Arguments

`$ARGUMENTS` is parsed as a space-separated list of bare values and/or flags:

- `--to <files|linear>` — selects the target backend. If omitted, defaults to `files (indexed)` for backward compatibility with the legacy single-direction behavior of this command.
- `--mirror` / `--no-mirror` — sets the offline mirror toggle. **`--to linear` only.** With `--to files`, error out.
- `--team <key-or-uuid>` — pre-selects the Linear team without going through the interactive picker. **`--to linear` only.** Validated via MCP team-list either way.

Conflicting flags (e.g. `--to files --mirror`, or `--team` with `--to files`) error out with a clear message naming the conflict. Interactive prompting only fires for choices not already in `$ARGUMENTS`.

Examples:

- `/migrate-roadmap` — legacy behavior: `files (single-file) → files (indexed)`, fully interactive for ambiguous headings only.
- `/migrate-roadmap --to linear` — fully interactive linear migration: prompts for team and mirror.
- `/migrate-roadmap --to linear --team ENG --no-mirror` — non-interactive linear migration with auto-delete of local files at the end.
