# TASK_001 — Multi-backend support (Linear first)

Today `claude-roadmap-tools` enforces its `ROADMAP → IN_PROGRESS → HISTORY` flow strictly against three local Markdown files at the repo root (and, in indexed layout, a `roadmap/TASK_NNN_*.md` per task). This task extends the plugin so the same flow can run against other task trackers, with **Linear** as the first concrete backend. Future backends (GitHub Issues, Jira, Trello) get tracked in `ROADMAP.md` under Low Priority and will land in follow-up tasks once this foundation is in place.

## Goal

A user can:

1. Pick a backend per repository via a `.roadmap.json` config file (default `"files"`, keeps current behaviour).
2. Select `"linear"` and have the plugin auto-install Linear's MCP server when missing, then drive task state changes through it.
3. Optionally turn on an **offline mirror** when using a remote backend (Linear): the three Markdown files (and `roadmap/TASK_NNN_*.md`) are kept locally as a read-only-ish mirror, with each file linked to its Linear issue by a stable ID stored in the file's frontmatter.
4. Run `/migrate-roadmap` to switch backend on an existing repo (e.g. `files` → `linear`), preserving every task by ID-based mapping.

## Design decisions (resolved)

- **Config file name**: `.roadmap.json` at the repo root.
- **`/migrate-roadmap` scope**: extended to be cross-backend, not just single-file → indexed. Same command handles both shapes of migration.
- **Mirror coherence**: ID-based. Each task file in the offline mirror carries the remote backend's task ID in its YAML frontmatter (`backendId: "<linear-issue-id>"`). The local `TASK_NNN` number remains the human-friendly handle; the backend ID is the canonical identity for syncing.

## Open design decisions (resolve during work)

- **Linear MCP auto-install mechanism**: which command does the plugin run to install it? Candidates: `claude mcp add linear ...`, an `install.sh`-like setup script, or a documented pre-flight. Confirm one before writing code.
- **What invokes the install**: a hook fired by the skill on first activation, or an explicit step in `/create-roadmap` when the user picks `linear`? Leaning toward the second (explicit, surfaceable to the user).
- **Mirror direction(s)**: when Linear is the backend, is the mirror **read-only** (Linear is source of truth, local files regenerate on `git pull`/refresh) or **read-write with conflict policy** (edits in either place sync back)? Leaning toward read-only in v1 to avoid sync nightmares; revisit once usage data exists.
- **Refresh model for the mirror**: pull-on-demand (`/refresh-roadmap`), pull on skill activation, or background polling? Leaning toward explicit `/refresh-roadmap` for v1.
- **Frontmatter shape on task files**: `backendId` only, or also `backend: "linear" | "files"`, `lastSyncedAt`, etc.? Keep minimal at first.
- **`.gitignore` semantics for the mirror**: when offline mirror is enabled, do we add `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/` to `.gitignore`, or only the latter two? `ROADMAP.md` is often committed as project documentation even when the source of truth lives elsewhere — confirm with the user during implementation.

## Config schema (`.roadmap.json`)

Minimum viable shape; extend as backends are added.

```json
{
  "backend": "files" | "linear",
  "offlineMirror": false,
  "linear": {
    "teamId": "<team-uuid>",
    "stateMap": {
      "roadmap":    ["Backlog", "Todo"],
      "inProgress": ["In Progress"],
      "history":    ["Done", "Cancelled"]
    }
  }
}
```

- `backend` is required. Anything other than `"files"` requires the matching sub-object (`linear` for `"linear"`).
- `offlineMirror` defaults to `false`. Ignored when `backend` is `"files"` (the files *are* the source of truth).
- `linear.stateMap` lets users customize which Linear states correspond to each bucket — Linear workflows vary by team.

## Backend abstraction

The skill `roadmap-tracking-flow` and the two slash commands talk to a single `RoadmapBackend` interface. Each backend implementation lives in its own module and is selected by the config. v1 ships two implementations: `FilesBackend` (today's behaviour) and `LinearBackend`. Future backends implement the same contract.

Minimum surface (concrete signatures decided during work):

- `listTasks(bucket)` — list tasks in `roadmap` / `inProgress` / `history`.
- `getTask(id)` — fetch one task by canonical ID.
- `addTask(task)` — create a new task in the `roadmap` bucket.
- `moveTask(id, fromBucket, toBucket)` — atomic move; errors if `id` is not in `fromBucket`.
- `appendHistoryEntry(id, prMetadata)` — log completion with PR link, delivered bullets, tests.
- `isAvailable()` — for remote backends, check MCP connectivity without performing any mutating call.

## Linear backend specifics

- **MCP detection**: before any operation, `LinearBackend.isAvailable()` checks the Linear MCP is reachable. If not, the skill / command tells the user and offers to install it.
- **Auto-install**: when the user picks `linear` during `/create-roadmap` (or via direct config edit followed by the next operation) and the MCP is missing, run the install non-interactively. On failure, surface the exact recovery commands instead of half-completing.
- **State mapping**: defaults provided in the config schema above; users override per-team.
- **Identifiers**: Linear assigns issue IDs like `ENG-123`. That string is what gets written into `backendId` in the offline mirror's task-file frontmatter.

## Offline mirror semantics

- Activated by `offlineMirror: true` in `.roadmap.json` when a non-`files` backend is configured.
- File layout matches indexed mode: `ROADMAP.md` (index), `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/TASK_NNN_<slug>.md` per task. Each task file's frontmatter carries `backendId`.
- **`.gitignore` behaviour**: when enabling the mirror, the plugin checks for `.gitignore` at the repo root. If it exists, the plugin adds the mirror paths to it (Linear is the source of truth, so committing the mirror would create merge headaches). If `.gitignore` does not exist, the plugin does **nothing** (the user may not be using git — that is a valid setup; do not auto-create `.gitignore` or `.git`).
- **Coherence**: on refresh, the plugin matches existing local task files to remote issues by `backendId`, not by title or slug. New remote tasks get new local files with the next sequential `TASK_NNN`. Local tasks whose `backendId` no longer exists remotely are flagged but not auto-deleted (user decides).

## Command behaviour changes

- **`/create-roadmap`**: gains a `--backend <files|linear>` argument (still asks interactively if absent). When `linear` is picked, it also asks for the Linear team, writes `.roadmap.json`, offers the offline mirror, and triggers MCP install if needed.
- **`/migrate-roadmap`**: re-scoped. Detects current backend from `.roadmap.json` (or absence of it) and accepts `--to <backend>`. Performs the move:
  - `files` → `linear`: pushes every existing task into Linear, captures the new `backendId`s, writes them back into the local files' frontmatter, and rewrites `.roadmap.json`.
  - `files` (single-file layout) → `files` (indexed layout): current behaviour, unchanged.
  - Other directions surface "not yet implemented" rather than silently doing nothing.

## Skill (`roadmap-tracking-flow`) changes

- At activation, read `.roadmap.json` if present and pick the backend. Without the file, behave exactly as today (`files` backend, indexed or single-file depending on directory layout).
- All operations route through the `RoadmapBackend` interface — no hardcoded file ops outside `FilesBackend`.
- Pre-merge tracking rule still applies, expressed against the backend abstraction (`appendHistoryEntry` + remove from `inProgress` bucket atomically).

## Sub-tasks

- [ ] Confirm the open design decisions above before writing code.
- [ ] Design and document the `RoadmapBackend` interface (separate file in the plugin once the structure is decided).
- [ ] Implement `FilesBackend` against the new interface (refactor of today's logic, no behaviour change for current users).
- [ ] Implement `LinearBackend` (state mapping, ID translation, error surfaces).
- [ ] Linear MCP auto-install path: detection + install command + failure messaging.
- [ ] Extend `/create-roadmap` with backend selection + Linear-specific prompts + mirror opt-in + `.gitignore` handling.
- [ ] Extend `/migrate-roadmap` with the `--to` flag and the `files → linear` migration (other directions stay "not yet implemented").
- [ ] Update the `roadmap-tracking-flow` skill to read `.roadmap.json` and route through the abstraction.
- [ ] Update `README.md` with the new backend selection flow and the offline-mirror caveats.
- [ ] Smoke validation:
  - Happy path: clean repo → `/create-roadmap --backend linear` → tasks appear in Linear; offline mirror toggled on → files appear locally with `backendId` set.
  - MCP missing: same flow → plugin auto-installs MCP and continues.
  - MCP install fails: clear error, no half-state in `.roadmap.json`.
  - Existing files-only repo → `/migrate-roadmap --to linear` → every task arrives in Linear with original titles/bodies; local frontmatter gets `backendId`s.
  - Existing repo without `.gitignore` → mirror enabled → plugin does not create `.gitignore` or `.git`.

## Notes

- The future backends (GitHub Issues, Jira, Trello) listed in `ROADMAP.md` Low Priority intentionally do **not** get their own task files yet. They become real `TASK_NNN_*.md` entries when a user prioritises one and we have enough detail to fill the file. This avoids pre-staging scaffolds that the maintainer must later flesh out from scratch.
- Out of scope for v1: bidirectional sync (Linear ↔ local edits both ways), background polling, conflict resolution UI. The mirror is one-way (remote → local) on explicit refresh.

## Status

_Not started. Open design decisions above must be resolved (with the user) before writing implementation code._
