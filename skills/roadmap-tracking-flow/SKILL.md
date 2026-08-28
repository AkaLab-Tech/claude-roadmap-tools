---
name: roadmap-tracking-flow
description: Consult this skill whenever the current repository's root contains all three of `ROADMAP.md`, `IN_PROGRESS.md` and `HISTORY.md`, OR a `.roadmap.json` config file (any backend), OR the user explicitly mentions task tracking, the roadmap, what is in progress, history of completed work, or moving a task between those files. The skill defines the flow `ROADMAP → IN_PROGRESS → HISTORY`, the pre-merge tracking rule, how to propose the next task, and the entry format for each file. It supports four backends — `files` (markdown at the repo root, single-file or indexed layout), `linear` (Linear issues via the Linear MCP, optional offline mirror with auto-refresh on activation), `github-project` (GitHub Projects v2 via the hosted GitHub MCP, optional offline mirror), and `github-issues` (one GitHub Issue per task via the `gh` CLI, optional offline mirror). Skip for read-only chats that do not touch tracking, for trivial edits, and once the user has declined applying it earlier in the session.
---

# roadmap-tracking-flow skill

Keep the user's task tracking consistent across the three top-level files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) and, when the repo uses it, the `roadmap/` folder of per-task files.

## Backend protocol

The skill's operations follow the abstract `RoadmapBackend` contract documented in [`docs/RoadmapBackend.md`](../../docs/RoadmapBackend.md). That document is the canonical spec — operation signatures, error names, atomicity rules, and per-backend notes — and is shared with every other piece of the plugin (the slash commands and any future backend).

This `SKILL.md` expresses four backends shipped with the plugin:

- **`FilesBackend`** — applied when `.roadmap.json` is absent or declares `backend: "files"` (the default). Markdown files at the repo root, single-file or indexed layout. See [Operations (`FilesBackend`)](#operations-filesbackend) below.
- **`LinearBackend`** — applied when `.roadmap.json` declares `backend: "linear"`. Linear issues backed by the Linear MCP server. See [Operations (`LinearBackend`)](#operations-linearbackend) below.
- **`GitHubProjectBackend`** — applied when `.roadmap.json` declares `backend: "github-project"`. GitHub Projects v2 items backed by the hosted GitHub MCP. See [Operations (`GitHubProjectBackend`)](#operations-githubprojectbackend) below.
- **`GitHubIssuesBackend`** — applied when `.roadmap.json` declares `backend: "github-issues"`. One GitHub Issue per task, driven via the `gh` CLI (not the GitHub MCP). See [Operations (`GitHubIssuesBackend`)](#operations-githubissuesbackend) below.

Future backends (`JiraBackend`, `TrelloBackend`) extend this file in the same pattern, each adding its own `## Operations (<BackendName>)` sibling section with per-operation notes.

The plugin is 100% markdown — the contract is a specification the skill follows, not a runtime API. The function-style signatures in the Operations sections below describe inputs, outputs, and behaviour, not callable code.

## When this skill applies

Activate the rules below when **any** of:

1. The current repository's root contains **all three** of `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, **or**
2. The current repository's root contains a `.roadmap.json` config file (any backend — `files`, `linear`, `github-project`, or `github-issues`), **or**
3. The user explicitly references the flow ("move this to HISTORY", "what is in progress?", "next task from the roadmap", "log this PR").

Predicate 2 covers the `backend: "linear"`, `backend: "github-project"`, or `backend: "github-issues"` + `offlineMirror: false` setup where there are no local tracking files at the repo root: the `.roadmap.json` is the only on-disk evidence of the flow. Without predicate 2, the skill would silently not activate for those repos until the user explicitly invoked the flow.

Otherwise — none of the predicates match — leave the repo alone. Do not invent these files, do not invent `.roadmap.json`, and do not suggest the flow on repos that do not use it.

**Special case — predicate 3 fires without predicates 1 or 2.** The user mentioned the flow ("what's the next task of the roadmap?", "move this to HISTORY", etc.) but the repo has neither the three tracking files nor a `.roadmap.json` at its root. The skill is being consulted, but the repo is not set up. The correct response is to state this clearly and point the user at `/create-roadmap` to initialize it. **Do not** silently substitute another markdown file in the repo (e.g. `REFACTORING_OPPORTUNITIES.md`, `NOTES.md`, `TODO.md`, project-specific planning docs) by extracting priorities from it as if it were the roadmap — the user asked about *this* tracking flow, and if it is not set up the answer is to set it up, not to invent one from adjacent files. Only deviate from this if the user explicitly insists on reading a substitute file as a one-off ("look at NOTES.md as if it were the roadmap"); in that case make clear it is the user's choice to bypass the convention, not the skill's prescription.

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
     - `backend: "github-project"` → use [Operations (`GitHubProjectBackend`)](#operations-githubprojectbackend).
     - `backend: "github-issues"` → use [Operations (`GitHubIssuesBackend`)](#operations-githubissuesbackend).
     The `offlineMirror` field decides whether the [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) applies — meaningful for any remote backend (`linear`, `github-project`, `github-issues`), ignored for `files`.
   - **Absent**: source backend is implicitly `files` (the default). Use [Operations (`FilesBackend`)](#operations-filesbackend).

2. **For `files` backend**, detect the layout (single-file vs indexed) as documented in [Layouts: single-file vs indexed](#layouts-single-file-vs-indexed) above. The chosen layout governs how each operation reads and writes files.

3. **For any remote backend (`linear`, `github-project`, or `github-issues`) with `offlineMirror: true`**, consider the mirror auto-refresh (see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below) **before** answering the user's prompt. The refresh is part of activation, not a separate step the user invokes — but it is **TTL-gated**: when the existing snapshot is younger than `mirrorTTL` (default one hour), activation proceeds against it and no board read happens at all. Refreshing unconditionally on every activation is what this gate replaces.

4. **For any remote backend (`linear`, `github-project`, or `github-issues`) with `offlineMirror: false`**, no local files exist (the repo is remote-only). All operations route through the appropriate backend and execute against the remote in real-time. No refresh step is needed because there is no mirror to refresh.

Once the backend (and, for files, the layout) is decided, the rest of this skill — [the flow](#the-flow), [the pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing), the chosen Operations section, and the format conventions — applies as documented. The detection above is the routing layer; everything else is the per-backend implementation.

## Offline mirror writes are local-only (`LinearBackend` / `GitHubProjectBackend` / `GitHubIssuesBackend`)

For a remote backend (`linear`, `github-project`, or `github-issues`), the remote issue/item **is** the source of truth — for the task itself **and** for its plan (`setPlan`/`getPlan`, fenced by the `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` delimiters in the issue/item body). With `offlineMirror: true`, every write operation below (`addTask`, `moveTask`, `appendHistoryEntry`, `setReady`, `setPlan`) *also* writes a local file — `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/TASK_NNN_*.md`, or `.plan/<id>.md` — as a read convenience. **None of these local writes may ever be committed, tracked in git, or ride a PR.** They exist only so the operator (and other tools) can read the current state without a network call; the remote call is what actually persists anything.

Enforcement, set up once by `/create-roadmap` or `/migrate-roadmap` and never via the committed `.gitignore`:

- All five local-mirror paths — `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`, `.plan/` — go in **`.git/info/exclude`** (local to the checkout, itself never committed), not `.gitignore`. `.gitignore` is repo content that ships to every clone; these paths are not repo content.
- If any of them are already git-tracked (e.g. a repo that adopted a remote backend after already committing `.plan/<id>.md` under a `files` backend, or before this convention existed), `git rm --cached` them once (files stay on disk) so the exclude entries take effect, then let that removal ride its own PR — this is a one-time untracking, not an ongoing pattern.
- A session that finds itself about to `git add` / commit / open a PR for any of these five paths on a remote-backend repo has hit this bug, not a legitimate tracking update — stop and fix the exclude setup instead of committing.

This invariant is why the "[Pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing)" and "Tracking updates ride on the same PR branch" (see [Things this skill does NOT do](#things-this-skill-does-not-do)) apply to the `FilesBackend` only — for `linear`/`github-project`/`github-issues` there is no tracking file to bundle onto the work's PR; the state change already landed via the MCP call (or, for `github-issues`, the `gh` call).

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

### `setReady(id, ready)` — set/clear the readiness marker

The marker is the literal `[ready]` token in the task's ROADMAP entry. This formalizes what `/atelier:plan-task` edits inline today.

- **Single-file layout** — the token is placed immediately after the `- [ ]` checkbox on the task's heading line in `ROADMAP.md`.
- **Indexed layout** — the index link line in `ROADMAP.md` (the `- [TASK_NNN — <Title>](roadmap/...)` line). The `[ready]` token is placed immediately after the checkbox if the line carries one, or immediately after the leading `- ` bullet marker (before the link) if it does not.

`setReady(id,true)` inserts `[ready]`; `setReady(id,false)` removes it. Idempotent — already-set or already-clear is a no-op success. Single in-file edit.

**Errors** — throw `task-not-found` if the id has no ROADMAP entry.

### `setPlan(id, markdown)` / `getPlan(id)` — store or retrieve the task plan

The plan for a task lives in `.plan/<id>.md`, keyed by the **numeric task id** (e.g. `.plan/6.md` for `TASK_006`). No delimiter markers are used in `FilesBackend` — the file is the plan content verbatim.

- **`setPlan(id, markdown)`** — write (or overwrite) `.plan/<id>.md` with the given markdown content.
- **`getPlan(id)`** — read `.plan/<id>.md` and return its contents. Missing file → returns empty (no plan; not an error).

**Errors** — throw `task-not-found` if the task has no ROADMAP entry. Missing `.plan/<id>.md` is not an error for `getPlan`.

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

**Exhaust pagination.** The issue-list tool returns results page by page (cursor-based, `pageInfo.hasNextPage` / `endCursor` or the MCP's equivalent paging fields); its default page size does not guarantee every matching issue in one call. Keep calling issue-list with the next cursor until `hasNextPage` is `false`, then union all pages before building task elements — stopping after the first page silently truncates the bucket.

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

When `offlineMirror: true`, the same operation **also** writes a new `roadmap/TASK_NNN_<slug>.md` locally with frontmatter `backend: linear` + `backendId: <Linear id>`, plus an index entry in `ROADMAP.md`. The `TASK_NNN` is allocated locally (next sequential, following the `FilesBackend` numbering rule), independent of the Linear id. Local-only — see [Offline mirror writes are local-only](#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend); never commit these writes.

**Side effects** — task exists on Linear in `linear.stateMap.roadmap[0]` (typically `Backlog`).

**Errors** — invalid input (missing title) → throw. Team permission denied by Linear → throw, surfacing the Linear error verbatim.

### `moveTask(id, fromBucket, toBucket)` — moving a task between buckets

> **Moving INTO `history` is forbidden in this operation.** Use `appendHistoryEntry` instead — history transitions require PR metadata and an atomic comment-append.

1. **Pre-check the source bucket.** Call the Linear MCP issue-fetch tool. Verify that the issue's current state is in `linear.stateMap[fromBucket]`. If not, throw `task-not-in-from-bucket`.
2. **Resolve target state.** Use the **first** element of `linear.stateMap[toBucket]`.
3. **Call the Linear MCP issue-update tool** to set `state` to the resolved target. Linear's state-change is atomic per call — that satisfies the contract's atomicity requirement.

When `offlineMirror: true`, the same operation **also** rewrites the corresponding link entries in the local `ROADMAP.md` ↔ `IN_PROGRESS.md` (mirroring the `FilesBackend` behaviour). Both the local file edits and the Linear API call must succeed together; if the Linear call fails, no local files are touched. The local `roadmap/TASK_NNN_*.md` is **not** moved or renamed (indexed-layout rule). Local-only — never commit these writes.

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

When `offlineMirror: true`, the same operation **also** removes the link entry from local `IN_PROGRESS.md` and appends an entry to local `HISTORY.md` mirroring the comment content (entry shape: same as `FilesBackend.appendHistoryEntry` — `### <Title> — YYYY-MM-DD` / `**PR:** [#N](url)` / `**Delivered:** …` / `**Tests:** …` / `**Follow-ups:** …`). Local edits bundle with the Linear calls in the same logical transaction. Local-only — never commit these writes.

**Errors** — `task-not-in-progress`, missing required `prMetadata` fields, `backend-unavailable`.

### `setReady(id, ready)` — set/clear the readiness label

Readiness is represented as a dedicated **`Ready` label** on the Linear issue. The label name is the literal string `Ready`.

1. Resolve the `Ready` label by name via the Linear MCP. If it does not exist, create it (the same way the backend handles other label/state lookups).
2. `setReady(id,true)` adds the `Ready` label to the issue via the Linear MCP issue-update (label add) role. `setReady(id,false)` removes it via the issue-update (label remove) role.

Both calls are idempotent — adding an already-present label or removing an already-absent label is a no-op success at the Linear API level.

When `offlineMirror: true`, mirror the `[ready]` token into the local `ROADMAP.md` entry (bundle with the Linear call), parallel to how the other write ops mirror. Local-only — never commit this write.

**Errors** — `task-not-found`, `backend-unavailable`.

### `setPlan(id, markdown)` / `getPlan(id)` — store or retrieve the task plan

The plan lives in the issue description, fenced by `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` delimiters. See [`docs/RoadmapBackend.md` — `setPlan`](../../docs/RoadmapBackend.md) for the canonical delimiter semantics (missing → empty, duplicate → first wins).

- **`setPlan(id, markdown)`** — fetch the current description via issue-fetch; rewrite the content of the first delimiter pair (or append a fresh delimited section if absent); call issue-update. When `offlineMirror: true`, also write `.plan/<id>.md` locally (bundled with the Linear call), parallel to how `setReady` mirrors the `[ready]` token. Local-only, same as every other offline-mirror write — never commit `.plan/<id>.md` for this backend.
- **`getPlan(id)`** — fetch the issue description via issue-fetch and extract the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` pair. No markers → returns empty.

**Errors** — `task-not-found`, `backend-unavailable`.

### `isAvailable()` — connectivity check

For `LinearBackend`, `isAvailable()` returns `true` iff a Linear MCP server is registered in Claude Code. The check is:

1. Inspect the MCP server list (the skill calls Claude Code's MCP listing — equivalent to what `claude mcp list` would show).
2. Look for an MCP whose host matches `mcp.linear.app` (or whose name matches a known registration name like `linear-server`).
3. Return `true` if found; `false` otherwise.

**Must not** issue any Linear API call — doing so would trigger the OAuth browser flow on first-ever invocation, violating the contract's "no side effects" rule for `isAvailable`.

When `isAvailable()` returns `false`, the skill surfaces this error to the user (and `/create-roadmap` re-suggests the install command). Operations that depend on the Linear MCP throw `backend-unavailable` when called against an unavailable backend. For the activation-time behaviour when `isAvailable()` returns `false`, see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below — the skill falls back gracefully to the existing local snapshot rather than refusing to activate.

## Operations (`GitHubProjectBackend`)

This section describes how each of the six contract operations is performed when the repo's `.roadmap.json` declares `backend: "github-project"`. The structure mirrors [Operations (`FilesBackend`)](#operations-filesbackend) and [Operations (`LinearBackend`)](#operations-linearbackend) above; only the per-operation implementation differs.

Activation prerequisites (assumed by every operation below):

- `.roadmap.json` exists at the repo root with `backend: "github-project"`, a project/owner selector (`githubProject.owner` plus either `githubProject.projectNumber` or the Project node id), and a `githubProject.stateMap` (defaults: `roadmap: ["Backlog", "Todo"]`, `inProgress: ["In Progress"]`, `history: ["Done", "Cancelled"]`).
- A hosted GitHub MCP server is registered with Claude Code, reachable at `https://api.githubcopilot.com/mcp/`. The `projects` toolset is **not** enabled by default — it requires the `project` OAuth scope. An unscoped token makes the toolset appear absent; treat a missing toolset as a missing scope, not a missing server. (The exact `claude mcp add` registration command and OAuth scope wiring are finalized in task #19c — do not rely on a specific command here.)
- The user has authorized the GitHub MCP via OAuth 2.1 + PKCE at least once in this Claude Code installation. The first-ever GitHub MCP call triggers a browser-based flow; subsequent calls reuse the cached token until it expires.

Tool naming convention: the operations below refer to GitHub Projects v2 operations by their **role** — **project-item-list** (list a project's items), **item-fetch** (fetch one item by id), **item-create / draft-issue-create** (create a draft item), **item-field-update** (set or clear a field, including single-select Status), **comment/note-create** (append a note to the item's linked or draft issue) — rather than by exact MCP tool names, which depend on the MCP version and are resolved at call time by inspecting the tool list. These roles map to the confirmed Projects v2 toolset: `projects_list` / `projects_get` / `projects_write` (GA hosted endpoint `https://api.githubcopilot.com/mcp/`, OAuth 2.1 + PKCE).

> **⚠ Naming convention for `stateMap` lookups.** Bucket arguments in operations use snake_case (`roadmap`, `in_progress`, `history`). The matching JSON keys in `githubProject.stateMap` use camelCase (`roadmap`, `inProgress`, `history`). Every `githubProject.stateMap[bucket]` lookup in the operations below is **implicitly translated**: bucket `in_progress` → key `inProgress`, others unchanged. When writing `.roadmap.json`, use the camelCase keys. See [`docs/RoadmapBackend.md` — Buckets](../../docs/RoadmapBackend.md) for the full convention.

**Field/option-id resolution.** Setting the single-select **Status** field (or any single-select custom field) via Projects v2 requires the **field id + option id** — not the human label. Before any item-field-update that changes Status, the skill first inspects the project's field metadata via the project-item-list role to map a label like `"In Progress"` to its option id. This resolution is performed at call time.

### `listTasks(bucket)` — propose / inspect the buckets

Resolve the Status values for the requested bucket via `githubProject.stateMap[bucket]` in `.roadmap.json` (e.g. `["Backlog", "Todo"]` for `"roadmap"` under the defaults; for `in_progress`, look up `githubProject.stateMap.inProgress` per the naming convention above).

Call the project-item-list role to fetch project items, then filter to those whose Status value is in `githubProject.stateMap[bucket]`. **Exhaust pagination** — `project-item-list` returns items page by page (GraphQL `pageInfo` / cursor semantics); a single call's default page size does not guarantee every item in the project. Keep calling project-item-list with the next cursor, following `pageInfo.hasNextPage` / `endCursor`, until `hasNextPage` is `false`, then union all pages before filtering — stopping after the first page silently truncates the bucket. For each matching item, build a task element with:

- `id`: the item node id (`PVTI_...`).
- `title`: from the item.
- `current_bucket`: derived by reverse-mapping the item's Status through `githubProject.stateMap`.
- `contentType`, and — only when the content is an `Issue` — `issueNumber` and `issueRepo`. Select the content union in the same project-item-list query (`content { __typename ... on Issue { number repository { owner { login } name } } }`); these are extra **fields**, not extra **calls**. See [`docs/RoadmapBackend.md` — Content identity](../../docs/RoadmapBackend.md#content-identity-optional-fields). A consumer that needs to know whether an item is issue-backed — because only issue-backed items can carry native sub-issues — reads this field instead of re-querying every candidate by node id.

When `offlineMirror: true`, this operation also refreshes the corresponding section of the local mirror as part of the [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) procedure. When the caller passed `maxStaleness` and a fresh, complete, schema-current snapshot exists, the answer is served from that snapshot and **none** of the calls above are made; see [`docs/RoadmapBackend.md` — `listTasks(bucket, options?)`](../../docs/RoadmapBackend.md#listtasksbucket-options).

**Errors** — empty bucket returns an empty list (not an error). MCP unavailable → throw `backend-unavailable`.

### `getTask(id)` — fetch a single task's full content

Call the item-fetch role with the canonical `PVTI_...` node id. **This call is never served from the snapshot**, whatever the mirror's freshness — it is the authoritative single-item read that a cached listing is designed to be checked against.

Return:

- `id`: the item node id.
- `title`: from the item.
- `body`: from the item's draft-issue or linked-issue body.
- `current_bucket`: reverse-mapped from the item's Status through `githubProject.stateMap`.
- Custom-field values: `type`, `estimate`, `Ready` (the dedicated Ready field on the Project), `blocked_by` (plain text field).

**Where progress notes live (GitHubProjectBackend equivalent of `## Status`)**: there is no `## Status` section in a GitHub Project item; the equivalent is the **item's draft-issue or linked-issue comment thread**. Surface the most recent meaningful progress comment as the active state, the same way `FilesBackend` surfaces the latest `## Status` entry.

**Errors** — throw `task-not-found` if no item with that id exists, or it belongs to a different project than the configured owner/projectNumber. MCP unavailable → throw `backend-unavailable`.

### `addTask(task)` — adding a new task to the `ROADMAP`

1. **Create a draft item** using the item-create / draft-issue-create role with the given title and body.
2. **Set Status** to `githubProject.stateMap.roadmap[0]` (e.g. `Backlog` under defaults). Resolve the field id and option id from the project's field metadata via the project-item-list role before calling item-field-update.
3. **Set custom fields**: `type` and `estimate` if provided; `Ready` unset (not ready by default); `blocked_by` as a plain text value if provided.
4. **Capture the assigned item node id** (`PVTI_...`) returned by GitHub and return it.

When `offlineMirror: true`, the same operation **also** writes a new local `roadmap/TASK_NNN_<slug>.md` with YAML frontmatter `backend: github-project` + `backendId: <PVTI_...>` (the item node id returned by GitHub), plus an index entry in `ROADMAP.md`. The `TASK_NNN` is allocated locally (next sequential, following the `FilesBackend` numbering rule), independent of the GitHub item id. Bundle the local file write with the item-create calls as one logical transaction. Local-only — see [Offline mirror writes are local-only](#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend); never commit these writes.

**Side effects** — task exists in the Project in `githubProject.stateMap.roadmap[0]` (typically `Backlog`).

**Errors** — invalid input (missing title) → throw. Permission denied by GitHub → throw, surfacing the error verbatim.

### `moveTask(id, fromBucket, toBucket)` — moving a task between buckets

> **Moving INTO `history` is forbidden in this operation.** Use `appendHistoryEntry` instead — history transitions require PR metadata and a comment append.

1. **Pre-check the source bucket.** Call the item-fetch role. Verify the item's current Status is in `githubProject.stateMap[fromBucket]`. If not, throw `task-not-in-from-bucket`.
2. **Resolve target Status.** Use the **first** element of `githubProject.stateMap[toBucket]`; resolve its option id from the project's field metadata.
3. **Update the item's Status field** via item-field-update. A single Status field-update mutation is atomic — that satisfies the contract's atomicity requirement.

When `offlineMirror: true`, the same operation **also** rewrites the corresponding link entries in the local `ROADMAP.md` ↔ `IN_PROGRESS.md` (mirroring the `FilesBackend` behaviour). The local `roadmap/TASK_NNN_*.md` is **not** moved or renamed (indexed-layout rule). Both the local file edits and the GitHub Status-field update must succeed together — if the GitHub call fails, no local files are touched. Local-only — never commit these writes.

**Errors** — `task-not-in-from-bucket`, `move-into-history-forbidden` (when `toBucket == "history"`), `backend-unavailable`.

### `appendHistoryEntry(id, prMetadata)` — logging completed work

The **load-bearing atomic operation** that enforces the [pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing) above. Three steps in sequence:

1. **Pre-check.** Verify the item's current Status is in `githubProject.stateMap.inProgress` (using the camelCase key per the naming convention). If not, throw `task-not-in-progress`.
2. **Update Status to history.** Call item-field-update to set the item's Status to the first element of `githubProject.stateMap.history[0]` (e.g. `Done`). Resolve the option id from field metadata first.
3. **Append PR metadata as an item comment/note.** Call the comment/note-create role with the comment body formatted as:

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

**Atomicity caveat** — the Status change is atomic per mutation, but comment/note-create is a separate call. If the Status change succeeds but the comment append fails:

- **Do not** revert the Status change — the task is genuinely done; reverting would be misleading.
- **Retry** the comment append once. If it still fails, surface a clear warning to the user with the exact comment text so they can post it manually, and continue.

This caveat is documented in [`docs/RoadmapBackend.md` — Atomicity and rollback](../../docs/RoadmapBackend.md).

When `offlineMirror: true`, the same operation **also** removes the `IN_PROGRESS.md` link entry and appends the standard `HISTORY.md` entry (entry shape identical to `FilesBackend.appendHistoryEntry` — `### <Title> — YYYY-MM-DD` / `**PR:** [#N](url)` / `**Delivered:** …` / `**Tests:** …` / `**Follow-ups:** …`), bundled with the GitHub item-field-update + comment/note-create calls as one logical transaction. Local-only — never commit these writes.

**Errors** — `task-not-in-progress`, missing required `prMetadata` fields, `backend-unavailable`.

### `setReady(id, ready)` — set/clear the Ready field

Set or clear the dedicated **`Ready`** Project field on the item via the **item-field-update** role (`projects_write`).

1. **Resolve the field id and option id** from the project's field metadata via the project-detail operation (same field/option-id-resolution pattern as Status, documented in the preamble above). The `Ready` field is a boolean or single-select field; locate its id before writing.
2. `setReady(id,true)` sets the Ready field to its "ready" value. `setReady(id,false)` clears it (sets to the "not ready" value or unsets the field). A single item-field-update mutation — atomic.

When `offlineMirror: true`, mirror the `[ready]` token into the local `ROADMAP.md` entry (bundle with the GitHub call), parallel to how the other write ops mirror. Local-only — never commit this write.

**Errors** — `task-not-found`, `backend-unavailable`.

### `setPlan(id, markdown)` / `getPlan(id)` — store or retrieve the task plan

The plan lives in the item's draft-issue or linked-issue body, fenced by `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` delimiters. See [`docs/RoadmapBackend.md` — `setPlan`](../../docs/RoadmapBackend.md) for the canonical delimiter semantics (missing → empty, duplicate → first wins).

- **`setPlan(id, markdown)`** — fetch the current body via item-fetch; rewrite the content of the first delimiter pair (or append a fresh delimited section if absent); call item-write (body update). When `offlineMirror: true`, also write `.plan/<id>.md` locally (bundled with the GitHub call), parallel to the `setReady` offline-mirror pattern. Local-only, same as every other offline-mirror write — never commit `.plan/<id>.md` for this backend.
- **`getPlan(id)`** — fetch the item body via item-fetch and extract the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` pair. No markers → returns empty.

**Errors** — `task-not-found`, `backend-unavailable`.

### `isAvailable()` — connectivity check

For `GitHubProjectBackend`, `isAvailable()` returns `true` iff a GitHub MCP server is registered in Claude Code. The check is:

1. Inspect the MCP server list (equivalent to what `claude mcp list` would show).
2. Look for an MCP whose host matches `api.githubcopilot.com/mcp` (or whose registered name matches a known GitHub MCP registration name).
3. Return `true` if found; `false` otherwise.

**Must not** issue any GitHub API call — doing so would trigger the OAuth browser flow on first-ever invocation, violating the contract's "no side effects" rule for `isAvailable`. Exactly mirrors the `LinearBackend` pattern.

Cross-reference [`docs/RoadmapBackend.md` — `GitHubProjectBackend`](../../docs/RoadmapBackend.md) for the full `isAvailable` contract notes.

When `isAvailable()` returns `false`, the skill surfaces this to the user. Operations that depend on the GitHub MCP throw `backend-unavailable` when called against an unavailable backend. For the activation-time behaviour when `isAvailable()` returns `false`, see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below — the skill falls back gracefully to the existing local snapshot rather than refusing to activate.

## Operations (`GitHubIssuesBackend`)

This section describes how each of the six contract operations is performed when the repo's `.roadmap.json` declares `backend: "github-issues"`. The structure mirrors [Operations (`FilesBackend`)](#operations-filesbackend), [Operations (`LinearBackend`)](#operations-linearbackend), and [Operations (`GitHubProjectBackend`)](#operations-githubprojectbackend) above; only the per-operation implementation differs. **This is the one backend that has no MCP surface at all** — every operation below shells out to the `gh` CLI, never the GitHub MCP (that is `GitHubProjectBackend`'s surface).

Activation prerequisites (assumed by every operation below):

- `.roadmap.json` exists at the repo root with `backend: "github-issues"`, a `githubIssues.repo` selector (`"<owner>/<name>"`), and a `githubIssues.stateMap` (defaults: `roadmap: ["status:roadmap"]`, `inProgress: ["status:in-progress"]`, `history: ["status:done"]`).
- The `gh` CLI is installed on `PATH` and authenticated (`gh auth status` succeeds). There is no MCP registration step and no OAuth browser flow driven by the skill — authentication is whatever `gh auth login` already set up on the machine.
- The seven labels used by this backend (`status:roadmap`, `status:in-progress`, `status:done`, `ready`, and the three `priority:P0`/`priority:P1`/`priority:P2` labels) exist on `githubIssues.repo`. `/create-roadmap`'s `github-issues` setup step creates any missing ones via `gh label create` before writing `.roadmap.json` — see [`/create-roadmap`](../../commands/create-roadmap.md).

Every `gh` invocation below passes `--repo <githubIssues.repo>` explicitly rather than relying on the invoking shell's `cwd` remote.

> **⚠ Naming convention for `stateMap` lookups.** Bucket arguments in operations use snake_case (`roadmap`, `in_progress`, `history`). The matching JSON keys in `githubIssues.stateMap` use camelCase (`roadmap`, `inProgress`, `history`). Every `githubIssues.stateMap[bucket]` lookup in the operations below is **implicitly translated**: bucket `in_progress` → key `inProgress`, others unchanged. When writing `.roadmap.json`, use the camelCase keys. See [`docs/RoadmapBackend.md` — Buckets](../../docs/RoadmapBackend.md) for the full convention.

### `listTasks(bucket)` — propose / inspect the buckets

Resolve the label(s) for the requested bucket via `githubIssues.stateMap[bucket]` in `.roadmap.json` (e.g. `["status:roadmap"]` for `"roadmap"` under the defaults; for `in_progress`, look up `githubIssues.stateMap.inProgress` per the naming convention above).

Run `gh issue list --repo <githubIssues.repo> --label <label> --json number,title,body,labels --limit 1000` for each label in `githubIssues.stateMap[bucket]` (union the results, de-duplicating by issue number). For `history`, add `--state closed` (issues in `status:done` are also closed by `appendHistoryEntry`, see below). **`--limit 1000` is mandatory** — `gh issue list` defaults to 30 results and silently truncates without an explicit `--limit`, which would drop tasks from the bucket unnoticed. **Verify the returned count**: if a call returns exactly 1000 issues (i.e. the limit itself), the bucket may still be truncated — re-issue the call with a higher `--limit` (e.g. `5000`) until a call returns fewer than its limit, confirming the full set was retrieved. For each returned issue, build a task element with:

- `id`: the issue number (e.g. `42`).
- `title`: from the issue title.
- `current_bucket`: derived by reverse-mapping the issue's `status:*` label through `githubIssues.stateMap`.

When `offlineMirror: true`, this operation also refreshes the corresponding section of the local mirror as part of the [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) procedure.

**Errors** — empty bucket returns an empty list (not an error). `gh` unavailable or unauthenticated → throw `backend-unavailable`.

### `getTask(id)` — fetch a single task's full content

Run `gh issue view <n> --repo <githubIssues.repo> --json number,title,body,labels,state` with `<n>` the canonical issue number.

Return:

- `id`: the issue number.
- `title`: from the issue.
- `body`: from the issue body (with the `atelier:plan` delimited section, if present, left in place — `getPlan` is the operation that extracts it).
- `current_bucket`: reverse-mapped from the issue's `status:*` label through `githubIssues.stateMap`.
- `priority`: derived from whichever `priority:P0`/`priority:P1`/`priority:P2` label is present, if any.
- `Ready`: whether the `ready` label is present.
- `blocked_by`: parsed from the `**Blocked by:** …` convention line in the body, if present.

**Where progress notes live (GitHubIssuesBackend equivalent of `## Status`)**: there is no `## Status` section on a GitHub Issue; the equivalent is the **issue's comment thread** (`gh issue view <n> --json comments`). Surface the most recent meaningful progress comment as the active state, the same way `FilesBackend` surfaces the latest `## Status` entry.

**Errors** — throw `task-not-found` if no issue with that number exists on `githubIssues.repo`. `gh` unavailable or unauthenticated → throw `backend-unavailable`.

### `addTask(task)` — adding a new task to the `ROADMAP`

1. **Create the issue**: `gh issue create --repo <githubIssues.repo> --title <title> --body <body> --label <githubIssues.stateMap.roadmap[0]>` (e.g. `status:roadmap`).
2. **Add the priority label** if `priority` was given: a second `--label priority:P0|P1|P2` on the same `gh issue create` call.
3. **Capture the assigned issue number** returned by `gh issue create` (parsed from the printed issue URL) and return it as the new canonical `id`.

When `offlineMirror: true`, the same operation **also** writes a new local `roadmap/TASK_NNN_<slug>.md` with YAML frontmatter `backend: github-issues` + `backendId: <issue-number>`, plus an index entry in `ROADMAP.md`. The `TASK_NNN` is allocated locally (next sequential, following the `FilesBackend` numbering rule), independent of the GitHub issue number. Bundle the local file write with the `gh issue create` call as one logical transaction. Local-only — see [Offline mirror writes are local-only](#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend); never commit these writes.

**Side effects** — the issue exists on `githubIssues.repo`, open, carrying `githubIssues.stateMap.roadmap[0]` (typically `status:roadmap`).

**Errors** — invalid input (missing title) → throw. Permission denied by GitHub (e.g. no push access to the repo) → throw, surfacing the `gh` error verbatim.

### `moveTask(id, fromBucket, toBucket)` — moving a task between buckets

> **Moving INTO `history` is forbidden in this operation.** Use `appendHistoryEntry` instead — history transitions require PR metadata and close the issue.

1. **Pre-check the source bucket.** Run `gh issue view <n> --repo <githubIssues.repo> --json labels`. Verify the issue currently carries a label in `githubIssues.stateMap[fromBucket]`. If not, throw `task-not-in-from-bucket`.
2. **Swap the labels in one call.** Run `gh issue edit <n> --repo <githubIssues.repo> --remove-label <githubIssues.stateMap[fromBucket][0]> --add-label <githubIssues.stateMap[toBucket][0]>`. Bundling both label changes into a single `gh issue edit` invocation is what satisfies the contract's atomicity requirement — there is no separate multi-call transaction to compensate for.

When `offlineMirror: true`, the same operation **also** rewrites the corresponding link entries in the local `ROADMAP.md` ↔ `IN_PROGRESS.md` (mirroring the `FilesBackend` behaviour). The local `roadmap/TASK_NNN_*.md` is **not** moved or renamed (indexed-layout rule). Both the local file edits and the `gh issue edit` call must succeed together — if the `gh` call fails, no local files are touched. Local-only — never commit these writes.

**Errors** — `task-not-in-from-bucket`, `move-into-history-forbidden` (when `toBucket == "history"`), `backend-unavailable`.

### `appendHistoryEntry(id, prMetadata)` — logging completed work

The **load-bearing atomic operation** that enforces the [pre-merge tracking rule](#pre-merge-tracking-rule-load-bearing) above. Two steps in sequence:

1. **Pre-check.** Run `gh issue view <n> --repo <githubIssues.repo> --json labels`. Verify the issue currently carries the label in `githubIssues.stateMap.inProgress` (using the camelCase key per the naming convention). If not, throw `task-not-in-progress`.
2. **Swap the label and close the issue with the PR metadata as the closing comment, in one call.** Run:

   ```
   gh issue close <n> --repo <githubIssues.repo> --comment "<comment body>"
   ```

   formatted as:

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

   Immediately before or after the close (whichever the `gh` invocation order allows in one logical step), run `gh issue edit <n> --repo <githubIssues.repo> --remove-label <githubIssues.stateMap.inProgress[0]> --add-label <githubIssues.stateMap.history[0]>` to swap the status label to `status:done`.

**Atomicity caveat** — `gh issue close --comment` and the label swap are two separate `gh` calls (GitHub's REST/GraphQL surface has no single call that closes, comments, and re-labels together). If the label swap succeeds but the close-with-comment fails (or vice versa):

- **Do not** revert the side that succeeded — the task is genuinely done; reverting would be misleading.
- **Retry** the failed call once. If it still fails, surface a clear warning to the user with the exact command that needs to be re-run manually, and continue.

This caveat is documented in [`docs/RoadmapBackend.md` — Atomicity and rollback](../../docs/RoadmapBackend.md).

When `offlineMirror: true`, the same operation **also** removes the `IN_PROGRESS.md` link entry and appends the standard `HISTORY.md` entry (entry shape identical to `FilesBackend.appendHistoryEntry` — `### <Title> — YYYY-MM-DD` / `**PR:** [#N](url)` / `**Delivered:** …` / `**Tests:** …` / `**Follow-ups:** …`), bundled with the `gh` calls above as one logical transaction. Local-only — never commit these writes.

**Errors** — `task-not-in-progress`, missing required `prMetadata` fields, `backend-unavailable`.

### `setReady(id, ready)` — set/clear the `ready` label

Readiness is a dedicated **`ready`** label (lowercase, the literal string `ready`) on the issue.

1. **Resolve the `ready` label.** If it does not exist on `githubIssues.repo`, create it via `gh label create ready` (the same setup-time guarantee documented in [`/create-roadmap`](../../commands/create-roadmap.md) means this should already exist; treat a missing label at call time as a repair, not the expected path).
2. `setReady(id,true)` runs `gh issue edit <n> --repo <githubIssues.repo> --add-label ready`. `setReady(id,false)` runs `gh issue edit <n> --repo <githubIssues.repo> --remove-label ready`. A single `gh issue edit` call — atomic. Both add and remove are idempotent at the GitHub API level.

When `offlineMirror: true`, mirror the `[ready]` token into the local `ROADMAP.md` entry (bundle with the `gh` call), parallel to how the other write ops mirror. Local-only — never commit this write.

**Errors** — `task-not-found`, `backend-unavailable`.

### `setPlan(id, markdown)` / `getPlan(id)` — store or retrieve the task plan

The plan lives in the issue body, fenced by `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` delimiters. See [`docs/RoadmapBackend.md` — `setPlan`](../../docs/RoadmapBackend.md) for the canonical delimiter semantics (missing → empty, duplicate → first wins).

- **`setPlan(id, markdown)`** — run `gh issue view <n> --repo <githubIssues.repo> --json body` to fetch the current body; rewrite the content of the first delimiter pair (or append a fresh delimited section if absent); run `gh issue edit <n> --repo <githubIssues.repo> --body <new body>`. When `offlineMirror: true`, also write `.plan/<id>.md` locally (bundled with the `gh` call), parallel to the `setReady` offline-mirror pattern. Local-only, same as every other offline-mirror write — never commit `.plan/<id>.md` for this backend.
- **`getPlan(id)`** — run `gh issue view <n> --repo <githubIssues.repo> --json body` and extract the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` pair. No markers → returns empty.

**Errors** — `task-not-found`, `backend-unavailable`.

### `isAvailable()` — connectivity check

For `GitHubIssuesBackend`, `isAvailable()` returns `true` iff **both**:

1. The `gh` CLI binary is present on `PATH`.
2. `gh auth status` reports an authenticated session.

The check is a read-only auth probe — it does **not** call any Issues endpoint, so there is nothing to trigger an interactive login flow. If `gh auth status` itself would prompt interactively when unauthenticated, the skill treats a non-zero exit / "not logged in" output as `false` rather than following an interactive prompt. Return `false` if `gh` is missing or unauthenticated; `true` otherwise.

Cross-reference [`docs/RoadmapBackend.md` — `GitHubIssuesBackend`](../../docs/RoadmapBackend.md) for the full `isAvailable` contract notes.

When `isAvailable()` returns `false`, the skill surfaces this to the user (e.g. "`gh` is not authenticated — run `gh auth login`"). Operations that depend on `gh` throw `backend-unavailable` when called against an unavailable backend. For the activation-time behaviour when `isAvailable()` returns `false`, see [Mirror auto-refresh on activation](#mirror-auto-refresh-on-activation) below — the skill falls back gracefully to the existing local snapshot rather than refusing to activate.

## Mirror auto-refresh on activation

Applies when **all** of:

- `.roadmap.json` exists at the repo root.
- It declares a remote backend (`backend: "linear"`, `backend: "github-project"`, or `backend: "github-issues"`).
- It declares `offlineMirror: true`.

On skill activation in such a repo, the skill considers a mirror refresh **before** answering the user's prompt. This implements decision 8 in [TASK_001](../../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions): "automatic on skill activation; no background polling, no explicit `/refresh-roadmap` command in v1." Activation remains the only trigger — what has changed is that activation no longer *implies* a board read.

### Freshness gate (TTL)

The refresh is gated on a TTL, not performed unconditionally. Read `fetchedAt` from the snapshot's `meta.json` (see [Snapshot index](#snapshot-index-the-machine-face) below) and compare it against `mirrorTTL` — `linear.mirrorTTL` / `githubProject.mirrorTTL` / `githubIssues.mirrorTTL` in `.roadmap.json`, **default `"1h"`**, grammar `"<N>m"` / `"<N>h"` / `"0"` (never fresh).

- **Snapshot is younger than `mirrorTTL`, complete, and schema-current** → **no refresh, and no board read of any kind.** Activation proceeds against the existing mirror.
- **Otherwise** → run the refresh procedure below.

Two cadences this replaces, both wrong in different directions: refreshing on *every* activation (a full board sweep per session, which on a large board exhausts the backend's rate budget), and a once-per-calendar-day stamp (a date string cannot express "an hour ago", and it makes the first activation after midnight expensive and every other activation blind). Freshness is **computed** from an ISO-8601 instant. It is never inferred from a date.

### Refresh procedure

1. **Pre-check the backend's availability**: resolve the active backend from `.roadmap.json` and call that backend's `isAvailable()` — `LinearBackend.isAvailable()`, `GitHubProjectBackend.isAvailable()`, or `GitHubIssuesBackend.isAvailable()` (see [`isAvailable()` under Operations (LinearBackend)](#isavailable--connectivity-check-1), [`isAvailable()` under Operations (GitHubProjectBackend)](#isavailable--connectivity-check-2), and [`isAvailable()` under Operations (GitHubIssuesBackend)](#isavailable--connectivity-check-3)).

2. **If `isAvailable()` returns `false`** (the active backend's MCP is not registered / not reachable, or — for `github-issues` — `gh` is missing or unauthenticated):
   - **Do not** attempt the refresh.
   - **Fall back to the existing local snapshot**: the user can still read `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and every `roadmap/TASK_NNN_*.md` as they were at the last successful refresh.
   - **Surface a clear warning** at the start of the answer, naming the snapshot age and the reconnection hint. Examples:
     - _Linear backend_: _Linear MCP unreachable; showing the mirror snapshot from 2026-05-22 14:31. To restore: re-run `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` (or check your network). Read-only operations work against the snapshot; write operations (`addTask`, `moveTask`, `appendHistoryEntry`) will throw `backend-unavailable` until the MCP is restored._
     - _GitHub Project backend_: _GitHub MCP unreachable; showing the mirror snapshot from 2026-05-22 14:31. To restore: re-register / reconnect the hosted GitHub MCP (endpoint `https://api.githubcopilot.com/mcp/`) and ensure the `project` OAuth scope is granted. Read-only operations work against the snapshot; write operations (`addTask`, `moveTask`, `appendHistoryEntry`) will throw `backend-unavailable` until the MCP is restored._
     - _GitHub Issues backend_: _`gh` unavailable or unauthenticated; showing the mirror snapshot from 2026-05-22 14:31. To restore: install the `gh` CLI and/or run `gh auth login`. Read-only operations work against the snapshot; write operations (`addTask`, `moveTask`, `appendHistoryEntry`) will throw `backend-unavailable` until `gh` is restored._
   - Activation continues — the skill is still useful for reading the snapshot.

3. **If `isAvailable()` returns `true`**, perform the refresh in this order against the active backend (`LinearBackend`, `GitHubProjectBackend`, or `GitHubIssuesBackend`):
   1. Call `listTasks("roadmap")`. Regenerate the index lines in `ROADMAP.md`, plus any new `roadmap/TASK_NNN_*.md` files for remote items that do not yet have a local file.
   2. Call `listTasks("in_progress")`. Regenerate the link lines in `IN_PROGRESS.md`.
   3. Call `listTasks("history")` **scoped by the history window** (see below). Regenerate the matching `HISTORY.md` entries.

   4. Write **both faces of the mirror from this one read** — the markdown files above (the human face) *and* the snapshot index (the machine face, see below) — then stamp `fetchedAt`. A refresh that updates one face and not the other is a failed refresh: handle it under the Safe failure mode rather than leaving the two faces describing different boards.

   Each call above must exhaust pagination / use a non-truncating limit per its backend's `listTasks(bucket)` mandate (see [Operations](#operations-filesbackend) above — cursor pagination to `hasNextPage: false` for `linear` and `github-project`, `--limit 1000`+ re-check for `github-issues`). **Verify the returned set is complete before regenerating a bucket's files.** A call that cannot be confirmed complete (limit hit, paging loop aborted) is a failure for that bucket — handle it under the Safe failure mode below rather than regenerating from a partial result.

4. **Coherence rules** (per decision 3 in [TASK_001](../../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions)):
   - Match local task files to remote items by `backendId` in YAML frontmatter, **not** by title or slug.
   - New remote items that have no matching local file get new `roadmap/TASK_NNN_*.md` files with the next sequential `TASK_NNN` (per the [Numbering convention](../../commands/create-roadmap.md) — never reuse numbers).
   - Local task files whose `backendId` no longer exists remotely are **flagged in the warning** at the start of the answer (e.g. `TASK_042 — backendId no longer exists in the remote backend (Linear issue / GitHub Project item / GitHub Issue); left in place for review`) but **not auto-deleted**. The user decides whether to remove them.
   - When writing each `roadmap/TASK_NNN_*.md` file from a remote item's body, **split the `atelier:plan` section out of the body first**: extract the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` pair, write the remainder to `roadmap/TASK_NNN_*.md`, and materialize the extracted plan as `.plan/<id>.md` (numeric id). If no delimiter markers are present, write the body as-is and skip the `.plan/<id>.md` write.

5. **Safe failure mode**:
   - If any individual `listTasks` call fails mid-refresh, **stop that bucket's refresh** and keep the previous local snapshot for that bucket intact. Do **not** half-write the bucket's files.
   - Refresh of other buckets that already completed successfully stays applied.
   - Surface the partial-refresh state clearly: name the buckets that succeeded vs failed, and the underlying error per failed bucket.

### Snapshot index (the machine face)

The markdown mirror is prose for the operator; it cannot answer a structured query. Its `ROADMAP.md` index lines carry `<type> <title> #id ~estimate` and its task-file frontmatter carries `backend` / `backendId` — neither carries the item's Status, its readiness, or its content type. A consumer needing those would have to open every task file and would still come away without them.

So the same refresh also writes a structured snapshot, **outside the repo** and keyed by **the board rather than the repo** (one board often backs several repos; the host tool picks the actual directory):

```
<host-cache-dir>/<backend-key>/
  meta.json          # schemaVersion, backend, fetchedAt, buckets, items, complete
  index.json         # one record per item, across all three buckets
  bodies/<key>.md    # item body, one file per item, under a stable per-item key
```

`<backend-key>` is `project-<owner>-<projectNumber>` / `linear-<teamId>` / `issues-<owner>-<repo>`.

Three rules bind the writer and the reader. The full specification is [`docs/RoadmapBackend.md` — Offline mirror](../../docs/RoadmapBackend.md#offline-mirror-freshness-snapshot-layout-and-cache-service):

1. **Populate every field you declare.** A column that is structurally always `null` is worse than no column, because the next reader takes its presence as evidence the data is there. `priority` in particular needs a declared provenance (Project `Priority` field, else a `**Priority:** P<N>` line in the body, else absent) — a `null` must mean *the board declares no priority*, never *we did not look*. Type and estimate are not columns: they live inside `title`, and are parsed from it exactly as they are parsed from a markdown index line.
2. **Writes are write-through and do not refresh.** `addTask` / `moveTask` / `setReady` / `setPlan` / `appendHistoryEntry` update the snapshot from the values they just wrote — never by reading the board back — and **never advance `fetchedAt`**. A write is not a read: advancing the stamp would extend every *other* record's staleness by a full TTL while only one record actually became current.
3. **Validate a snapshot before trusting it.** The directory is untrusted input — it may predate the schema, or have been left by another tool. Confirm `meta.json` parses, carries the current `schemaVersion`, and reports `complete: true`; anything else is a cache miss, so discard and refetch rather than reading it as far as it goes. This failure is invisible without the check: a plausible index of unknown provenance yields a backlog quietly days old and several items short, with nothing in the output to say so.

### History window

The `history` bucket can grow large over a long-running project. To bound the cost of refreshing it on every activation, `listTasks("history")` is **scoped by default to the last 90 days** of items whose state is in the backend's history states. The window key is **backend-scoped**:

- **Linear backend** — `linear.historyWindow` in `.roadmap.json`:

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

- **GitHub Project backend** — `githubProject.historyWindow` in `.roadmap.json` (identical grammar):

  ```json
  {
    "backend": "github-project",
    "offlineMirror": true,
    "githubProject": {
      "owner": "<org-or-user>",
      "projectNumber": 7,
      "historyWindow": "90d",
      "stateMap": {
        "roadmap": ["Backlog", "Todo"],
        "inProgress": ["In Progress"],
        "history": ["Done", "Cancelled"]
      }
    }
  }
  ```

- **GitHub Issues backend** — `githubIssues.historyWindow` in `.roadmap.json` (identical grammar):

  ```json
  {
    "backend": "github-issues",
    "offlineMirror": true,
    "githubIssues": {
      "repo": "acme/widgets",
      "historyWindow": "90d",
      "stateMap": {
        "roadmap": ["status:roadmap"],
        "inProgress": ["status:in-progress"],
        "history": ["status:done"]
      }
    }
  }
  ```

Supported `historyWindow` values (same grammar for all three backends):

| Value | Meaning |
| :--- | :--- |
| `"90d"` (default if omitted) | Items whose completion date is within the last 90 days. |
| `"30d"`, `"180d"`, `"365d"`, etc. | Same shape, different window. |
| `"50"` (any bare integer) | The last N entries by completion date, regardless of age. |
| `"all"` | No limit; pull every history item. Use only on small projects — refresh cost scales with project age. |

Items older than the window remain accessible via `getTask(id)` on-demand — `getTask` always fetches a single item from the remote backend regardless of window. The window only bounds the refresh's `listTasks("history")` call.

### What is **not** refreshed

- **Local task file bodies that were modified by the refresh's own previous run**: this is fine, the next refresh will overwrite them again. The contract is read-only mirror; user-edited content is not preserved (decision 7).
- **`.roadmap.json`**: never modified by the refresh. The config is the user's choice, not Linear's.
- **`.git/info/exclude`**: never modified by the refresh. It is written only at `/create-roadmap` / `/migrate-roadmap` time (never the committed `.gitignore` — see [Offline mirror writes are local-only](#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend)).

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
- Does not push tracking commits to a protected branch directly. For `FilesBackend`, tracking updates ride on the same PR branch as the work they describe. For `LinearBackend`/`GitHubProjectBackend`/`GitHubIssuesBackend`, tracking IS the remote call (MCP or `gh`) — the local offline-mirror files are read-only convenience copies and are never committed at all (see [Offline mirror writes are local-only](#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend)).
- Does not assume one layout — always detects first.
- Does not invent PR numbers. If the PR is not yet open, log the entry with a placeholder and ask the user to confirm the number once it exists, **before** the PR is merged.
- Does not invent the tracking flow on repos that do not use it. When predicate 3 fires alone (the user mentions the flow on a repo without the three tracking files and without `.roadmap.json`), the answer is to point at `/create-roadmap` and stop — **not** to extract priorities from a substitute markdown file in the repo. See [When this skill applies](#when-this-skill-applies) above for the full rule.
