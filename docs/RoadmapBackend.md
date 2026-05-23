# `RoadmapBackend` — backend contract

The `RoadmapBackend` is the abstract contract every storage backend in `claude-roadmap-tools` implements. The `roadmap-tracking-flow` skill, `/create-roadmap`, and `/migrate-roadmap` all operate against this contract — they do not call file or Linear APIs directly.

v1 ships two backends:

- **`FilesBackend`** — markdown files at the repo root, today's behaviour, default.
- **`LinearBackend`** — Linear issues, via the Linear MCP server. Selected by `.roadmap.json`.

Future backends (`GitHubIssuesBackend`, `JiraBackend`, `TrelloBackend`) implement the same contract.

> ⚠️ **The plugin is 100% markdown.** This document is the contract the **skill** follows; the "implementation" of each backend is the set of instructions the skill applies when that backend is active. There is no executable code in the plugin — the function-style signatures below are a specification of inputs, outputs, and behaviour, not a reference to a runtime API.

This contract is the canonical reference. The matching task plan (with goals, sub-tasks, and decisions) lives in [`roadmap/TASK_001_multi-backend-linear-first.md`](../roadmap/TASK_001_multi-backend-linear-first.md).

## Concepts

### Identity

Every task has a single canonical `id` per backend.

| Backend | Canonical `id` | Notes |
| :--- | :--- | :--- |
| `FilesBackend` | `TASK_NNN` (e.g. `TASK_001`) | Sequential, zero-padded to three digits, never reused (per the indexed-layout numbering rule in `skills/roadmap-tracking-flow/SKILL.md`). |
| `LinearBackend` | Linear issue ID (e.g. `ENG-123`) | Allocated by Linear on issue creation. |
| _Future_ | Backend-native ID | Each future backend documents its scheme in this table. |

When the offline mirror is enabled (Linear backend + `.roadmap.json` has `offlineMirror: true`), each local task file's YAML frontmatter carries both:

```yaml
---
backend: linear
backendId: ENG-123
---
```

The local `TASK_NNN` stays the **human handle** (for filenames and the index in `ROADMAP.md`); `backendId` is the **canonical identity for sync** operations against Linear. See decision 9 in [TASK_001](../roadmap/TASK_001_multi-backend-linear-first.md#design-decisions).

### Buckets

Three abstract buckets — backends map each one to native concepts:

| Bucket | Meaning | `FilesBackend` | `LinearBackend` |
| :--- | :--- | :--- | :--- |
| `roadmap` | Backlog. Tasks awaiting prioritization or start. | `ROADMAP.md` (or index entries in indexed layout). | Linear states matching `linear.stateMap.roadmap` (defaults: `Backlog`, `Todo`). |
| `in_progress` | Active work. Tasks moved here when work actually begins. | `IN_PROGRESS.md`. | States matching `linear.stateMap.inProgress` (default: `In Progress`). |
| `history` | Completed work, append-only log. | `HISTORY.md`, newest first, grouped by `## YYYY-MM`. | States matching `linear.stateMap.history` (defaults: `Done`, `Cancelled`). |

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

### `getTask(id)`

- **Inputs** — canonical `id`.
- **Returns** — the full task: `id`, `title`, `body`, `priority`, current bucket, backend-specific metadata.
- **Side effects** — none.
- **Errors** — throws `task-not-found` if the id is unknown. Backend unavailable throws.
- **`FilesBackend`** — reads `roadmap/TASK_NNN_*.md` when in indexed layout; otherwise extracts the task block from the bucket file in single-file layout.
- **`LinearBackend`** — calls the Linear MCP issue-fetch tool with the issue id.

### `addTask(task)`

- **Inputs** — a task with at least `{ title, body }`. Optional `priority`.
- **Returns** — the created task, with `id` assigned by the backend.
- **Side effects** — the task is now in the `roadmap` bucket.
- **Errors** — invalid input (missing `title`) throws. Backend rejection (e.g. Linear team permission) throws.
- **`FilesBackend`** — allocates the next sequential `TASK_NNN` (highest existing + 1), writes `roadmap/TASK_NNN_<slug>.md`, and inserts the bullet under the appropriate priority section in `ROADMAP.md`. In single-file layout, writes the task block directly into `ROADMAP.md`.
- **`LinearBackend`** — calls the Linear MCP issue-create tool with team, title, body, and an initial state from `linear.stateMap.roadmap[0]`.

### `moveTask(id, fromBucket, toBucket)`

- **Inputs** — `id`, `fromBucket`, `toBucket`. Both `fromBucket` and `toBucket` must be in `{"roadmap", "in_progress"}`. Moving INTO `history` is forbidden in this operation — use `appendHistoryEntry` instead.
- **Returns** — the moved task.
- **Side effects** — task is now in `toBucket`; no longer in `fromBucket`.
- **Atomicity** — the move is **atomic**: either both side effects succeed or none happen. Backends that cannot guarantee a single-transaction update must implement compensation (e.g. `FilesBackend` writes both files within one edit set so the diff is reviewable as a single unit).
- **Errors** — throws `task-not-in-from-bucket` if `id` is not currently in `fromBucket` (prevents race conditions and wrong assumptions). Throws `move-into-history-forbidden` if `toBucket == "history"`.
- **`FilesBackend`** — edits `ROADMAP.md` and `IN_PROGRESS.md` together in one change set. The `roadmap/TASK_NNN_*.md` file is **not** moved or renamed — only the index entries change.
- **`LinearBackend`** — calls the Linear MCP issue-update tool, changing the issue's state to the first state listed in `linear.stateMap[toBucket]`.

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

### `isAvailable()`

- **Inputs** — none.
- **Returns** — `true` or `false`.
- **Side effects** — **must not mutate any state and must not trigger interactive flows** (e.g. OAuth). The skill is allowed to call `isAvailable` on every activation.
- **Errors** — must not throw on routine connectivity issues; just returns `false`. Throws only on programmer errors (e.g. backend instance not initialized).
- **`FilesBackend`** — always returns `true`. The filesystem is the backend.
- **`LinearBackend`** — checks that a Linear MCP server is registered in Claude Code (matching the `mcp.linear.app` host or a known server name like `linear-server`). Returns `false` if not. Does **not** issue any Linear API call — that would trigger OAuth on first ever use.

## Error semantics

- All operations **throw on error**; the skill catches and surfaces a human-readable message. **No silent failures.**
- An operation that partially succeeds must clean up before throwing. Half-written files or half-moved Linear states are not acceptable.
- Error names are stable strings (e.g. `task-not-found`, `task-not-in-from-bucket`, `move-into-history-forbidden`, `task-not-in-progress`, `backend-unavailable`) so the skill can branch on them.
- `isAvailable()` is the only operation that surfaces "backend not reachable" as a boolean instead of an exception. Every other operation throws `backend-unavailable` when `isAvailable()` would have returned `false`.

## Atomicity and rollback

- **`moveTask`** and **`appendHistoryEntry`** are atomic. Backends that touch multiple resources implement compensation if their underlying API does not provide transactions.
  - `FilesBackend`: bundles all file edits into a single change set so the user reviews and commits them as one unit. If the user rejects partway, no files are left touched.
  - `LinearBackend`: each operation maps to a single Linear API call (state change), so atomicity is provided by Linear's transactional state update. The risk is for `appendHistoryEntry` where PR metadata is appended as a comment after the state change — if the comment append fails the state is already moved; the skill should re-try the comment and surface a warning if it cannot, but **not** revert the state.

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
- Offline mirror: when `offlineMirror: true`, the skill maintains the four local paths (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`) as a one-way read-only mirror of Linear's state. The mirror refreshes automatically every time the skill activates. See [TASK_001 — Offline mirror semantics](../roadmap/TASK_001_multi-backend-linear-first.md#offline-mirror-semantics).

### Future backends

`GitHubIssuesBackend`, `JiraBackend`, `TrelloBackend` follow the same contract. Each materialised backend must document:

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
