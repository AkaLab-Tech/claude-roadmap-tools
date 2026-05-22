# TASK_001 — Multi-backend support (Linear first)

Today `claude-roadmap-tools` enforces its `ROADMAP → IN_PROGRESS → HISTORY` flow strictly against three local Markdown files at the repo root (and, in indexed layout, a `roadmap/TASK_NNN_*.md` per task). This task extends the plugin so the same flow can run against other task trackers, with **Linear** as the first concrete backend. Future backends (GitHub Issues, Jira, Trello) get tracked in `ROADMAP.md` under Low Priority and will land in follow-up tasks once this foundation is in place.

## Goal

A user can:

1. Pick a backend per repository via a `.roadmap.json` config file (default `"files"`, keeps current behaviour).
2. Select `"linear"` and have the plugin auto-install Linear's MCP server when missing, then drive task state changes through it.
3. Optionally turn on a one-way **offline mirror** (Linear → local) when using a remote backend. The Markdown files refresh automatically every time the skill activates. Each task file links to its Linear issue via `backend` + `backendId` in its YAML frontmatter.
4. Run `/migrate-roadmap` to switch backend on an existing repo (e.g. `files` → `linear`), preserving every task by ID-based mapping.

## Design decisions

All design decisions resolved before implementation begins. No open items remain in the planning phase — new questions surface only during implementation if an assumption breaks.

| # | Decision | Choice |
| :- | :--- | :--- |
| 1 | Config file name | `.roadmap.json` at the repo root. |
| 2 | `/migrate-roadmap` scope | Extended to be **cross-backend** (`files → linear`, etc.), not just single-file → indexed. |
| 3 | Mirror coherence strategy | **ID-based**. Each local task file carries `backend` + `backendId` in its YAML frontmatter. The local `TASK_NNN` number stays the human handle; the backend ID is the canonical identity for syncing. |
| 4 | MCP auto-install mechanism | Claude Code's native `claude mcp add` CLI command. |
| 5 | Linear MCP install one-liner | `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` (Linear distributes the MCP as a remote HTTP server at `https://mcp.linear.app/mcp`; auth is OAuth 2.1 with dynamic client registration — browser opens on first tool call). |
| 6 | Install trigger | `/create-roadmap`. Explicit during setup, not a lazy hook on the skill. |
| 7 | Mirror direction (v1) | **Read-only** / one-way (Linear → local). Linear is the source of truth; local files get rewritten on refresh. Editing a local file with your editor is **not** the way to move tasks — use the plugin commands or change state in Linear directly. |
| 8 | Refresh model (v1) | **Automatic on skill activation**. Every time `roadmap-tracking-flow` activates in a Linear-backed repo with mirror enabled, the plugin pulls latest state from Linear and rewrites the local files. No background polling, no explicit `/refresh-roadmap` command in v1. |
| 9 | Frontmatter shape | `backend` + `backendId` (two fields). Sync timestamps and remote URLs deferred to v2 if they prove useful. |
| 10 | `.gitignore` behaviour | When the mirror is enabled and `.gitignore` exists, the plugin appends `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/` to it. If `.gitignore` does **not** exist, the plugin does nothing — the user may not be using git, which is a valid setup. Project documentation lives in `README.md`, `CLAUDE.md`, or `docs/` (ADRs), not in the tracking files. |
| 11 | Out of scope for v1 | Bidirectional sync, conflict resolution UI, background polling, an explicit `/refresh-roadmap` command, multi-backend within the same repo (one repo = one backend). |

## Config schema (`.roadmap.json`)

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

The full contract — operation signatures, error semantics, atomicity rules, identity scheme per backend — lives in [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md). Summary of the minimum surface:

- `listTasks(bucket)` — list tasks in `roadmap` / `in_progress` / `history`.
- `getTask(id)` — fetch one task by canonical ID.
- `addTask(task)` — create a new task in the `roadmap` bucket.
- `moveTask(id, fromBucket, toBucket)` — atomic move; errors if `id` is not in `fromBucket`. Moving INTO `history` is forbidden here — use `appendHistoryEntry` instead.
- `appendHistoryEntry(id, prMetadata)` — atomic operation enforcing the pre-merge tracking rule: remove from `in_progress` and add structured entry to `history` in one shot.
- `isAvailable()` — connectivity check; must be cheap and side-effect-free.

## Linear backend specifics

- **Distribution**: Linear publishes its MCP as a centrally-hosted remote HTTP server at `https://mcp.linear.app/mcp`. Not an npm package; nothing to install locally beyond the Claude Code MCP registration.
- **Install command** (decision 5): `claude mcp add --transport http linear-server https://mcp.linear.app/mcp`. Runs once per machine. Idempotent at the plugin layer (`/create-roadmap` checks first and skips if already registered).
- **Auth**: OAuth 2.1 with dynamic client registration. The browser opens for the user to authorize on first tool call; subsequent calls reuse the token. `/create-roadmap` tells the user to expect that browser prompt before triggering any Linear operation.
- **MCP detection**: before any operation, `LinearBackend.isAvailable()` checks that a Linear MCP is registered (matching the `mcp.linear.app` host or a known name). If not, the operation halts with a clear error pointing at the auto-install path.
- **State mapping**: defaults in the config schema above; users override per-team via `linear.stateMap`.
- **Identifiers**: Linear assigns issue IDs like `ENG-123`. That string is what gets written into `backendId` in the offline mirror's task-file frontmatter.

## Offline mirror semantics

- Activated by `offlineMirror: true` in `.roadmap.json` when a non-`files` backend is configured.
- File layout matches indexed mode: `ROADMAP.md` (index), `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/TASK_NNN_<slug>.md` per task. Each task file's frontmatter carries `backend: linear` + `backendId: <linear-issue-id>`.
- **Direction** (decision 7): one-way (Linear → local). The plugin rewrites local files from Linear's state. Editing a local file with your editor is **not** a supported way to change task state — your edit gets overwritten on the next refresh.
- **Refresh trigger** (decision 8): the `roadmap-tracking-flow` skill, when activating in a repo whose `.roadmap.json` has `backend: linear` and `offlineMirror: true`, pulls latest state from Linear and rewrites the local files. Activation already happens on every Claude Code session that opens this repo, so "freshness" matches session boundaries. No explicit `/refresh-roadmap` command in v1.
- **`.gitignore`** (decision 10): when enabling the mirror, the plugin checks for `.gitignore` at the repo root. If it exists, the plugin appends `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/` to it. If `.gitignore` does **not** exist, the plugin does nothing (no auto-creation; the user may be working without git, which is a valid setup).
- **Coherence** (decision 3): on refresh, the plugin matches existing local task files to remote issues by `backendId`, not by title or slug. New remote tasks get new local files with the next sequential `TASK_NNN`. Local tasks whose `backendId` no longer exists remotely are flagged but not auto-deleted (user decides).

## Command behaviour changes

- **`/create-roadmap`**: gains a `--backend <files|linear>` argument (still asks interactively if absent). When `linear` is picked, it:
  1. Asks for the Linear team (or auto-detects via Linear MCP if a Linear MCP is already registered and authenticated).
  2. Writes `.roadmap.json` with the chosen backend, state map, and `offlineMirror` toggle.
  3. If the Linear MCP is not already registered, runs `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` and warns the user that a browser will open for OAuth on the next Linear operation.
  4. If the user opted into the mirror, appends the four paths to `.gitignore` (only when `.gitignore` already exists — decision 10).
- **`/migrate-roadmap`**: re-scoped. Detects current backend from `.roadmap.json` (or absence of it) and accepts `--to <backend>`. Performs the move:
  - `files` → `linear`: pushes every existing task into Linear, captures the new `backendId`s, writes them back into each local file's frontmatter (along with `backend: linear`), updates `.roadmap.json`, and handles `.gitignore` if the user enables the mirror as part of the migration.
  - `files` (single-file layout) → `files` (indexed layout): current behaviour, unchanged.
  - Other directions surface "not yet implemented" rather than silently doing nothing.

## Skill (`roadmap-tracking-flow`) changes

- On activation, read `.roadmap.json` if present and pick the backend. Without the file, behave exactly as today (`files` backend, indexed or single-file depending on directory layout).
- When `backend: linear` and `offlineMirror: true`, the skill **pulls latest state from Linear and rewrites the local files** as part of activation (decision 8). On Linear API errors during refresh, the skill surfaces the failure and keeps the previous local snapshot — never half-writes.
- All operations route through the `RoadmapBackend` interface — no hardcoded file ops outside `FilesBackend`.
- Pre-merge tracking rule still applies, expressed against the backend abstraction (`appendHistoryEntry` + remove from `inProgress` bucket atomically).

## Sub-tasks

- [x] Design and document the `RoadmapBackend` interface — see [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md).
- [x] Implement `FilesBackend` against the new interface — see the refactored [`skills/roadmap-tracking-flow/SKILL.md`](../skills/roadmap-tracking-flow/SKILL.md). No behaviour change for current users; instructions reorganized around the six operations of the contract.
- [ ] Implement `LinearBackend` (state mapping, ID translation, error surfaces, OAuth-pending awareness).
- [ ] `/create-roadmap` extensions: backend selection prompts, Linear team selection, `.roadmap.json` write, MCP auto-install via the canonical one-liner, mirror opt-in, `.gitignore` append.
- [ ] `/migrate-roadmap` extensions: `--to` flag, `files → linear` migration with ID write-back, "not yet implemented" stubs for other directions.
- [ ] Update the `roadmap-tracking-flow` skill: (a) read `.roadmap.json`, (b) route operations through the backend abstraction, (c) auto-refresh local mirror from Linear on activation when applicable, with safe failure mode.
- [ ] Update `README.md` with the new backend selection flow and the offline-mirror caveats.
- [ ] Smoke validation:
  - Happy path: clean repo → `/create-roadmap --backend linear` → tasks appear in Linear; mirror enabled → files appear locally with `backend: linear` + `backendId` set.
  - MCP missing: same flow → plugin auto-installs MCP via the canonical command, warns about OAuth.
  - MCP install fails: clear error, no half-state in `.roadmap.json`.
  - Existing files-only repo → `/migrate-roadmap --to linear` → every task arrives in Linear with original titles/bodies; local frontmatter gets `backend: linear` + `backendId` rewritten in place; `.gitignore` updated when mirror enabled.
  - Existing repo without `.gitignore` → mirror enabled → plugin does not create `.gitignore` or `.git`.
  - Activation freshness: open a new Claude Code session on a Linear-backed mirrored repo → local files reflect Linear's current state (not the previous session's snapshot).
  - Linear API down at activation → previous local snapshot retained, user warned.

## Notes

- The future backends (GitHub Issues, Jira, Trello) listed in `ROADMAP.md` Low Priority intentionally do **not** get their own task files yet. They become real `TASK_NNN_*.md` entries when a user prioritises one and we have enough detail to fill the file.
- v1 ships **one backend per repo**. Mixing backends within the same `.roadmap.json` is deferred. The frontmatter is forward-compatible (per-file `backend` field) so adding mixed mode later is non-breaking.
- Documentation lives in `README.md`, `CLAUDE.md`, or `docs/` (ADRs). Anything in `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` (and `roadmap/TASK_NNN_*.md`) is task tracking, not documentation.

## Status

### 2026-05-22 — `FilesBackend` expressed against the contract

Sub-task #2 (`Implement FilesBackend against the new interface`) delivered. Refactored [`skills/roadmap-tracking-flow/SKILL.md`](../skills/roadmap-tracking-flow/SKILL.md) to organize its instructions around the six operations of the `RoadmapBackend` contract (`listTasks`, `getTask`, `addTask`, `moveTask`, `appendHistoryEntry`, `isAvailable`). Behaviour is preserved verbatim — single-file vs indexed detection, the numbering convention, the pre-merge tracking rule, and every format convention stay as they were. The reorganization adds a `## Backend protocol` section pointing at [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md) as the canonical spec, and surfaces one previously-implicit rule that proved load-bearing during the Test 3 smoke check of [PR #4](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/4): in indexed layout, "what's in progress?" answers come from the task file's `## Status` section, **not** from `IN_PROGRESS.md` (which only holds the link).

Next sub-task: `LinearBackend` instructions in `SKILL.md` (per-operation notes for the Linear MCP path), followed by the `/create-roadmap` and `/migrate-roadmap` command extensions.

### 2026-05-22 — Kickoff

Task moved from `ROADMAP.md` to `IN_PROGRESS.md`. First sub-task delivered: the `RoadmapBackend` contract is documented in [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md). Sub-task checklist above updated. The PR opening this status note also adds a follow-up to `ROADMAP.md` Low Priority for an observation surfaced during the Test 5 smoke check of [PR #3](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/3) (skill should explicitly point at `/create-roadmap` when the flow predicate fires on a repo without tracking files, instead of letting the assistant find a substitute file).

Next sub-task: refactor `skills/roadmap-tracking-flow/SKILL.md` to organize its instructions around the `RoadmapBackend` contract for `FilesBackend` (today's behaviour expressed against the new abstraction, no behaviour change for current users).
