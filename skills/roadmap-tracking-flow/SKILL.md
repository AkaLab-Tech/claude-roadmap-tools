---
name: roadmap-tracking-flow
description: Consult this skill whenever the current repository's root contains all three of `ROADMAP.md`, `IN_PROGRESS.md` and `HISTORY.md`, OR a `.roadmap.json` config file (any backend), OR the user explicitly mentions task tracking, the roadmap, what is in progress, history of completed work, or moving a task between those files. The skill defines the flow `ROADMAP → IN_PROGRESS → HISTORY`, the pre-merge tracking rule, how to propose the next task, and the entry format for each file. It supports two backends — `files` (markdown at the repo root, single-file or indexed layout) and `linear` (Linear issues via the Linear MCP, optional offline mirror with auto-refresh on activation). Skip for read-only chats that do not touch tracking, for trivial edits, and once the user has declined applying it earlier in the session.
---

# roadmap-tracking-flow skill

Keep the user's task tracking consistent across the three top-level files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) and, when the repo uses it, the `roadmap/` folder of per-task files.

## Backend protocol

The skill's operations follow the abstract `RoadmapBackend` contract documented in [`docs/RoadmapBackend.md`](../../docs/RoadmapBackend.md). That document is the canonical spec — operation signatures, error names, atomicity rules, and per-backend notes — and is shared with every other piece of the plugin (the slash commands and any future backend).

This `SKILL.md` expresses both backends shipped with the plugin:

- **`FilesBackend`** — applied when `.roadmap.json` is absent or declares `backend: "files"` (the default). Markdown files at the repo root, single-file or indexed layout. See [Operations (`FilesBackend`)](#operations-filesbackend) below.
- **`LinearBackend`** — applied when `.roadmap.json` declares `backend: "linear"`. Linear issues backed by the Linear MCP server. See [Operations (`LinearBackend`)](#operations-linearbackend) below.

Future backends (`GitHubIssuesBackend`, `JiraBackend`, `TrelloBackend`) extend this file in the same pattern, each adding its own `## Operations (<BackendName>)` sibling section with per-operation notes.

The plugin is 100% markdown — the contract is a specification the skill follows, not a runtime API. The function-style signatures in the Operations sections below describe inputs, outputs, and behaviour, not callable code.

## When this skill applies

Activate the rules below when **any** of:

1. The current repository's root contains **all three** of `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, **or**
2. The current repository's root contains a `.roadmap.json` config file (any backend — `files` or `linear`), **or**
3. The user explicitly references the flow ("move this to HISTORY", "what is in progress?", "next task from the roadmap", "log this PR").

Predicate 2 covers the `backend: "linear"` + `offlineMirror: false` setup where there are no local tracking files at the repo root: the `.roadmap.json` is the only on-disk evidence of the flow. Without predicate 2, the skill would silently not activate for those repos until the user explicitly invoked the flow.

Otherwise, leave it alone — do not invent these files, do not invent `.roadmap.json`, and do not suggest the flow on repos that do not use it. If the user asks to set the flow up on a repo that does not yet have it, point them at `/create-roadmap`.

## Layouts: single-file vs indexed

Detect which layout the repo uses **before** acting:

- **Indexed layout** — a `roadmap/` folder exists at the repo root and contains files named `TASK_NNN_<slug>.md`. `ROADMAP.md` is an index of titles linking to those files; the long descriptions live inside each `TASK_NNN_<slug>.md`. `IN_PROGRESS.md` links to the same task files; progress updates are written **inside** the task file, not in `IN_PROGRESS.md`.
- **Single-file layout** — no `roadmap/` folder. `ROADMAP.md` itself contains both titles and full descriptions. `IN_PROGRESS.md` holds the active task content directly (checkboxes, sub-stories, etc.).

When unsure, run a quick check: list the repo root and look for `roadmap/`. Pick the layout that matches; do not mix them in the same operation.

## Activation: detecting the active backend

On every skill activation, run the detection in this order **before** answering the user's prompt:

1. **Look for `.roadmap.json`** at the repo root.
   - **Present**: read it. The `backend` field decides which Operations section to follow:
     - `backend: "files"` → use [Operations (`FilesBackend`)](#operations-filesbackend).
     - `backend: "linear"` → use [Operations (`LinearBackend`)](#operations-linearbackend).
     The `offlineMirror` field decides whether the [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) applies — only meaningful for `linear` (and any future remote backend), ignored for `files`.
   - **Absent**: source backend is implicitly `files` (the default). Use [Operations (`FilesBackend`)](#operations-filesbackend).

2. **For `files` backend**, detect the layout (single-file vs indexed) as documented in [Layouts: single-file vs indexed](#layouts-single-file-vs-indexed) above. The chosen layout governs how each operation reads and writes files.

3. **For `linear` backend with `offlineMirror: true`**, run the mirror auto-refresh (see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below) **before** answering the user's prompt. The refresh is part of activation, not a separate step the user invokes.

4. **For `linear` backend with `offlineMirror: false`**, no local files exist (the repo is Linear-only). All operations route through `LinearBackend` and execute against Linear in real-time. No refresh step is needed because there is no mirror to refresh.

Once the backend (and, for files, the layout) is decided, the rest of this skill — [the flow](#the-flow), [the pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing), the chosen Operations section, and the format conventions — applies as documented. The detection above is the routing layer; everything else is the per-backend implementation.

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

(For remote backends like `LinearBackend`, `isAvailable()` performs a cheap connectivity check without triggering OAuth or any mutating call. See [Operations (`LinearBackend`)](#operations-linearbackend) below for the concrete implementation, and the matching section in [`docs/RoadmapBackend.md`](../../docs/RoadmapBackend.md) for the contract.)

## Operations (`LinearBackend`)

This section describes how each of the six contract operations is performed when the repo's `.roadmap.json` declares `backend: "linear"`. The structure mirrors [Operations (`FilesBackend`)](#operations-filesbackend) above; only the per-operation implementation differs.

Activation prerequisites (assumed by every operation below):

- `.roadmap.json` exists at the repo root with `backend: "linear"`, a valid `linear.teamId`, and a `linear.stateMap` matching the team's Linear workflow (defaults: `roadmap: ["Backlog", "Todo"]`, `inProgress: ["In Progress"]`, `history: ["Done", "Cancelled"]`).
- A Linear MCP server is registered with Claude Code, reachable at `https://mcp.linear.app/mcp`. The canonical install command is documented in [TASK_001 — Linear backend specifics](../../roadmap/TASK_001_multi-backend-linear-first.md#linear-backend-specifics). `/create-roadmap` installs it automatically the first time a user picks `backend: "linear"`.
- The user has authorized the Linear MCP via OAuth at least once in this Claude Code installation. The first-ever Linear MCP call triggers a browser-based OAuth flow; subsequent calls reuse the cached token until it expires.

Tool naming convention: the operations below refer to Linear MCP tools by their **role** (issue-list, issue-fetch, issue-create, issue-update, comment-create) rather than by exact tool names, which depend on the Linear MCP version. The skill resolves the right tool at call time by inspecting the MCP's tool list.

> **⚠ Naming convention for `stateMap` lookups.** Bucket arguments in operations use snake_case (`roadmap`, `in_progress`, `history`). The matching JSON keys in `linear.stateMap` use camelCase (`roadmap`, `inProgress`, `history`). Every `linear.stateMap[bucket]` lookup in the operations below is **implicitly translated**: bucket `in_progress` → key `inProgress`, others unchanged. When writing `.roadmap.json` (via `/create-roadmap` or `/migrate-roadmap`), use the camelCase keys. See [`docs/RoadmapBackend.md` — Buckets](../../docs/RoadmapBackend.md) for the full convention.

### `listTasks(bucket)` — propose / inspect the buckets

Resolve the Linear workflow states for the requested bucket via `linear.stateMap[bucket]` in `.roadmap.json` (e.g. `["Backlog", "Todo"]` for `"roadmap"` under the defaults; for `in_progress`, look up `linear.stateMap.inProgress` per the naming convention above).

Call the Linear MCP issue-list tool with:

- `team`: from `linear.teamId`.
- state filter: any state in `linear.stateMap[bucket]`.

Order: Linear's default sort (priority then created date) unless the user has a custom team view configured — defer to it where the MCP exposes views.

For each returned issue, build a task element with:

- `id`: Linear's identifier (e.g. `ENG-123`).
- `title`: from the issue title.
- `current_bucket`: derived by reverse-mapping the issue's state through `linear.stateMap`.

When `offlineMirror: true`, the same operation **also** refreshes the local mirror by rewriting the corresponding markdown file from Linear's authoritative state (see [TASK_001 — Offline mirror semantics](../../roadmap/TASK_001_multi-backend-linear-first.md#offline-mirror-semantics) for the rules).

**Errors** — empty bucket returns an empty list (not an error). MCP unavailable → throw `backend-unavailable`.

### `getTask(id)` — fetch a single task's full content

Call the Linear MCP issue-fetch tool with the canonical `id`.

Return:

- `id`: the Linear identifier.
- `title`: from the issue.
- `body`: from the issue description (markdown supported by Linear).
- `current_bucket`: reverse-mapped from the issue's state.
- `comments`: the issue's comment thread (each with author + body).

**Where progress notes live (LinearBackend equivalent of `## Status`)**: there is no `## Status` section in Linear; the equivalent is the **issue's comment thread**. When asked "what's in progress?", surface the most recent meaningful progress comment as the active state, the same way `FilesBackend` surfaces the latest `## Status` entry.

**Errors** — throw `task-not-found` if Linear has no issue with that id, or it belongs to a different team than `linear.teamId`. MCP unavailable → throw `backend-unavailable`.

### `addTask(task)` — adding a new task to the `ROADMAP`

When the user asks to add a new task:

1. **Confirm scope and priority.** If the user has not specified a priority (Linear's Urgent / High / Medium / Low / No-priority), ask. When migrating from a `FilesBackend` repo, map markdown sections (`High Priority`, `Medium Priority`, `Low Priority`) to Linear priorities accordingly.
2. **Call the Linear MCP issue-create tool** with:
   - `team`: from `linear.teamId`.
   - `title`: from the task.
   - `description`: from the task body.
   - `state`: the **first** element of `linear.stateMap.roadmap` (e.g. `Backlog` under the defaults).
   - `priority`: from the task input (or `0` / No priority if absent).
3. **Capture the assigned Linear id** (e.g. `ENG-123`) and return it.

When `offlineMirror: true`, the same operation **also** writes a new `roadmap/TASK_NNN_<slug>.md` locally with frontmatter `backend: linear` + `backendId: <Linear id>`, plus an index entry in `ROADMAP.md`. The `TASK_NNN` is allocated locally (next sequential, following the `FilesBackend` numbering rule), independent of the Linear id.

**Side effects** — task exists on Linear in `linear.stateMap.roadmap[0]` (typically `Backlog`).

**Errors** — invalid input (missing title) → throw. Team permission denied by Linear → throw, surfacing the Linear error verbatim.

### `moveTask(id, fromBucket, toBucket)` — moving a task between buckets

> **Moving INTO `history` is forbidden in this operation.** Use `appendHistoryEntry` instead — history transitions require PR metadata and an atomic comment-append.

1. **Pre-check the source bucket.** Call the Linear MCP issue-fetch tool. Verify that the issue's current state is in `linear.stateMap[fromBucket]`. If not, throw `task-not-in-from-bucket`.
2. **Resolve target state.** Use the **first** element of `linear.stateMap[toBucket]`.
3. **Call the Linear MCP issue-update tool** to set `state` to the resolved target. Linear's state-change is atomic per call — that satisfies the contract's atomicity requirement.

When `offlineMirror: true`, the same operation **also** rewrites the corresponding link entries in the local `ROADMAP.md` ↔ `IN_PROGRESS.md` (mirroring the `FilesBackend` behaviour). Both the local file edits and the Linear API call must succeed together; if the Linear call fails, no local files are touched. The local `roadmap/TASK_NNN_*.md` is **not** moved or renamed (indexed-layout rule).

**Errors** — `task-not-in-from-bucket`, `move-into-history-forbidden` (when `toBucket == "history"`), `backend-unavailable`.

### `appendHistoryEntry(id, prMetadata)` — logging completed work

The **load-bearing atomic operation** that enforces the [pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing) above. Three steps in sequence:

1. **Pre-check.** Verify the issue's current state is in `linear.stateMap.in_progress`. If not, throw `task-not-in-progress`.
2. **Update state to history.** Call the Linear MCP issue-update tool to set the issue's state to the first element of `linear.stateMap.history` (e.g. `Done`).
3. **Append PR metadata as a Linear comment.** Call the Linear MCP comment-create tool with the comment body formatted as:

   ```markdown
   ## Closed by PR [#<N>](<full GitHub URL>)

   <1–2 sentence framing of why this PR existed.>

   **Delivered:**
   - <bullet>
   - <bullet>

   **Tests:** <one line on the validation done>

   **Follow-ups:** (optional)
   - <bullet>
   ```

**Atomicity caveat** — Linear's state-change is atomic per API call, but comment-create is a separate call. If the state change succeeds but the comment append fails:

- **Do not** revert the state change — the task is genuinely done; reverting would be misleading.
- **Retry** the comment append once. If it still fails, surface a clear warning to the user with the exact comment text so they can post it manually, and continue.

This caveat is documented in [`docs/RoadmapBackend.md` — Atomicity and rollback](../../docs/RoadmapBackend.md).

When `offlineMirror: true`, the same operation **also** removes the link entry from local `IN_PROGRESS.md` and appends an entry to local `HISTORY.md` mirroring the comment content (entry shape: same as `FilesBackend.appendHistoryEntry` — `### <Title> — YYYY-MM-DD` / `**PR:** [#N](url)` / `**Delivered:** …` / `**Tests:** …` / `**Follow-ups:** …`). Local edits bundle with the Linear calls in the same logical transaction.

**Errors** — `task-not-in-progress`, missing required `prMetadata` fields, `backend-unavailable`.

### `isAvailable()` — connectivity check

For `LinearBackend`, `isAvailable()` returns `true` iff a Linear MCP server is registered in Claude Code. The check is:

1. Inspect the MCP server list (the skill calls Claude Code's MCP listing — equivalent to what `claude mcp list` would show).
2. Look for an MCP whose host matches `mcp.linear.app` (or whose name matches a known registration name like `linear-server`).
3. Return `true` if found; `false` otherwise.

**Must not** issue any Linear API call — doing so would trigger the OAuth browser flow on first-ever invocation, violating the contract's "no side effects" rule for `isAvailable`.

When `isAvailable()` returns `false`, the skill surfaces this error to the user (and `/create-roadmap` re-suggests the install command). Operations that depend on the Linear MCP throw `backend-unavailable` when called against an unavailable backend. For the activation-time behaviour when `isAvailable()` returns `false`, see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below — the skill falls back gracefully to the existing local snapshot rather than refusing to activate.

## Mirror auto-refresh on activation

Applies when **all** of:

- `.roadmap.json` exists at the repo root.
- It declares `backend: "linear"` (or, in the future, any other remote backend).
- It declares `offlineMirror: true`.

On every skill activation in such a repo, the skill performs a mirror refresh **before** answering the user's prompt. This implements decision 8 in [TASK_001](../../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions): "automatic on skill activation; no background polling, no explicit `/refresh-roadmap` command in v1."

### Refresh procedure

1. **Pre-check the backend's availability**: call `LinearBackend.isAvailable()` (see [`isAvailable()` under Operations (LinearBackend)](#isavailable--connectivity-check)).

2. **If `isAvailable()` returns `false`** (Linear MCP not registered or not reachable):
   - **Do not** attempt the refresh.
   - **Fall back to the existing local snapshot**: the user can still read `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and every `roadmap/TASK_NNN_*.md` as they were at the last successful refresh.
   - **Surface a clear warning** at the start of the answer, naming the snapshot age and the install / reconnection command. Example:
     > _Linear MCP unreachable; showing the mirror snapshot from 2026-05-22 14:31. To restore: re-run `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` (or check your network). Read-only operations work against the snapshot; write operations (`addTask`, `moveTask`, `appendHistoryEntry`) will throw `backend-unavailable` until the MCP is restored._
   - Activation continues — the skill is still useful for reading the snapshot.

3. **If `isAvailable()` returns `true`**, perform the refresh in this order:
   1. Call `listTasks("roadmap")` against `LinearBackend`. Regenerate the index lines in `ROADMAP.md`, plus any new `roadmap/TASK_NNN_*.md` files for issues that do not yet have a local file.
   2. Call `listTasks("in_progress")`. Regenerate the link lines in `IN_PROGRESS.md`.
   3. Call `listTasks("history")` **scoped by the history window** (see below). Regenerate the matching `HISTORY.md` entries.

4. **Coherence rules** (per decision 3 in [TASK_001](../../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions)):
   - Match local task files to remote issues by `backendId` in YAML frontmatter, **not** by title or slug.
   - New remote issues that have no matching local file get new `roadmap/TASK_NNN_*.md` files with the next sequential `TASK_NNN` (per the [Numbering convention](../../commands/create-roadmap.md) — never reuse numbers).
   - Local task files whose `backendId` no longer exists remotely are **flagged in the warning** at the start of the answer (`TASK_042 — backendId ENG-123 no longer exists in Linear; left in place for review`) but **not auto-deleted**. The user decides whether to remove them.

5. **Safe failure mode**:
   - If any individual `listTasks` call fails mid-refresh, **stop that bucket's refresh** and keep the previous local snapshot for that bucket intact. Do **not** half-write the bucket's files.
   - Refresh of other buckets that already completed successfully stays applied.
   - Surface the partial-refresh state clearly: name the buckets that succeeded vs failed, and the underlying error per failed bucket.

### History window

The `history` bucket can grow large over a long-running Linear project. To bound the cost of refreshing it on every activation, `listTasks("history")` is **scoped by default to the last 90 days** of issues whose state is in `linear.stateMap.history`. Users override this via `linear.historyWindow` in `.roadmap.json`:

```json
{
  "backend": "linear",
  "offlineMirror": true,
  "linear": {
    "teamId": "<team-uuid>",
    "historyWindow": "90d",
    "stateMap": {
      "roadmap": ["Backlog", "Todo"],
      "inProgress": ["In Progress"],
      "history": ["Done", "Cancelled"]
    }
  }
}
```

Supported `historyWindow` values:

| Value | Meaning |
| :--- | :--- |
| `"90d"` (default if omitted) | Issues whose completion date is within the last 90 days. |
| `"30d"`, `"180d"`, `"365d"`, etc. | Same shape, different window. |
| `"50"` (any bare integer) | The last N entries by completion date, regardless of age. |
| `"all"` | No limit; pull every history issue. Use only on small projects — refresh cost scales with project age. |

Issues older than the window remain accessible via `getTask(id)` on-demand — `getTask` always fetches a single issue from Linear regardless of window. The window only bounds the refresh's `listTasks("history")` call.

### What is **not** refreshed

- **Local task file bodies that were modified by the refresh's own previous run**: this is fine, the next refresh will overwrite them again. The contract is read-only mirror; user-edited content is not preserved (decision 7).
- **`.roadmap.json`**: never modified by the refresh. The config is the user's choice, not Linear's.
- **`.gitignore`**: never modified by the refresh. `.gitignore` is touched only at `/create-roadmap` / `/migrate-roadmap` time.

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
