# `RoadmapBackend` — backend contract

The `RoadmapBackend` is the abstract contract every storage backend in `claude-roadmap-tools` implements. The `roadmap-tracking-flow` skill, `/create-roadmap`, and `/migrate-roadmap` all operate against this contract — they do not call file or Linear APIs directly.

v1 ships four backends:

- **`FilesBackend`** — markdown files at the repo root, today's behaviour, default.
- **`LinearBackend`** — Linear issues, via the Linear MCP server. Selected by `.roadmap.json`.
- **`GitHubProjectBackend`** — GitHub Projects v2 items, via the hosted GitHub MCP server. Selected by `.roadmap.json`.
- **`GitHubIssuesBackend`** — one GitHub Issue per roadmap task, driven via the `gh` CLI (not the GitHub MCP — that is `GitHubProjectBackend`'s surface). Selected by `.roadmap.json`.

Future backends (`JiraBackend`, `TrelloBackend`) implement the same contract.

> ⚠️ **The plugin is 100% markdown.** This document is the contract the **skill** follows; the "implementation" of each backend is the set of instructions the skill applies when that backend is active. There is no executable code in the plugin — the function-style signatures below are a specification of inputs, outputs, and behaviour, not a reference to a runtime API.

This contract is the canonical reference. The matching task plan (with goals, sub-tasks, and decisions) lives in [`roadmap/TASK_001_multi-backend-linear-first.md`](../roadmap/TASK_001_multi-backend-linear-first.md).

## Concepts

### Identity

Every task has a single canonical `id` per backend.

| Backend | Canonical `id` | Notes |
| :--- | :--- | :--- |
| `FilesBackend` | `TASK_NNN` (e.g. `TASK_001`) | Sequential, zero-padded to three digits, never reused (per the indexed-layout numbering rule in `skills/roadmap-tracking-flow/SKILL.md`). |
| `LinearBackend` | Linear issue ID (e.g. `ENG-123`) | Allocated by Linear on issue creation. |
| `GitHubProjectBackend` | GitHub Projects v2 item node id (e.g. `PVTI_...`) | Allocated by GitHub on item creation. The local `TASK_NNN` remains the **human handle** for filenames and the index in `ROADMAP.md`, exactly parallel to `LinearBackend`'s `ENG-123` ↔ `TASK_NNN` parity. |
| `GitHubIssuesBackend` | GitHub Issue number (e.g. `#42`) | Allocated by GitHub on issue creation (`gh issue create`). The local `TASK_NNN` remains the **human handle** for filenames and the index in `ROADMAP.md`, exactly parallel to `LinearBackend`'s `ENG-123` ↔ `TASK_NNN` and `GitHubProjectBackend`'s `PVTI_...` ↔ `TASK_NNN` parity. |
| _Future_ | Backend-native ID | Each future backend documents its scheme in this table. |

When the offline mirror is enabled (Linear backend + `.roadmap.json` has `offlineMirror: true`), each local task file's YAML frontmatter carries both:

```yaml
---
backend: linear
backendId: ENG-123
---
```

The local `TASK_NNN` stays the **human handle** (for filenames and the index in `ROADMAP.md`); `backendId` is the **canonical identity for sync** operations against Linear. See decision 9 in [TASK_001](../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions).

For `GitHubProjectBackend` with an offline mirror, the same frontmatter pattern applies:

```yaml
---
backend: github-project
backendId: PVTI_xxx
---
```

The local `TASK_NNN` stays the **human handle** (for filenames and the index in `ROADMAP.md`); `backendId` (the Projects v2 item node id) is the **canonical identity for sync** operations against the Project.

For `GitHubIssuesBackend` with an offline mirror, the same frontmatter pattern applies:

```yaml
---
backend: github-issues
backendId: 42
---
```

The local `TASK_NNN` stays the **human handle** (for filenames and the index in `ROADMAP.md`); `backendId` (the GitHub Issue number, stored as a bare integer) is the **canonical identity for sync** operations against the repo's Issues.

### Buckets

Three abstract buckets — backends map each one to native concepts:

| Bucket | Meaning | `FilesBackend` | `LinearBackend` | `GitHubProjectBackend` | `GitHubIssuesBackend` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `roadmap` | Backlog. Tasks awaiting prioritization or start. | `ROADMAP.md` (or index entries in indexed layout). | Linear states matching `linear.stateMap.roadmap` (defaults: `Backlog`, `Todo`). | Project **Status** field values matching `githubProject.stateMap.roadmap` (defaults: `Backlog`, `Todo`). | Issues carrying the label `status:roadmap`. |
| `in_progress` | Active work. Tasks moved here when work actually begins. | `IN_PROGRESS.md`. | States matching `linear.stateMap.inProgress` (default: `In Progress`). | Status values matching `githubProject.stateMap.inProgress` (default: `In Progress`). | Issues carrying the label `status:in-progress`. |
| `history` | Completed work, append-only log. | `HISTORY.md`, newest first, grouped by `## YYYY-MM`. | States matching `linear.stateMap.history` (defaults: `Done`, `Cancelled`). | Status values matching `githubProject.stateMap.history` (defaults: `Done`, `Cancelled`). | Issues carrying the label `status:done` (closed on the same call). |

> **⚠ Naming convention — bucket names vs JSON config keys.** Bucket names in operation arguments use snake_case (`roadmap`, `in_progress`, `history`). The matching JSON config keys in `.roadmap.json`'s `linear.stateMap` (or `githubProject.stateMap`, or `githubIssues.stateMap`) use camelCase (`roadmap`, `inProgress`, `history`). **The mapping is fixed**: bucket `roadmap` ↔ field `linear.stateMap.roadmap`, bucket `in_progress` ↔ field `linear.stateMap.inProgress`, bucket `history` ↔ field `linear.stateMap.history`. This mismatch is intentional: snake_case reads better as a programmatic identifier inside operations, camelCase matches JSON conventions for config. Implementations of any backend (including the LinearBackend `listTasks`, `moveTask`, etc.) **must** translate from the snake_case bucket argument to the camelCase config key when looking up state names. The skill's `## Mirror auto-refresh on activation` section in `SKILL.md` performs this translation explicitly; new backends must do the same. **`GitHubIssuesBackend` names its bucket-mapping field `stateMap` too** (`githubIssues.stateMap`), for consistency with the other two remote backends, even though each value is a **label name** rather than a workflow-state name — same `roadmap` / `inProgress` / `history` keys, same snake_case ↔ camelCase translation rule. Defaults: `roadmap: ["status:roadmap"]`, `inProgress: ["status:in-progress"]`, `history: ["status:done"]`.

### Task representation

A task carries at least: `id`, `title`, `body`. Implementations may include `priority` and backend-specific metadata.

- `priority` for `FilesBackend`: which markdown section the index entry lives under (`High Priority`, `Medium Priority`, `Low Priority / Ideas`).
- `priority` for `LinearBackend`: Linear's priority field (1=Urgent, 2=High, 3=Medium, 4=Low, 0=No priority). The mapping to/from the markdown sections is documented per backend below.

## Operations

Every operation is described by:

- **Inputs** — what the caller supplies.
- **Returns** — what the operation yields on success.
- **Side effects** — observable state changes.
- **Errors** — failure modes (always thrown, never silent).
- **Per-backend notes** — implementation specifics (or "Same across backends").

### `listTasks(bucket)`

- **Inputs** — `bucket`: one of `"roadmap" | "in_progress" | "history"`.
- **Returns** — ordered list of tasks.
  - For `roadmap` and `in_progress`: in the order the bucket is human-curated (sections / Linear's display order).
  - For `history`: newest entry first.
  - Each element carries at least `id` and `title`; backends may include `body`, `priority`, and metadata.
- **Side effects** — none (read-only).
- **Errors** — empty bucket returns an empty list (not an error). Backend unavailable throws (see `isAvailable`).
- **`FilesBackend`** — reads `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md`. In indexed layout, follows each index link to the matching `roadmap/TASK_NNN_*.md` to enrich `body` and `priority`.
- **`LinearBackend`** — queries Linear issues filtered by team and the states listed in `linear.stateMap[bucket]`.
- **`GitHubProjectBackend`** — uses the project-detail operation (Projects v2 toolset) to fetch all items, then filters by the Status field values listed in `githubProject.stateMap[bucket]`.
- **`GitHubIssuesBackend`** — runs `gh issue list --label <label> --json number,title,body,labels` for each label listed in `githubIssues.stateMap[bucket]`, against `githubIssues.repo`.

### `getTask(id)`

- **Inputs** — canonical `id`.
- **Returns** — the full task: `id`, `title`, `body`, `priority`, current bucket, backend-specific metadata.
- **Side effects** — none.
- **Errors** — throws `task-not-found` if the id is unknown. Backend unavailable throws.
- **`FilesBackend`** — reads `roadmap/TASK_NNN_*.md` when in indexed layout; otherwise extracts the task block from the bucket file in single-file layout.
- **`LinearBackend`** — calls the Linear MCP issue-fetch tool with the issue id.
- **`GitHubProjectBackend`** — uses the project-detail operation to fetch the item by its `PVTI_...` node id.
- **`GitHubIssuesBackend`** — runs `gh issue view <n> --json number,title,body,labels,state` with `<n>` the canonical issue number, against `githubIssues.repo`.

### `addTask(task)`

- **Inputs** — a task with at least `{ title, body }`. Optional `priority`.
- **Returns** — the created task, with `id` assigned by the backend.
- **Side effects** — the task is now in the `roadmap` bucket.
- **Errors** — invalid input (missing `title`) throws. Backend rejection (e.g. Linear team permission) throws.
- **`FilesBackend`** — allocates the next sequential `TASK_NNN` (highest existing + 1), writes `roadmap/TASK_NNN_<slug>.md`, and inserts the bullet under the appropriate priority section in `ROADMAP.md`. In single-file layout, writes the task block directly into `ROADMAP.md`.
- **`LinearBackend`** — calls the Linear MCP issue-create tool with team, title, body, and an initial state from `linear.stateMap.roadmap[0]`.
- **`GitHubProjectBackend`** — uses the item-write operation (Projects v2 toolset) to create a draft item with the given title and body, then sets the Status field to the first value in `githubProject.stateMap.roadmap`. Because setting a single-select field requires the field's `option id` (not its human label), the implementation must first retrieve the project's field definitions via the project-detail operation to resolve the option id before calling the item-write operation.
- **`GitHubIssuesBackend`** — runs `gh issue create --title <title> --body <body> --label <first value of githubIssues.stateMap.roadmap>` (plus a `priority:*` label when `priority` is given) against `githubIssues.repo`. The issue number GitHub assigns is the new canonical `id`.

### `moveTask(id, fromBucket, toBucket)`

- **Inputs** — `id`, `fromBucket`, `toBucket`. Both `fromBucket` and `toBucket` must be in `{"roadmap", "in_progress"}`. Moving INTO `history` is forbidden in this operation — use `appendHistoryEntry` instead.
- **Returns** — the moved task.
- **Side effects** — task is now in `toBucket`; no longer in `fromBucket`.
- **Atomicity** — the move is **atomic**: either both side effects succeed or none happen. Backends that cannot guarantee a single-transaction update must implement compensation (e.g. `FilesBackend` writes both files within one edit set so the diff is reviewable as a single unit).
- **Errors** — throws `task-not-in-from-bucket` if `id` is not currently in `fromBucket` (prevents race conditions and wrong assumptions). Throws `move-into-history-forbidden` if `toBucket == "history"`.
- **`FilesBackend`** — edits `ROADMAP.md` and `IN_PROGRESS.md` together in one change set. The `roadmap/TASK_NNN_*.md` file is **not** moved or renamed — only the index entries change.
- **`LinearBackend`** — calls the Linear MCP issue-update tool, changing the issue's state to the first state listed in `linear.stateMap[toBucket]`.
- **`GitHubProjectBackend`** — uses the item-write operation to update the item's Status field to the first value in `githubProject.stateMap[toBucket]`. The option id must be resolved from the project's field definitions via the project-detail operation before writing.
- **`GitHubIssuesBackend`** — runs `gh issue edit <n> --remove-label <githubIssues.stateMap[fromBucket][0]> --add-label <githubIssues.stateMap[toBucket][0]>` in a single call so both label changes land together (satisfying atomicity).

### `appendHistoryEntry(id, prMetadata)`

The load-bearing operation that enforces the pre-merge tracking rule.

- **Inputs** — `id`, `prMetadata`: `{ number, url, title, deliveredBullets[], testsNote, followUps?[] }`.
- **Returns** — the history entry created.
- **Side effects** —
  1. Removes the task from its current bucket (typically `in_progress`).
  2. Adds a structured entry to `history` referencing the PR.
- **Atomicity** — both side effects happen as a **single transaction**. Half-completed history-append is not acceptable; if either side fails, both must be rolled back. This is what makes the pre-merge tracking rule reliable.
- **Errors** — throws `task-not-in-progress` if the task is not currently in `in_progress`. Throws on missing required `prMetadata` fields.
- **`FilesBackend`** — within one edit set: (a) removes the link line from `IN_PROGRESS.md`, (b) appends an entry to `HISTORY.md` under the current month's section (creating the section if absent), formatted per the convention in `skills/roadmap-tracking-flow/SKILL.md` (`### <Title> — YYYY-MM-DD` / `**PR:** [#N](url)` / `**Delivered:** …` / `**Tests:** …` / `**Follow-ups:** …`). The `roadmap/TASK_NNN_*.md` task file is **not** deleted — it stays as the canonical record of what was delivered.
- **`LinearBackend`** — calls the Linear MCP issue-update tool, changing the issue's state to the first state listed in `linear.stateMap.history`. PR metadata is preserved by appending a comment to the Linear issue (or by updating the issue description — implementation choice deferred to the LinearBackend sub-task; either is contract-compliant). When the offline mirror is enabled, the local `HISTORY.md` entry is regenerated from Linear's done state on the next skill activation refresh.
- **`GitHubProjectBackend`** — uses the item-write operation to set the item's Status field to the first value in `githubProject.stateMap.history`. PR metadata is stored by updating a text field on the item (e.g. a `PR` custom field). When the offline mirror is enabled, the local `HISTORY.md` entry is regenerated on the next skill activation refresh.
- **`GitHubIssuesBackend`** — runs `gh issue edit <n> --remove-label <githubIssues.stateMap.inProgress[0]> --add-label <githubIssues.stateMap.history[0]>`, then `gh issue close <n> --comment <PR metadata formatted per the SKILL.md comment shape>` (close and comment in the same call). Pre-check via `gh issue view <n> --json labels` before either write. When the offline mirror is enabled, the local `HISTORY.md` entry is regenerated on the next skill activation refresh.

### `setReady(id, ready)`

- **Inputs** — `id` (canonical id); `ready` (boolean).
- **Returns** — the updated readiness state (`true` or `false`) confirming the new value.
- **Side effects** — the task's readiness marker is set or cleared. Idempotent: setting an already-set marker (or clearing an already-clear one) is a no-op success.
- **Atomicity** — a single field/label/token write; atomic by construction (one write, no multi-resource transaction).
- **Errors** — throws `task-not-found` if the id is unknown. Throws `backend-unavailable` when the backend is unreachable.
- **`FilesBackend`** — the marker is the literal `[ready]` token in the task's ROADMAP entry. Single-file layout: the token is placed immediately after the `- [ ]` checkbox on the task's heading line. Indexed layout: the token is placed immediately after the checkbox if the index link line carries one, or immediately after the leading `- ` bullet marker (before the link) if it does not. `setReady(id,true)` inserts `[ready]`; `setReady(id,false)` removes it. Single in-file edit; idempotent.
- **`LinearBackend`** — readiness is a dedicated **`Ready` label** on the issue (labels are universally available without per-team custom-field setup). `setReady(id,true)` adds the `Ready` label (resolving it by name; creating it if absent, mirroring how the backend handles other label/state lookups); `setReady(id,false)` removes it. The label name is the literal string `Ready`.
- **`GitHubProjectBackend`** — set/clear the dedicated **`Ready`** Project field (a boolean or single-select field on the Project item, as documented in the `GitHubProjectBackend` notes' `[ready]` marker bullet) via the **item-field-update** role (`projects_write`). The field id and option id are resolved from the project's field metadata via the project-detail operation first (same field/option-id-resolution pattern as Status). `setReady(id,true)` sets the Ready field; `setReady(id,false)` clears it. A single field-update mutation — atomic.
- **`GitHubIssuesBackend`** — readiness is a dedicated **`ready`** label (lowercase, the literal string `ready`) on the issue. `setReady(id,true)` runs `gh issue edit <n> --add-label ready` (creating the label first via `gh label create ready` if it does not yet exist); `setReady(id,false)` runs `gh issue edit <n> --remove-label ready`. A single `gh issue edit` call — atomic; both add and remove are idempotent at the GitHub API level.

### `setPlan(id, markdown)`

- **Inputs** — `id` (canonical id); `markdown` (the plan content as a markdown string).
- **Returns** — nothing (void).
- **Side effects** — the plan content is stored backend-resident. Rewrite-in-place: if the body already contains a `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` marker pair, the content between the first such pair is replaced with the new `markdown`. If no marker pair is present, a fresh `<!-- atelier:plan:start -->` … `<!-- atelier:plan:end -->` section is appended to the body.
- **Atomicity** — a single body / description / file write; atomic by construction.
- **Errors** — throws `task-not-found` if the id is unknown. Throws `backend-unavailable` when the backend is unreachable.
- **Delimiter semantics (canonical reference)** — the delimiter pair `<!-- atelier:plan:start -->` … `<!-- atelier:plan:end -->` fences the plan section inside a remote item body / issue description. Two degenerate cases:
  - **Missing markers**: `getPlan` returns empty / none (not an error); `setPlan` appends a fresh delimited section.
  - **Duplicate markers** (multiple `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` pairs in the same body): first match wins. `getPlan` reads the content between the first pair; `setPlan` rewrites the content of the first pair and leaves any trailing duplicate sections untouched. This is a known-degenerate case; no auto-cleanup is performed.
- **`FilesBackend`** — the plan lives in `.plan/<id>.md`, keyed by the **numeric task id** (e.g. `.plan/6.md` for task `TASK_006`). `setPlan` writes or overwrites this file. No delimiter markers are used — the file is the plan content verbatim.
- **`LinearBackend`** — the plan lives in the issue description, fenced by the delimiter pair. `setPlan` fetches the current description via issue-fetch, rewrites or appends the delimited section, then calls issue-update. When `offlineMirror: true`, also writes `.plan/<id>.md` locally (bundled with the Linear call), parallel to how `setReady` mirrors the `[ready]` token — **local-only**, kept out of git via `.git/info/exclude`, never committed (see `SKILL.md` — [Offline mirror writes are local-only](../skills/roadmap-tracking-flow/SKILL.md#offline-mirror-writes-are-local-only-linearbackend--githubprojectbackend--githubissuesbackend)).
- **`GitHubProjectBackend`** — the plan lives in the item's draft-issue or linked-issue body, fenced by the same delimiter pair. `setPlan` fetches the current body via item-fetch, rewrites or appends the delimited section, then calls item-write (body update). When `offlineMirror: true`, also writes `.plan/<id>.md` locally (bundled with the GitHub call), parallel to the `setReady` offline-mirror pattern — **local-only**, same treatment as `LinearBackend` above; the plan is fully resident in the item body, the local file is a read convenience that must never be tracked or committed.
- **`GitHubIssuesBackend`** — the plan lives in the issue body, fenced by the same delimiter pair. `setPlan` runs `gh issue view <n> --json body` to fetch the current body, rewrites or appends the delimited section, then runs `gh issue edit <n> --body <new body>`. When `offlineMirror: true`, also writes `.plan/<id>.md` locally (bundled with the `gh` call), parallel to the `setReady` offline-mirror pattern — **local-only**, same treatment as `LinearBackend`/`GitHubProjectBackend` above.

### `getPlan(id)`

- **Inputs** — `id` (canonical id).
- **Returns** — the plan content as a markdown string, or empty / none if no plan has been set.
- **Side effects** — none (read-only).
- **Atomicity** — read-only; no atomicity concern.
- **Errors** — throws `task-not-found` if the id is unknown. Throws `backend-unavailable` when the backend is unreachable.
- **`FilesBackend`** — reads `.plan/<id>.md` (numeric id, e.g. `.plan/6.md`). Missing file → returns empty (no plan; not an error).
- **`LinearBackend`** — fetches the issue description via issue-fetch and extracts the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` marker pair. No markers → returns empty.
- **`GitHubProjectBackend`** — fetches the item body via item-fetch and extracts the content between the first marker pair. No markers → returns empty.
- **`GitHubIssuesBackend`** — runs `gh issue view <n> --json body` and extracts the content between the first `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` marker pair. No markers → returns empty.

### `isAvailable()`

- **Inputs** — none.
- **Returns** — `true` or `false`.
- **Side effects** — **must not mutate any state and must not trigger interactive flows** (e.g. OAuth). The skill is allowed to call `isAvailable` on every activation.
- **Errors** — must not throw on routine connectivity issues; just returns `false`. Throws only on programmer errors (e.g. backend instance not initialized).
- **`FilesBackend`** — always returns `true`. The filesystem is the backend.
- **`LinearBackend`** — checks that a Linear MCP server is registered in Claude Code (matching the `mcp.linear.app` host or a known server name like `linear-server`). Returns `false` if not. Does **not** issue any Linear API call — that would trigger OAuth on first ever use.
- **`GitHubProjectBackend`** — inspects the registered MCP server list in Claude Code for a host/name match against the hosted GitHub MCP endpoint (`api.githubcopilot.com/mcp`). Returns `false` if not found. Issues **no** API call — avoids triggering OAuth on first use, exactly mirroring the `LinearBackend` pattern.
- **`GitHubIssuesBackend`** — checks that the `gh` CLI binary is present on `PATH` and runs `gh auth status` (a read-only auth probe, not a mutating API call). Returns `true` iff `gh` is installed **and** `gh auth status` reports an authenticated session; `false` otherwise. Does **not** call any Issues endpoint — mirrors the "no side effects, no OAuth trigger" contract of `LinearBackend`/`GitHubProjectBackend`, substituting `gh`'s local auth-state check for an MCP-registration check since this backend has no MCP surface at all.

## Error semantics

- All operations **throw on error**; the skill catches and surfaces a human-readable message. **No silent failures.**
- An operation that partially succeeds must clean up before throwing. Half-written files or half-moved Linear states are not acceptable.
- Error names are stable strings (e.g. `task-not-found`, `task-not-in-from-bucket`, `move-into-history-forbidden`, `task-not-in-progress`, `backend-unavailable`) so the skill can branch on them.
- `isAvailable()` is the only operation that surfaces "backend not reachable" as a boolean instead of an exception. Every other operation throws `backend-unavailable` when `isAvailable()` would have returned `false`.

## Atomicity and rollback

- **`moveTask`** and **`appendHistoryEntry`** are atomic. Backends that touch multiple resources implement compensation if their underlying API does not provide transactions.
  - `FilesBackend`: bundles all file edits into a single change set so the user reviews and commits them as one unit. If the user rejects partway, no files are left touched.
  - `LinearBackend`: each operation maps to a single Linear API call (state change), so atomicity is provided by Linear's transactional state update. The risk is for `appendHistoryEntry` where PR metadata is appended as a comment after the state change — if the comment append fails the state is already moved; the skill should re-try the comment and surface a warning if it cannot, but **not** revert the state.
  - `GitHubIssuesBackend`: `moveTask` bundles both label changes (`--remove-label` + `--add-label`) into a single `gh issue edit` call, so atomicity is provided by that one API call. `appendHistoryEntry` bundles the label swap and the issue close into a single `gh issue close --comment` call where possible; if the label swap must precede the close (two calls), and the close fails after the labels changed, do **not** revert the labels — retry the close once and surface a warning if it still fails, the same non-reversion policy as `LinearBackend`'s comment-append risk.

## Per-backend notes

### `FilesBackend`

- Always available (no remote dependency).
- Identity: sequential `TASK_NNN`, allocated by scanning `roadmap/` for the highest existing number + 1. Numbers are never reused.
- Layouts: **single-file** and **indexed**. The contract is the same; only file layout differs:
  - Single-file: task content lives inside `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` directly. `getTask` extracts the block from the relevant file. `moveTask` cuts the block and pastes it.
  - Indexed: task content lives in `roadmap/TASK_NNN_<slug>.md`. The three top-level files hold only **links** to those task files. `moveTask` rewrites the link lines only — task files never move.
- Numbering and slug rules: see `skills/roadmap-tracking-flow/SKILL.md` (the canonical naming convention).

### `LinearBackend`

- Requires the Linear MCP to be registered: `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` (run once per machine, see [TASK_001](../roadmap/TASK_001_multi-backend-linear-first.md#linear-backend-specifics) decisions 4 and 5).
- Authentication: OAuth 2.1 with dynamic client registration. The browser opens for the user to authorize on the first data call; subsequent calls reuse the token until it expires.
- Identity: Linear issue ID (e.g. `ENG-123`).
- State mapping: `linear.stateMap` in `.roadmap.json`. Defaults shipped: `roadmap: ["Backlog", "Todo"]`, `inProgress: ["In Progress"]`, `history: ["Done", "Cancelled"]`. Users override per team.
- Team selection: `linear.teamId` in `.roadmap.json`. `/create-roadmap` writes this during setup.
- History window for refresh: `linear.historyWindow` in `.roadmap.json` (only meaningful with `offlineMirror: true`). Bounds the cost of `listTasks("history")` on every skill activation. Supported values: `"90d"` (default), any `"<N>d"`, a bare integer like `"50"` (last N entries), or `"all"` (no limit). Issues outside the window remain accessible via `getTask(id)` on-demand. See [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md) for the full semantics.
- Offline mirror: when `offlineMirror: true`, the skill maintains five local paths (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`, `.plan/`) as a one-way read-only mirror of Linear's state — local-only, never committed, kept out of git via `.git/info/exclude`. The mirror refreshes automatically every time the skill activates. See [TASK_001 — Offline mirror semantics](../roadmap/TASK_001_multi-backend-linear-first.md#offline-mirror-semantics).

### `GitHubProjectBackend`

- Requires the hosted GitHub MCP server to be registered in Claude Code (endpoint `https://api.githubcopilot.com/mcp/`, GA since 2025-09). Authentication uses OAuth 2.1 + PKCE — the browser opens for the user to authorize on the first data call; subsequent calls reuse the token. The exact `claude mcp add` registration command and OAuth scope wiring are finalized in task #19c (command extensions); the auth model itself is confirmed and is not TBD.
- **The `projects` toolset is NOT enabled by default.** It must be explicitly enabled and requires the `project` OAuth scope. OAuth scope-filtering hides tools the token lacks permission for — an unscoped token makes the entire Projects v2 toolset appear absent. Treat a missing toolset as a missing scope, not a missing server.
- MCP surface — the **Projects v2 toolset** (consolidated per GitHub changelog 2026-01-28) provides three operations used to fulfil the contract:
  - **Project-list operation** — enumerate Projects visible to the authed user or org.
  - **Project-detail operation** — fetch a project's field definitions (including Status field option ids) and its full item list.
  - **Item-write operation** — create or update items (including draft items) and set/clear field values (including the single-select Status).
- Identity: GitHub Projects v2 item node id (`PVTI_...`), allocated by GitHub on item creation. The local `TASK_NNN` remains the human handle, parallel to `LinearBackend`'s `ENG-123` ↔ `TASK_NNN` parity.
- **Status `stateMap`**: `githubProject.stateMap` in `.roadmap.json`. The Project uses a single-select **Status** field; the stateMap maps each bucket to a set of Status label values. Defaults shipped: `roadmap: ["Backlog", "Todo"]`, `inProgress: ["In Progress"]`, `history: ["Done", "Cancelled"]`. The fixed snake_case-bucket ↔ camelCase-config-key convention (see ⚠ note in _Buckets_ above) applies: bucket `in_progress` ↔ field `githubProject.stateMap.inProgress`.
- **Setting the Status field requires resolving option ids at call time.** Projects v2 requires the `field id` and `option id` (not the human label) when writing a single-select field. The implementation must call the project-detail operation first to map a label like `"In Progress"` to its option id before every item-write that changes Status.
- **Custom fields** — the following custom fields are stored directly on the Project item:
  - `#id` / external id: a text or number field holding the `TASK_NNN` human handle (and optionally the external PR/issue reference).
  - Task type and estimate: custom fields on the Project, populated during `addTask` / `moveTask` as needed.
- **`[ready]` marker** — modeled as a dedicated **Ready** field on the Project (e.g. a boolean or single-select Ready field). It is **not** a Status value — keeping readiness separate from workflow state avoids polluting the Status field with a cross-cutting concern.
- **`blocked_by`** — stored as a plain text field on the Project item. Projects v2 has **no** native dependency or relations field; this is a known limitation. The text field holds a comma-separated list of blocking task ids (e.g. `TASK_003, TASK_005`) as a convention.
- **`isAvailable()`** — inspects the registered MCP server list in Claude Code for a host/name match against `api.githubcopilot.com/mcp`. Returns a boolean. Issues no API call, avoiding OAuth on first use — exactly mirroring the `LinearBackend` pattern.
- **Project and owner selection**: `githubProject.owner` (GitHub org or user login) plus either `githubProject.projectNumber` (the integer shown in the Project URL) or the Project node id, recorded in `.roadmap.json`. Mirrors `LinearBackend`'s `linear.teamId` selection pattern. `/create-roadmap` writes these during setup.
- **Offline mirror**: when `offlineMirror: true`, the skill maintains five local paths (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`, `.plan/`) as a one-way read-only mirror of the Project's state — local-only, never committed, kept out of git via `.git/info/exclude`. The mirror refreshes automatically every time the skill activates. Each local task file carries `backend: github-project` + `backendId: PVTI_...` frontmatter; coherence between local files and remote items is by `backendId`, not by title or slug. See [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md#mirror-auto-refresh-on-activation).
- **History window for refresh**: `githubProject.historyWindow` in `.roadmap.json` (only meaningful with `offlineMirror: true`). Bounds the cost of `listTasks("history")` on every skill activation. Supported values: `"90d"` (default), any `"<N>d"`, a bare integer like `"50"` (last N entries), or `"all"` (no limit). Items outside the window remain accessible via `getTask(id)` on-demand. Same grammar as `linear.historyWindow`. See [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md#mirror-auto-refresh-on-activation) for the full semantics.

### `GitHubIssuesBackend`

- **Requires the `gh` CLI, not any MCP.** This is the one backend in the plugin with no MCP surface at all — every operation shells out to `gh`. Authentication is whatever `gh auth login` has already set up on the machine; the skill never drives an OAuth browser flow for this backend. `isAvailable()` (see above) is a `gh auth status` probe, nothing more.
- Identity: the GitHub Issue number (e.g. `#42`), allocated by GitHub on `gh issue create`. The local `TASK_NNN` remains the human handle, parallel to `LinearBackend`'s `ENG-123` ↔ `TASK_NNN` and `GitHubProjectBackend`'s `PVTI_...` ↔ `TASK_NNN` parity.
- **Bucket → label `stateMap`**: `githubIssues.stateMap` in `.roadmap.json`, same `roadmap` / `inProgress` / `history` keys and snake_case ↔ camelCase translation rule as `linear.stateMap` / `githubProject.stateMap` (see ⚠ note in _Buckets_ above), except each value is a **label name**, not a workflow-state name. Fixed defaults: `roadmap: ["status:roadmap"]`, `inProgress: ["status:in-progress"]`, `history: ["status:done"]`. `moveTask` and `appendHistoryEntry` swap these labels via `gh issue edit --remove-label` / `--add-label`; `appendHistoryEntry` additionally closes the issue (`gh issue close`).
- **Priority labels**: `priority: "P0" | "P1" | "P2"` maps to the labels `priority:P0`, `priority:P1`, `priority:P2` (byte-identical strings, no separate stateMap — these are fixed, not user-configurable, since they mirror the `#5 ROADMAP.md` priority sections directly).
- **`[ready]` marker** — modeled as a dedicated **`ready`** label (lowercase). Not a `status:*` label — keeping readiness orthogonal to bucket placement, the same design reason `GitHubProjectBackend` keeps `Ready` off the Status field. See the `setReady` per-backend note above.
- **`blocked_by`** — GitHub Issues has no native relations/dependency field usable without extra API scopes; as a known limitation, this backend stores `blocked_by` the same way `GitHubProjectBackend` stores it on a Project item: a plain-text convention, here appended as a `**Blocked by:** TASK_003, TASK_005` line in the issue body (outside the `atelier:plan` delimited section) rather than a field. This is a documented limitation, not a contract violation — `blocked_by` round-trips through the issue body, not a structured field.
- **Plan storage**: the plan lives in the issue body, fenced by `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` — identical delimiter strings and rewrite-in-place semantics to `LinearBackend`/`GitHubProjectBackend` (see `setPlan`/`getPlan` per-backend notes above).
- **`isAvailable()`** — `gh` binary present on `PATH` **and** `gh auth status` reports an authenticated session. No Issues API call. See the `isAvailable()` per-backend note above.
- **Repo selection**: `githubIssues.repo` (`"<owner>/<name>"`, e.g. `"acme/widgets"`) in `.roadmap.json` — every `gh issue` invocation passes `--repo <githubIssues.repo>` explicitly rather than relying on the invoking shell's `cwd` remote, so the backend behaves the same whether or not the current directory happens to be a clone of that repo. Mirrors `LinearBackend`'s `linear.teamId` / `GitHubProjectBackend`'s `githubProject.owner` selection pattern. `/create-roadmap` writes this during setup.
- **Label validation before first use** — because labels are free-text and easy to fat-finger (a typo silently creates a look-alike label that no `stateMap` entry matches, quietly breaking `listTasks`), `/create-roadmap`'s `github-issues` setup step runs `gh label list --repo <githubIssues.repo>` and creates any of `status:roadmap`, `status:in-progress`, `status:done`, `ready`, `priority:P0`, `priority:P1`, `priority:P2` that are missing via `gh label create` **before** the config is considered ready. This is the mitigation for the "less-structured-than-a-Project's-custom-fields" risk noted in the task plan — labels have no schema, so the setup step is the closest available approximation to Projects v2's constrained field options.
- **Offline mirror**: when `offlineMirror: true`, identical five-path mechanism (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`, `.plan/`) as `LinearBackend`/`GitHubProjectBackend` — local-only, never committed, kept out of git via `.git/info/exclude`, refreshed automatically on every skill activation. Each local task file carries `backend: github-issues` + `backendId: <issue-number>` frontmatter; coherence is by `backendId`, not title or slug. See [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md#mirror-auto-refresh-on-activation).
- **History window for refresh**: `githubIssues.historyWindow` in `.roadmap.json` (only meaningful with `offlineMirror: true`). Same grammar and defaults as `linear.historyWindow` / `githubProject.historyWindow`: `"90d"` (default), any `"<N>d"`, a bare integer like `"50"`, or `"all"`. Bounds the cost of `listTasks("history")` (a `gh issue list --label status:done --state closed` call) on every skill activation.

## Reverse reconstruction (remote → files)

This section documents the contract for reading the active remote backend in reverse to rebuild a local indexed-`files` layout. It is the shared read path for two consumers:

- **[Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md#mirror-auto-refresh-on-activation)** (SKILL.md) — refreshes a read-only mirror on every skill activation. Uses the default 90-day history window.
- **[`/migrate-roadmap` step 5d](../commands/migrate-roadmap.md)** — full reconstruct + flip authority to local files (removes `.roadmap.json`). Uses `"all"` history semantics (lossless).

The difference between them is the history window and what happens to `.roadmap.json` at the end. The read contract is identical.

### Bucket → file inversion

The _Buckets_ table above maps each bucket forward (files → remote). This table inverts it for the reconstruction pass:

| Bucket | Remote source | Reconstructed local artefact |
| :--- | :--- | :--- |
| `history` | States in `stateMap.history` | `HISTORY.md` entries grouped `## YYYY-MM`, newest first |
| `in_progress` | States in `stateMap.inProgress` | `IN_PROGRESS.md` index link lines |
| `roadmap` | States in `stateMap.roadmap` | `ROADMAP.md` index entries + `roadmap/TASK_NNN_<slug>.md` task files |

`listTasks(bucket)` is called for each of the three buckets; `getTask(id)` is called per task to enrich with body and metadata.

### `backendId`-keyed coherence

During the read pass, local task files are matched to remote items by the `backendId` field in their YAML frontmatter — **not** by title or slug. This is consistent with the forward mirror's coherence rule (decision 3 in [TASK_001](../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions)). Remote items without a matching local file get new `roadmap/TASK_NNN_<slug>.md` files with the next sequential `TASK_NNN` (never reuse numbers).

On the **written** files, `backend` and `backendId` frontmatter is deliberately stripped. The strip is the authority-flip: these fields name the remote as canonical source. Writing local files without them makes the local files the canonical source, with no pointer back to the remote. This is the intended end-state of a full `/migrate-roadmap` 5d run; the mirror-refresh variant does NOT strip them (it keeps them for the next coherence pass).

### Round-trip of tracked fields

| Field (remote) | Remote representation | Files representation |
| :--- | :--- | :--- |
| `Ready` | Linear label `Ready`; GitHub Project `Ready` field; GitHub Issue label `ready` | `[ready]` token on the `ROADMAP.md` index line |
| `blocked_by` | Plain text field on the remote item; GitHub Issue: `**Blocked by:** …` line in the issue body | `blocked_by:` YAML frontmatter in the task file |
| `type` | Custom field on the remote item | `type:` YAML frontmatter in the task file |
| `estimate` | Custom field on the remote item | `estimate:` YAML frontmatter in the task file |
| Status / state | `stateMap` value (e.g. `"In Progress"`); GitHub Issue: `status:*` label | Bucket placement (`IN_PROGRESS.md` / `ROADMAP.md` / `HISTORY.md`) via reverse `stateMap` lookup |
| `plan` | `<!-- atelier:plan:start -->` … `<!-- atelier:plan:end -->` delimited section in the item body / issue description | `.plan/<numeric-id>.md` (e.g. `.plan/6.md`) |

The `stateMap` reverse-lookup maps a remote status label to its bucket: find the bucket whose `stateMap[bucket]` list contains the item's current Status, then write the task into the corresponding local file. The same snake_case ↔ camelCase naming convention (⚠ note in _Buckets_ above) applies.

### Per-bucket safe failure

Each bucket's `listTasks` call is independent. On failure for a single bucket:

- Stop that bucket's reconstruction pass. Do not write the corresponding local file.
- Keep the previous local snapshot for that bucket intact (if any).
- Continue with any remaining buckets that have not yet been attempted — or stop all reconstruction if the implementation chooses a stricter all-or-nothing mode. Either mode must surface per-bucket success/failure clearly.

The remote source is **never mutated** during reconstruction. This read-only-against-remote guarantee is explicitly stronger than the forward migration (5b/5c), which creates remote items.

### Lossiness note

Reconstruction is lossless for the §5 task model: title, body, bucket, `type`, `estimate`, `Ready`, `blocked_by`, and the plan all round-trip. The `atelier:plan` delimited section is **extracted out of** the item body / issue description during reconstruction (so it never bleeds into the written `roadmap/TASK_NNN_*.md` body) and materialized as `.plan/<numeric-id>.md` — lossless. Remote-only metadata is **inherently dropped** because it has no representation in the files layout:

- Backend-native ids (`ENG-123`, `PVTI_...`, GitHub Issue numbers) — stripped per the authority-flip rule above.
- Assignees — no files-layout field.
- Comment threads — no files-layout field (the equivalent is the `## Status` section in indexed task files, populated only by the user going forward).

Both consumers (mirror-refresh and `/migrate-roadmap` 5d) must document this lossiness in their output.

#### `github-issues → files` fidelity

**Preserved (round-trips losslessly within the §5 model):**
- Task title and body.
- `type` and `estimate` frontmatter fields.
- The `TASK_NNN`/`#id` human handle.
- The bucket (via `githubIssues.stateMap` reverse-lookup on the issue's `status:*` label).
- `[ready]` marker (via the `ready` label).
- `blocked_by` (via the `**Blocked by:** …` convention line in the issue body).
- History entries (reconstructed from the `history` bucket items; the issue's closed state is the GitHub-native signal, the `status:done` label is the `stateMap`-driven one this backend reads).
- The plan (`.plan/<id>.md` content folded into the issue body as an `atelier:plan` delimited section on the forward leg; extracted back out to `.plan/<id>.md` on the reverse leg).

**Inherently lossy (no `files` representation — dropped on the authority flip, per the approved §5-scoped lossiness decision):**
- The GitHub Issue number — dropped when `backendId` is stripped; this is the backend-native id for the `github-issues` backend.
- GitHub assignees, comment threads, and any label not covered by the `status:*` / `ready` / `priority:*` conventions.

The `stateMap`-multi-value and `<slug>`-cosmetic caveats above apply equally to this direction.

### Future backends

`JiraBackend`, `TrelloBackend` follow the same contract. Each materialised backend must document:

- Its identity scheme (this doc's _Identity_ table gains a new row).
- Its authentication requirements.
- Its bucket → native-state mapping (this doc's _Buckets_ table gains a new column).
- Its required MCP / API surface.
- Its specifics in a new sub-section here, mirroring the `LinearBackend` notes pattern above.

When a future backend is prioritised, its task file (`roadmap/TASK_NNN_<slug>.md`) updates this document as one of its sub-tasks.

## Versioning

This contract is part of the plugin's public surface. Breaking changes (renaming an operation, changing its arity, redefining an error name) require:

1. A version bump in `.claude-plugin/plugin.json`.
2. A migration note in `HISTORY.md`.
3. A new section in this document describing the migration path.

Non-breaking additions (a new optional field on a task, a new optional metadata key) do **not** require a version bump but must be documented in the relevant operation section.

**v0.8.0** — additive minor bump: `setPlan(id, markdown)` and `getPlan(id)` are new public operations (non-breaking; existing callers are unaffected).

**v0.9.0** — additive minor bump: `GitHubIssuesBackend` is a new backend implementing the full existing contract (non-breaking; existing `files`/`linear`/`github-project` callers are unaffected). It maps one roadmap task to one GitHub Issue via the `gh` CLI, using `status:*` / `ready` / `priority:*` labels in place of a Projects v2 Status field, and reuses the existing `<!-- atelier:plan:start -->` / `<!-- atelier:plan:end -->` plan delimiter and offline-mirror mechanisms verbatim.
