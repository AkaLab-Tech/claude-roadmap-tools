---
description: Migrate task tracking between backends or layouts. v1 supports `files (single-file) → files (indexed)`, `files (any layout) → linear` (Linear via MCP), `files (any layout) → github-project` (GitHub Projects v2 via the GitHub MCP), and `github-project → files (indexed)` (reverse reconstruction, step 5d), each with an optional offline mirror where applicable. Other directions error out as "not yet implemented".
---

# /migrate-roadmap

Migrate this repo's task tracking from one backend (or layout) to another. v1 supports four directions:

1. **`files (single-file) → files (indexed)`** — convert a single-file layout to indexed (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task).
2. **`files (any layout) → linear`** — push every existing task to Linear via the Linear MCP, write `backend: linear` + `backendId: <linear-id>` into each local task file's frontmatter, persist `.roadmap.json`, and either keep the local files as an offline mirror or delete them.
3. **`files (any layout) → github-project`** — push every existing task to a GitHub Project (Projects v2) via the hosted GitHub MCP, write `backend: github-project` + `backendId: <item-id>` into each local task file's frontmatter, persist `.roadmap.json`, and either keep the local files as an offline mirror or delete them.
4. **`github-project → files (indexed)`** — reconstruct the indexed `files` layout from the live GitHub Project via step 5d (the backend-agnostic reverse engine), strip `backend`/`backendId` from every task file, and remove `.roadmap.json` to flip authority to local files. Read-only against the remote.

Other directions error out with `not yet implemented` — see the [Direction matrix](#direction-matrix).

## Context

Run this only at the **root of the target repository**.

## Behavior

1. **Verify preconditions.**
   - `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` must all exist at the repo root. If any is missing, tell the user to run `/create-roadmap` first and stop.
   - **Determine the source backend** by reading `.roadmap.json` if present:
     - File present + `backend: "linear"` → source backend is `linear`. This command refuses to migrate **away from `linear`** in v1 (see [Direction matrix](#direction-matrix)). Stop with a clear message.
     - File present + `backend: "github-project"` → source backend is `github-project`. A `--to files` target is **supported** (routes to step 5d, the reverse engine). The other directions away from `github-project` still refuse: `github-project → github-project` is a no-op, and `github-project → linear` is a cross-remote migration out of scope for v1 (route via `files` — see [Direction matrix](#direction-matrix)). For those, stop with a clear message.
     - File present + `backend: "files"` (explicit) → source backend is `files`.
     - File absent → source backend is `files` (implicit default).
   - **Determine the source layout** (only meaningful for `files` source): if a `roadmap/` directory exists at the root, source layout is `indexed`; otherwise `single-file`.
   - **Detect orphan partial-migration state.** When `.roadmap.json` is **absent** AND `roadmap/` exists, scan every `roadmap/TASK_NNN_*.md` for a `backendId` field in YAML frontmatter. If any file has `backendId` set, this is an orphan state left over from a previously-failed `files → linear` or `files → github-project` migration (see steps 5b.5 and 5c.5). **Refuse to proceed.** Surface the list of orphan task files with their `backendId`s and tell the user to reconcile manually before re-running: either delete the orphan task files (and, optionally, the matching issues/items in the target backend to avoid duplicates), or strip the `backendId` frontmatter to re-include those tasks in a fresh migration. This precondition guards against creating duplicate items on retry.
   - If the working tree has uncommitted changes to any tracking file or to `.roadmap.json`, ask the user whether to proceed. A clean working tree makes the migration diff easier to review.

2. **Resolve target backend (and layout).** Either from `$ARGUMENTS` (`--to <files|linear|github-project>`) or via interactive prompt. For `--to files`, the target layout is `indexed` (single-file → single-file is a no-op; indexed → indexed is a no-op). When the **source** backend is remote (`github-project`; `linear` once #21c lands) and `--to files` is given, the resolved direction is `<remote> → files (indexed)` → step 5d, not the 5a single-file→indexed path. `--to files` therefore accepts a remote source, not only the legacy `files` single→indexed case.

3. **Validate direction.** Look up [Direction matrix](#direction-matrix). If the resolved direction is not supported in v1, error out with a clear message naming source and target.

4. **Branch by direction.**
   - **`files (single-file) → files (indexed)`** → step 5a.
   - **`files (any layout) → linear`** → step 5b.
   - **`files (any layout) → github-project`** → step 5c.
   - **`linear → files` or `github-project → files`** → step 5d.

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
   - **Detect existing MCP first (idempotency)**. Inspect the MCP server list (`claude mcp list` or equivalent). Look for a server whose host matches `mcp.linear.app` **or** whose name matches `linear-server`. **If found, skip the install entirely** — do not re-run `claude mcp add`, even though it would be technically idempotent. The CLI may print "already registered" but the user sees noise; worse, some Claude Code versions surface a "tools not visible yet; please restart" instruction even when the MCP is healthy. The correct behaviour when the MCP is detected is: **do nothing here and proceed to the next bullet**.
   - **Only if NOT detected**: install via `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` and tell the user a browser window will open for OAuth on the next Linear call.
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

6. **All pushes succeeded.** Write `.roadmap.json` at the repo root using the **exact** template below — same shape as `/create-roadmap`'s output, so a repo created with `/create-roadmap --backend linear` and a repo migrated with `/migrate-roadmap --to linear` end up with identical config. **Do not omit `historyWindow`**. **Do not trim the `stateMap` defaults** to only the state the user happens to be using — ship all defaults so the skill's mirror auto-refresh handles every state Linear may return in the future. **JSON field-naming convention**: bucket names in operation arguments use snake_case (`in_progress`); the JSON config field uses camelCase (`inProgress`). The mapping is fixed: bucket `in_progress` ↔ field `linear.stateMap.inProgress`. Same convention as `/create-roadmap`.

   ```json
   {
     "backend": "linear",
     "offlineMirror": <true|false from step 5b.1>,
     "linear": {
       "teamId": "<linear.teamId from step 5b.1>",
       "historyWindow": "90d",
       "stateMap": {
         "roadmap": ["Backlog", "Todo"],
         "inProgress": ["In Progress"],
         "history": ["Done", "Cancelled"]
       }
     }
   }
   ```

   `.roadmap.json` presence is the **atomic checkpoint** of a successful migration — its existence at this path means every task is in Linear.

7. **Branch on `offlineMirror`.**
   - **`true`** (mirror on): keep all the local files (they are now the active mirror). The single-file → indexed flip is already done; the indexed task files are written with the `backendId` frontmatter. **If `.gitignore` exists at the repo root**, append `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` to it (idempotent — do not duplicate entries). If `.gitignore` does not exist, do nothing — the user may be working without git.
   - **`false`** (mirror off): delete the four local artefacts (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` recursive). This deletion was previewed in step 5b.3's migration plan and confirmed there — do not re-prompt. Do not modify `.gitignore`.

8. Continue to step 6 (report).

### 5c. `files (any layout) → github-project` _(new in v1)_

1. **Run the GitHub MCP setup procedure** — identical to steps 5c.1–5c.4 of [`/create-roadmap`](create-roadmap.md) (MCP detect-first, install only if absent, list projects, pick project, ask for offline mirror). Do not duplicate that prose here; follow it exactly by reference.

2. **Parse every task from the source repo** — identical to step 5b.2 above: `ROADMAP.md` → bucket `roadmap`; `IN_PROGRESS.md` → bucket `in_progress`; `HISTORY.md` → bucket `history`. If source layout is single-file, build a virtual indexed view in memory (deterministic `TASK_NNN` assignment in document order). If indexed, use existing `roadmap/TASK_NNN_*.md` files.

3. **Show the full migration plan.** List every task that will be pushed, grouped by target bucket, with the proposed initial Status from `githubProject.stateMap[<bucket>][0]`. If the user picked `mirror: false`, also list the four local artefacts that will be deleted at the end. The user confirms or aborts here — do not re-prompt at deletion time.

4. **Push each task to the GitHub Project** one by one, in bucket order (`history` first, then `in_progress`, then `roadmap`). For each task:
   1. Resolve the project's field metadata (field id + option ids for the Status single-select) via the GitHub MCP `projects_get` role — do this once before the loop, not per item.
   2. Create a draft item via the GitHub MCP `projects_write` role (title + body).
   3. Set Status to `githubProject.stateMap[<bucket>][0]` using the resolved option id.
   4. Capture the assigned item node id (`PVTI_...`).
   5. **Write the id back** to the local task file's YAML frontmatter as `backend: github-project` + `backendId: <PVTI_...>`:
      - **Indexed source**: update the existing `roadmap/TASK_NNN_*.md` in place.
      - **Single-file source**: create a new `roadmap/TASK_NNN_<slug>.md` at this point (the in-flight layout flip).
      - **History entries with no task file**: no task file is created; the Project item is the record going forward.
   6. **Never use `gh` CLI** for this backend — always the GitHub MCP.

5. **On partial failure** (an individual push fails partway through): **stop immediately**. Surface the error with two lists: (a) item node ids already created; (b) tasks not yet pushed. **Do not write `.roadmap.json`. Do not delete any local files.** Tell the user to reconcile the orphan items manually before re-running. Same behavior as step 5b.5.

6. **All pushes succeeded.** Write `.roadmap.json` at the repo root using the **github-project template** documented in [`/create-roadmap`](create-roadmap.md#roadmapjson--github-project-backend) — reused verbatim (one source of truth). `.roadmap.json` presence is the **atomic checkpoint** of a successful migration.

7. **Branch on `offlineMirror`** — identical to step 5b.7: mirror true → keep local files + idempotent `.gitignore` append; mirror false → delete the four local artefacts (previewed in the plan, no re-prompt).

8. Continue to step 6 (report).

### 5d. `<remote backend> → files (indexed)` _(reverse engine; reachable once a direction row is ✅)_

Reconstructs the local indexed-`files` layout from the active remote backend (`linear` or `github-project`) and flips authority to local files by removing `.roadmap.json`. This is the full-reconstruct-and-flip-authority variant of the read procedure documented in the [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md#mirror-auto-refresh-on-activation) section of SKILL.md — generalizing it from "refresh a read-only mirror" into "full reconstruct + flip authority to local files". All backend-specific operations are expressed as calls to the **active backend's** contract operations; no Linear-specific or GitHub-Project-specific API calls appear here.

1. **Precondition + availability gate.**
   - Require `.roadmap.json` to be present and to declare a remote backend (`backend: "linear"` or `backend: "github-project"`). If not, stop with a clear message.
   - Call the active backend's `isAvailable()`. If `false`, **refuse** — the remote source is unreachable; writing nothing is safer than a partial reconstruction. Tell the user which MCP is missing.
   - Require a clean working tree (no uncommitted changes to any tracking file or `.roadmap.json`). If not clean, ask the user whether to proceed — a clean tree makes the migration diff reviewable.

2. **Pull all three buckets.**
   - Call `listTasks("history")`, `listTasks("in_progress")`, `listTasks("roadmap")` against the active backend.
   - For each task returned, call `getTask(id)` to enrich with body, `type`, `estimate`, the `TASK_NNN` handle (derived from local mirror frontmatter if present, or allocated freshly in the order: `history` first, then `in_progress`, then `roadmap`), `Ready`, `blocked_by`, and `backendId`.
   - **Use `"all"` history semantics for `listTasks("history")`**: override the 90-day default mirror window — a migration must be lossless. See the [History window table](../skills/roadmap-tracking-flow/SKILL.md#history-window) in SKILL.md for the `"all"` value.
   - `TASK_NNN` assignment (for items without a matching local mirror file): sequential, deterministic, in document order across buckets (`history` first, then `in_progress`, then `roadmap`). This ordering guarantees a failed-and-retried migration produces the same numbering.

3. **Show the full reconstruction plan before writing anything.**
   - List every task, grouped by destination: `HISTORY.md` entries, `IN_PROGRESS.md` link(s), and the `roadmap/TASK_NNN_<slug>.md` files to be created with their proposed filenames.
   - State **explicitly** that `.roadmap.json` will be **removed** as part of this migration.
   - Note explicitly that `backend`/`backendId` frontmatter will be **stripped** from every written task file (see step 5d.4).
   - Confirm or abort here. Zero side effects until the user confirms — no files written, no remote state mutated.

4. **Reconstruct the indexed `files` layout atomically** (write all task files and index files as a single change set after the user confirms):
   - **Per task → `roadmap/TASK_NNN_<slug>.md`**: write the task body and any frontmatter fields (`type`, `estimate`). **Strip `backend` and `backendId` from the written frontmatter.** The strip is the authority-flip: these fields name the remote as the canonical source; once written to local files without them, local files become the canonical source, and there is no pointer back to the remote.
   - **`ROADMAP.md`** — rebuild as a §5 index: map each remote item's Status → priority section via the active backend's `stateMap` **reverse-lookup** (e.g. a Linear issue in state `Backlog` → `linear.stateMap.roadmap` match → `## Backlog` or `## Medium Priority` section, as appropriate); add `[ready]` marker to the index line if the item's `Ready` field/label is set; add `blocked_by:` metadata if the item's `blocked_by` field is non-empty.
   - **`IN_PROGRESS.md`** — write one index link line per `in_progress` bucket task.
   - **`HISTORY.md`** — write entries grouped `## YYYY-MM`, newest first, matching the [`appendHistoryEntry` entry shape](../skills/roadmap-tracking-flow/SKILL.md#appendhistoryentryid-prmetadata--logging-completed-work).

5. **Remove `.roadmap.json` as the inverse atomic checkpoint.** Its **absence** signals that local files are now authoritative — the inverse of the forward migration's `.roadmap.json` presence convention (5b.6 / 5c.6). State this inversion explicitly when reporting. The remote source is left entirely untouched.

6. **Partial-failure guard.**
   - On any `listTasks` / `getTask` failure in step 5d.2, or any file-write failure in step 5d.4: **stop immediately**. Write nothing destructive. Leave `.roadmap.json` in place. **Never touch or mutate the remote source** (this direction is read-only against the remote). Report per-bucket success/failure with the underlying error.
   - The reverse path being read-only against the remote is an inherent safety advantage over the forward 5b/5c paths, which create remote items. If the reconstruction fails partway, the user can simply re-run — the remote source is unmodified.
   - **Lossiness note**: reconstruction is lossless for the §5 task model (title, body, bucket, `type`, `estimate`, `Ready`, `blocked_by`). Remote-only metadata — backend-native ids (`ENG-123`, `PVTI_...`), assignees, and comment threads — is inherently dropped. Document this in the report.

7. Continue to step 6 (report).

#### Fidelity (`files → github-project → files` round-trip)

The following describes what survives and what is lost when authority is flipped back to local files (extending the lossiness note in step 5d.6).

**Preserved (round-trips losslessly):**
- Task title and body.
- `type` and `estimate` frontmatter fields.
- The `TASK_NNN` human handle (keyed by the `#id`-style field on the Project item, or reallocated deterministically if absent).
- The bucket (via the Project's Status field → `stateMap` reverse-lookup).
- `[ready]` marker (via the Project's Ready field).
- `blocked_by` (via the Project's `blocked_by` text field).
- History entries (reconstructed from the Project's `history` bucket items).

**Inherently lossy (no `files` representation — dropped on the authority flip, per the approved §5-scoped lossiness decision):**
- The `PVTI_...` Project item node id — dropped when `backendId` is stripped; this is the backend-native id for the `github-project` backend.
- Project-native fields not present in the §5 task model (custom fields, labels, assignees, milestones, etc.).
- GitHub assignees and comment threads.

**`stateMap`-multi-value caveat:** when a bucket maps to multiple Status values (e.g. `roadmap: ["Backlog","Todo"]`), a task in `Todo` and one in `Backlog` both reverse-map to the same `roadmap` bucket — the intra-bucket sub-distinction is lost.

**`<slug>` is cosmetic:** the round-trip is keyed on `TASK_NNN` + content, not the exact filename slug. A regenerated slug that differs from the original is not a fidelity loss.

### 6. Report

- For `files (single-file) → files (indexed)`:
  - List every file created (`roadmap/TASK_NNN_*.md`) and every file modified (`ROADMAP.md`, `IN_PROGRESS.md`). `HISTORY.md` is unchanged.
  - Remind the user that progress updates from now on go inside `roadmap/TASK_NNN_<slug>.md`, not in `IN_PROGRESS.md`.
  - Suggest reviewing the diff before committing, ideally on a feature branch (use the `git-wt` skill if applicable).
- For `files → linear`:
  - List every Linear id created, grouped by bucket (`history` / `in_progress` / `roadmap`). Cite the Linear team + project so the user can navigate.
  - Note `.roadmap.json` was written.
  - **`mirror: true`** report: local files kept as mirror; `.gitignore` lines appended (or note "all four entries already present").
  - **`mirror: false`** report: local files deleted: `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` (recursive).
  - Remind the user that the next Linear MCP call may trigger an OAuth browser prompt if it has not already been authorized.
- For `files → github-project`:
  - List every item node id (`PVTI_...`) created, grouped by bucket. Cite the GitHub Project owner + number so the user can navigate to it.
  - Note `.roadmap.json` was written.
  - **`mirror: true`** report: local files kept as mirror; `.gitignore` lines appended (or note "all four entries already present").
  - **`mirror: false`** report: local files deleted: `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` (recursive).
- For `<remote backend> → files (indexed)`:
  - List every `roadmap/TASK_NNN_<slug>.md` created, plus the rebuilt index files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`).
  - Note that `.roadmap.json` was **removed** and local files are now authoritative.
  - Note the remote source was left entirely untouched (read-only against remote).
  - Call out explicitly what was dropped (remote-only metadata: backend-native ids, assignees, comment threads) — see step 5d.6 lossiness note. For the `github-project` backend, the dropped backend-native ids are the `PVTI_...` Project item node ids.

## Direction matrix

| Source → Target | Status | Notes |
| :--- | :--- | :--- |
| `files (single-file) → files (indexed)` | ✅ Supported | Step 5a. Current behavior preserved verbatim. |
| `files (single-file) → linear` | ✅ Supported | Step 5b. Auto-flips to indexed layout on the local side as part of the migration. |
| `files (indexed) → linear` | ✅ Supported | Step 5b. Existing `roadmap/TASK_NNN_*.md` files get `backendId` frontmatter written in place. |
| `files (single-file) → github-project` | ✅ Supported | Step 5c. Auto-flips to indexed layout on the local side as part of the migration. |
| `files (indexed) → github-project` | ✅ Supported | Step 5c. Existing `roadmap/TASK_NNN_*.md` files get `backendId` frontmatter written in place. |
| `linear → files` | ❌ Not yet implemented | Engine present at step 5d; not yet routed (direction row flipped by task #21b). |
| `linear → linear` | ❌ No-op | Detected at step 1; refuse with a clear message. Use `/create-roadmap` on a fresh repo if you want to switch teams. |
| `github-project → files` | ✅ Supported | Step 5d (the backend-agnostic reverse engine). Reconstructs the indexed `files` layout from the Project, strips `backend`/`backendId`, and removes `.roadmap.json` to flip authority to local files. Read-only against the remote. |
| `github-project → github-project` | ❌ No-op | Detected at step 1; refuse with a clear message. |
| `linear ↔ github-project` | ❌ Not yet implemented | Cross-remote migration is out of scope for v1; do NOT automate it. The supported path is to **route via `files`**: `github-project → files` (step 5d), then `files → linear` (step 5b). Same in reverse for `linear → github-project` once `linear → files` lands (#21c). |
| `files (indexed) → files (single-file)` | ❌ Not yet implemented | The skill's rule is one-way (single-file → indexed); reverse is unsupported. |

When the user invokes an unsupported direction, error out with a message naming source and target and pointing at this table. **Do not silently fall back to a different behavior.**

## Templates

The `.roadmap.json` templates used by steps 5b.6 and 5c.6 are documented in [`/create-roadmap`](create-roadmap.md) (the linear backend template and the github-project backend template respectively). This command reuses them verbatim so there is exactly one source of truth for both config schemas.

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
- **For `files → linear` and `files → github-project`, never write `.roadmap.json` until every push has succeeded.** `.roadmap.json` presence is the atomic checkpoint of a successful migration.
- **For `files → linear` or `files → github-project` with `mirror: false`, the deletion of the four local artefacts is destructive.** It must be previewed in the step 3 migration plan and confirmed there — do not re-prompt at deletion time, because the user already saw and approved it.
- If the user wants to abort mid-plan (before approving in step 5a.3, 5b.3, or 5c.3), do not leave partial state — no created issues/items, no written task files, no modified `.roadmap.json`.
- **The `<remote backend> → files` reverse path (step 5d) is read-only against the remote.** No Project item (or Linear issue) is created, updated, or deleted; the remote source is left entirely untouched. If the reconstruction fails partway through, `.roadmap.json` is left in place and the user can simply re-run — there is no remote cleanup required.

## Arguments

`$ARGUMENTS` is parsed as a space-separated list of bare values and/or flags:

- `--to <files|linear|github-project>` — selects the target backend. If omitted, defaults to `files (indexed)` for backward compatibility with the legacy single-direction behavior of this command.
- `--mirror` / `--no-mirror` — sets the offline mirror toggle. **`--to linear` and `--to github-project` only.** With `--to files`, error out.
- `--team <key-or-uuid>` — pre-selects the Linear team without going through the interactive picker. **`--to linear` only.** Validated via MCP team-list either way. Error out if combined with `--to github-project`.
- `--project <owner/number-or-id>` — pre-selects the GitHub Project. **`--to github-project` only.** Accepts `<owner>/<number>` (e.g. `acme/7`) or a bare Project node id. Validated against the user's Projects list via the GitHub MCP. Error out if combined with `--to files` or `--to linear`.

Conflicting flags (e.g. `--to files --mirror`, `--team` with `--to files`, `--project acme/7 --to linear`) error out with a clear message naming the conflict. Interactive prompting only fires for choices not already in `$ARGUMENTS`.

Examples:

- `/migrate-roadmap` — legacy behavior: `files (single-file) → files (indexed)`, fully interactive for ambiguous headings only.
- `/migrate-roadmap --to linear` — fully interactive linear migration: prompts for team and mirror.
- `/migrate-roadmap --to linear --team ENG --no-mirror` — non-interactive linear migration with auto-delete of local files at the end.
- `/migrate-roadmap --to github-project --project acme/7 --no-mirror` — non-interactive github-project migration targeting project `acme/7`, with auto-delete of local files at the end.
- `/migrate-roadmap --to files` (run inside a `github-project`-backed repo) — reverse reconstruction via step 5d: pulls all tasks from the GitHub Project, rebuilds the indexed `files` layout, and removes `.roadmap.json` to flip authority to local files.
