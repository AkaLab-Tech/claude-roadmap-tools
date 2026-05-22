---
name: roadmap-tracking-flow
description: Consult this skill whenever the current repository's root contains all three of `ROADMAP.md`, `IN_PROGRESS.md` and `HISTORY.md`, or when the user explicitly mentions task tracking, the roadmap, what is in progress, history of completed work, or moving a task between those files. The skill defines the flow `ROADMAP → IN_PROGRESS → HISTORY`, the pre-merge tracking rule, how to propose the next task, and the entry format for each file. It supports two layouts: single-file (everything in `ROADMAP.md`) and indexed (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task). Skip for read-only chats that do not touch tracking, for trivial edits, and once the user has declined applying it earlier in the session.
---

# roadmap-tracking-flow skill

Keep the user's task tracking consistent across the three top-level files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) and, when the repo uses it, the `roadmap/` folder of per-task files.

## Backend protocol

The skill's operations follow the abstract `RoadmapBackend` contract documented in [`docs/RoadmapBackend.md`](../../docs/RoadmapBackend.md). That document is the canonical spec — operation signatures, error names, atomicity rules, and per-backend notes — and is shared with every other piece of the plugin (the slash commands and any future backend).

This `SKILL.md` expresses the **`FilesBackend`** implementation of the contract: how each operation is performed when the repo's `.roadmap.json` is absent or has `backend: "files"` (the default). The `LinearBackend` instructions are added in a follow-up PR; future backends (`GitHubIssuesBackend`, `JiraBackend`, `TrelloBackend`) extend this file in the same pattern, each adding its per-operation notes.

The plugin is 100% markdown — the contract is a specification the skill follows, not a runtime API. The function-style signatures in [Operations](#operations-filesbackend) below describe inputs, outputs, and behaviour, not callable code.

## When this skill applies

Activate the rules below when **either**:

1. The current repository's root contains **all three** of `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, **or**
2. The user explicitly references the flow ("move this to HISTORY", "what is in progress?", "next task from the roadmap", "log this PR").

Otherwise, leave it alone — do not invent these files, and do not suggest the flow on repos that do not use it. If the user asks to set the flow up on a repo that does not yet have it, point them at `/create-roadmap`.

## Layouts: single-file vs indexed

Detect which layout the repo uses **before** acting:

- **Indexed layout** — a `roadmap/` folder exists at the repo root and contains files named `TASK_NNN_<slug>.md`. `ROADMAP.md` is an index of titles linking to those files; the long descriptions live inside each `TASK_NNN_<slug>.md`. `IN_PROGRESS.md` links to the same task files; progress updates are written **inside** the task file, not in `IN_PROGRESS.md`.
- **Single-file layout** — no `roadmap/` folder. `ROADMAP.md` itself contains both titles and full descriptions. `IN_PROGRESS.md` holds the active task content directly (checkboxes, sub-stories, etc.).

When unsure, run a quick check: list the repo root and look for `roadmap/`. Pick the layout that matches; do not mix them in the same operation.

## The flow

```
ROADMAP.md  ──(start work)──▶  IN_PROGRESS.md  ──(merge PR)──▶  HISTORY.md
```

- A task moves to `IN_PROGRESS.md` only when work actually starts. Do not pre-stage tasks there "for later".
- A task is logged in `HISTORY.md` when its PR(s) are ready to merge. See the pre-merge rule below.
- `ROADMAP.md` is the backlog. It can hold ideas that may never ship; that is fine.

## Pre-merge tracking rule (load-bearing)

When a PR closes a tracked task, **the same PR** must contain both:

1. The removal of the task from `IN_PROGRESS.md`.
2. The new entry in `HISTORY.md` referencing that PR.

Never defer either step to a follow-up commit on the protected branch after merge. The user's flow treats `main` (or equivalent) as a place that should never carry orphan tracking commits.

If the PR is opened without the tracking updates, push them as additional commits to the **same branch** before requesting merge — not after.

## Operations (`FilesBackend`)

Each sub-section below implements one operation from the [`RoadmapBackend` contract](../../docs/RoadmapBackend.md) for the default `FilesBackend`. Cross-cutting concerns — layout detection, the bucket flow, the pre-merge tracking rule — are documented above; the sub-sections below assume that context.

### `listTasks(bucket)` — propose / inspect the buckets

Listing the contents of a bucket — used most often when the user asks "what's next?" or "what's in progress?".

When the user asks "what's next?" or equivalent:

1. **Read `IN_PROGRESS.md` first** (i.e. `listTasks("in_progress")`). If something is active there, surface it as the default — do not propose a fresh task while another is mid-flight unless the user explicitly wants to switch.
2. **Then read `ROADMAP.md`** (i.e. `listTasks("roadmap")`). Propose **1–3 candidates** with:
   - Title and a one-line summary.
   - The main tradeoff or risk (what makes it big/risky/blocking).
   - Any obvious dependencies between candidates.
3. **Ask before starting.** Do not move anything to `IN_PROGRESS.md` without the user's OK.

In **indexed layout**, follow each candidate's link to its `roadmap/TASK_NNN_<slug>.md` and call `getTask(id)` (next section) to enrich the proposal — do not summarize from the title alone.

For `listTasks("history")`, return entries newest first; the layout of `HISTORY.md` (grouped by `## YYYY-MM`) already provides the order.

**Returns**, per element: `id` (the `TASK_NNN`), title, and current bucket. In indexed layout, the body and the latest `## Status` note are available via `getTask(id)`.

**Errors**: empty bucket returns an empty list, not an error.

### `getTask(id)` — fetch a single task's full content

Used to retrieve a task's body, sub-tasks, and progress notes — both when proposing the next task and when reporting current state.

- **Indexed layout** — read `roadmap/TASK_NNN_<slug>.md` directly. The full body is there: the description paragraph, `## Goal`, `## Sub-tasks` (checkboxes), `## Notes`, and `## Status` (the progress log). When asked "what's in progress?" or similar, read the latest `## Status` entry to report current state — that is the source of truth for active-task progress, **not** `IN_PROGRESS.md` (which in indexed layout only holds the link).
- **Single-file layout** — extract the task block from the file the task currently lives in (`ROADMAP.md`, `IN_PROGRESS.md`, or `HISTORY.md`). The block is everything from the heading down to the next heading at the same or higher level.

**Returns**: `id`, title, body, current bucket, and (indexed only) the contents of `## Status`.

**Errors**: throw `task-not-found` if the id is unknown. In indexed layout, this means the matching `roadmap/TASK_NNN_*.md` is missing.

### `addTask(task)` — adding a new task to the `ROADMAP`

When the user asks to add a new task (or to "put X on the roadmap"):

1. **Confirm scope and priority.** If the user has not specified a priority section (`High`, `Medium`, `Low / Ideas`, or whatever sections the file uses), ask. Do not invent new sections without asking.
2. **Apply the layout-specific procedure below.**
3. **Do not touch `IN_PROGRESS.md` or `HISTORY.md`.** A new task starts in the `roadmap` bucket only. It moves to `in_progress` via `moveTask` when work actually begins.

**Returns**: the created task with its newly-assigned `id` (`TASK_NNN`).

**Side effects**: the task is now in the `roadmap` bucket.

#### Single-file layout

Append a new task block under the chosen priority section in `ROADMAP.md`. Match the structure already used by surrounding entries:

```markdown
### <Title>

Short framing of what the task is and why it matters.

- [ ] Sub-task 1
- [ ] Sub-task 2

**Acceptance:** what "done" looks like.
```

If sibling tasks use a richer template (e.g. they include "Design notes" or "Out of scope" subsections), match that. Consistency wins over the minimal template above.

#### Indexed layout

1. **Pick the next number.** List `roadmap/` and find the highest existing `TASK_NNN_*.md`. The new file gets `NNN + 1`, zero-padded to three digits. Numbers are never reused — even if older tasks were cancelled or are missing, do not fill gaps.
2. **Derive the slug.** Kebab-case, lowercase, ASCII only, derived from the title. Strip articles (`the`, `a`) and stop-words at the user's discretion. Keep it short — 3 to 6 words is a good target.
3. **Create `roadmap/TASK_NNN_<slug>.md`** using the standard task template:
   ```markdown
   # TASK_NNN — <Title>

   <Description paragraph: what this is and why it matters.>

   ## Goal

   What "done" looks like for this task.

   ## Sub-tasks

   - [ ] Step 1
   - [ ] Step 2

   ## Notes

   Design decisions, links to issues, anything worth keeping with the task.

   ## Status

   (Updated as the task progresses. While in `IN_PROGRESS.md`, log changes here, not in `IN_PROGRESS.md`.)
   ```
   Adapt the sub-headings to whatever fits the task. The `# TASK_NNN — <Title>` top heading is mandatory; everything else is a starting point.
4. **Add the index entry to `ROADMAP.md`** under the chosen priority section:
   ```markdown
   - [TASK_NNN — <Title>](roadmap/TASK_NNN_<slug>.md)
   ```
   Match whatever bullet style the existing entries use (some users add a one-line summary after the link; if so, do the same).
5. **Report what was created** so the user can review the diff before committing.

#### Common pitfalls to avoid

- Do not number tasks based on git history or epic boundaries — it is a strict global counter over `roadmap/`.
- Do not pre-stage a "scaffold" task file with no real description. If the user has not told you enough to fill the file, ask first.
- Do not move existing tasks around in `ROADMAP.md` while adding a new one. Append-only, unless the user asks for a reorganization.

### `moveTask(id, fromBucket, toBucket)` — moving a task between buckets

After the user confirms the next task, move it from `roadmap` to `in_progress`. Less commonly, a task can be moved back from `in_progress` to `roadmap` (if the user changes their mind about starting it).

> **Moving INTO `history` is forbidden in this operation.** History transitions are richer (require PR metadata) and atomic with the source-bucket removal — use the `appendHistoryEntry` operation below instead.

- **Single-file layout:** cut the task block out of the source bucket file and paste it into the destination bucket file under a clear heading. Keep checkboxes intact.
- **Indexed layout:** remove (or strike through) the line in the source bucket file's index and add a link to the same `roadmap/TASK_NNN_<slug>.md` from the destination bucket file. **Do not move or rename the task file.** Progress updates (checkbox flips, design decisions, follow-ups) go inside `roadmap/TASK_NNN_<slug>.md`. `IN_PROGRESS.md` only holds the link plus, optionally, a one-line status note.

**Atomicity** — the move is atomic: bundle both file edits (source bucket remove + destination bucket add) into a single change set so the diff reviews as one unit. If the user rejects mid-way, no files are left touched.

**Errors** — throw `task-not-in-from-bucket` if the task is not currently in `fromBucket`. Throw `move-into-history-forbidden` if `toBucket == "history"`.

### `appendHistoryEntry(id, prMetadata)` — logging completed work

The **load-bearing atomic operation** that enforces the [pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing) above. In one transaction:

1. Remove the task from `IN_PROGRESS.md` (the source bucket — typically `in_progress`).
2. Append a structured entry to `HISTORY.md`, newest first, grouped by `## YYYY-MM` (creating the month section if absent).

Entry shape:

```markdown
### <Title> — YYYY-MM-DD
**PR:** [#N](<full GitHub URL>)

<1–2 sentence framing of why this PR existed.>

**Delivered:**
- <bullet>
- <bullet>

**Tests:** <one line on the validation done>

**Follow-ups:** (optional)
- <bullet>
```

Conventions:

- Date is the day the PR was **opened or merged**, whichever the user prefers — match the existing entries in the file.
- The PR number is the actual one (open or merged is fine; the link works either way).
- Keep bullets concrete: name the file, function, or behavior that changed, not vague wins like "improved performance".
- "Follow-ups" is for items spawned by this PR that go back to `ROADMAP.md` (or `IN_PROGRESS.md` if the user wants them next). Cross-link them; do not leave them only in `HISTORY.md`.

In **indexed layout**, the `roadmap/TASK_NNN_<slug>.md` file is **kept as the source of truth** for what was delivered. The `HISTORY.md` entry should be a concise summary that links to both the PR and (optionally) the task file. **Do not delete the task file.**

**Atomicity** — both side effects (remove from `in_progress`, append to `history`) happen as a single change set. Half-completed history-append is not acceptable; if either side fails, both must be rolled back.

**Errors** — throw `task-not-in-progress` if the task is not currently in `in_progress`. Throw on missing required `prMetadata` fields.

### `isAvailable()` — connectivity check

For `FilesBackend`, `isAvailable()` is always `true` — the filesystem is the backend. Once the activation predicate in [When this skill applies](#when-this-skill-applies) matches, operations proceed unconditionally.

(For remote backends like `LinearBackend`, `isAvailable()` performs a cheap connectivity check without triggering OAuth or any mutating call. See the matching section in [`docs/RoadmapBackend.md`](../../docs/RoadmapBackend.md).)

## Format conventions

- All three files (and the `roadmap/` task files) are written in **English**, regardless of the chat language. Same rule the user applies to code, commits, and PR descriptions.
- Markdown only. No emojis unless the file already uses them.
- Use checkboxes (`- [ ]` / `- [x]`) inside `IN_PROGRESS.md` and inside `roadmap/TASK_NNN_<slug>.md` for sub-tasks. Do not add checkboxes inside `HISTORY.md` — entries there are immutable records, not work lists.
- Keep `ROADMAP.md` short in indexed layout. If it starts holding paragraphs again, suggest running `/migrate-roadmap` (or splitting the offending block into a new task file manually).

## When the layout needs to change

- Repo currently single-file but `ROADMAP.md` is becoming long / hard to scan: suggest `/migrate-roadmap` to switch to indexed.
- Repo currently indexed but the user wants to collapse back: do this manually — the migration command only runs forward (single-file → indexed). Do not invent a reverse migration; ask the user before touching it.

## Initialization

If the user asks to set up tracking on a repo that does not have these files yet, do not create them silently. Point them at the slash command:

> "Run `/create-roadmap` — it will ask whether you want single-file or indexed layout and create only the files that don't exist yet."

## Things this skill does NOT do

- Does not edit `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` without the user's request.
- Does not push tracking commits to a protected branch directly. Tracking updates ride on the same PR branch as the work they describe.
- Does not assume one layout — always detects first.
- Does not invent PR numbers. If the PR is not yet open, log the entry with a placeholder and ask the user to confirm the number once it exists, **before** the PR is merged.
