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
    "historyWindow": "90d",
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
- `linear.historyWindow` bounds the cost of refreshing `HISTORY.md` from Linear on every skill activation (only meaningful with `offlineMirror: true`). Defaults to `"90d"`. Supported values: any `"<N>d"`, a bare integer like `"50"` (last N entries), or `"all"` (no limit). Added in sub-task #6 to avoid pulling thousands of historical issues per session on long-running projects. Issues outside the window remain accessible via `getTask(id)` on-demand.

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
- [x] Implement `LinearBackend` — see the new [`## Operations (LinearBackend)`](../skills/roadmap-tracking-flow/SKILL.md#operations-linearbackend) sibling section in `SKILL.md`. Covers state mapping via `linear.stateMap`, ID translation, per-operation MCP tool roles, OAuth-pending awareness in `isAvailable`, atomicity caveat for `appendHistoryEntry` (state change + comment append), and mirror-aware behaviour when `offlineMirror: true`.
- [x] `/create-roadmap` extensions — see [`commands/create-roadmap.md`](../commands/create-roadmap.md). Adds: backend prompt (`files`/`linear`), MCP auto-install via the canonical `claude mcp add` one-liner with OAuth heads-up, Linear team selection via the MCP team-list tool (with `--team` override flag), `.roadmap.json` write (only for `backend: linear`; absence of the file still means `files`), offline-mirror prompt, idempotent `.gitignore` append (only when `.gitignore` already exists at the repo root). Refuses to reconfigure when `.roadmap.json` already exists. Extended `$ARGUMENTS` parsing for `--backend`, `--layout`, `--mirror` / `--no-mirror`, `--team`, with explicit conflict detection.
- [x] `/migrate-roadmap` extensions — see the rewritten [`commands/migrate-roadmap.md`](../commands/migrate-roadmap.md). Adds `--to <files|linear>` flag, the `files (any layout) → linear` direction (Linear setup reused from `/create-roadmap` step 5b, push tasks bucket-by-bucket with on-the-fly layout flip for single-file sources, `backendId` write-back into each task file's frontmatter, atomic `.roadmap.json` checkpoint, mirror branch with idempotent `.gitignore` append or auto-delete of the four local artefacts when `mirror: false`), explicit Direction matrix with "not yet implemented" stubs for `linear → files`, `linear → linear`, and `files (indexed) → files (single-file)`. History entries are migrated to Linear as Done issues (full audit trail). Partial-failure semantics: stop on first push failure, list created Linear ids + unpushed tasks, do not write `.roadmap.json`, do not delete anything; auto-resume deferred to v2. `$ARGUMENTS` parsing extended for `--to`, `--mirror` / `--no-mirror`, `--team`.
- [x] Update the `roadmap-tracking-flow` skill — see the updated [`skills/roadmap-tracking-flow/SKILL.md`](../skills/roadmap-tracking-flow/SKILL.md). Adds: (a) `.roadmap.json` presence as a third activation predicate (closes the transitional gap from sub-task #4 — `linear` + `offlineMirror: false` now auto-activates), (b) new `## Activation: detecting the active backend` section that describes the runtime routing layer (read `.roadmap.json` → pick FilesBackend or LinearBackend → for linear+mirror also run the auto-refresh), and (c) new `## Mirror auto-refresh on activation` section with the refresh procedure, coherence rules, safe failure mode (graceful fallback to local snapshot + warning when MCP is unavailable; per-bucket atomicity if a refresh call fails mid-flow), and the new `linear.historyWindow` knob to bound the cost of refreshing `HISTORY.md` on long-running projects (default `"90d"`).
- [x] Update `README.md` with the new backend selection flow and the offline-mirror caveats — see [`README.md`](../README.md). Adds: activation predicates summary (3 instead of 2), Linear quickstart alongside the files quickstart, new `## Backends` section with one sub-section per backend, full `.roadmap.json` example with field notes (`teamId`, `stateMap`, `historyWindow`, `offlineMirror`), mention of the graceful-fallback behaviour when the Linear MCP is unreachable, layouts-at-a-glance updated to clarify that linear+mirror uses the indexed layout. Design rationale section reframed to include the multi-backend extension (TASK_001) alongside the original extraction (atelier M1.6). No version bump in `plugin.json` — deferred to sub-task #8's final commit when TASK_001 closes.
- [x] Smoke validation — run end-to-end on 2026-05-23 against a real scratch Linear team. **5 PASS / 1 SKIP / 1 NOT-TESTABLE**. See the dated `## Status` entry below for the full report and the 4 spec gaps it surfaced (all fixed in this same PR).
  - Happy path: clean repo → `/create-roadmap --backend linear` → tasks appear in Linear; mirror enabled → files appear locally with `backend: linear` + `backendId` set. **✅ PASS**
  - MCP missing: same flow → plugin auto-installs MCP via the canonical command, warns about OAuth. **✅ PASS** (covered by the same session as the happy path; one observation: OAuth browser did not auto-open; Claude Code required a restart to surface the new MCP tools — likely a Linear MCP / Claude Code integration quirk; filed as observation, not a plugin bug).
  - MCP install fails: clear error, no half-state in `.roadmap.json`. **⏸ SKIP** — impractical to engineer naturally; validated via spec walkthrough only.
  - Existing files-only repo → `/migrate-roadmap --to linear` → every task arrives in Linear with original titles/bodies; local frontmatter gets `backend: linear` + `backendId` rewritten in place; `.gitignore` updated when mirror enabled. **✅ PASS** (surfaced 4 spec gaps fixed by this PR — see Status entry below).
  - Existing repo without `.gitignore` → mirror enabled → plugin does not create `.gitignore` or `.git`. **✅ PASS** (validated harness-side as scenario A of the smoke report).
  - Activation freshness: open a new Claude Code session on a Linear-backed mirrored repo → local files reflect Linear's current state (not the previous session's snapshot). **✅ PASS**
  - Linear API down at activation → previous local snapshot retained, user warned. **⏸ NOT TESTABLE** — bare network outage kills Claude itself (Claude CLI needs `anthropic.com` connectivity), so the targeted partial-outage scenario (Anthropic up + Linear down) cannot be triggered with a simple WiFi toggle. Validated via spec walkthrough only.

## Notes

- The future backends (GitHub Issues, Jira, Trello) listed in `ROADMAP.md` Low Priority intentionally do **not** get their own task files yet. They become real `TASK_NNN_*.md` entries when a user prioritises one and we have enough detail to fill the file.
- v1 ships **one backend per repo**. Mixing backends within the same `.roadmap.json` is deferred. The frontmatter is forward-compatible (per-file `backend` field) so adding mixed mode later is non-breaking.
- Documentation lives in `README.md`, `CLAUDE.md`, or `docs/` (ADRs). Anything in `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` (and `roadmap/TASK_NNN_*.md`) is task tracking, not documentation.

## Status

### 2026-05-23 — TASK_001 CLOSED — smoke validation + spec fixes + v0.2.0

Sub-task #8 delivered. End-to-end smoke validation ran against a real scratch Linear team. Result: **5 PASS / 1 SKIP / 1 NOT-TESTABLE**. The validation surfaced **4 spec gaps in `/migrate-roadmap`**, all fixed in this same PR (so TASK_001 closes with a clean spec, not with known issues).

#### Smoke matrix results

| # | Scenario | Result | Notes |
| :- | :--- | :--- | :--- |
| 1+2 | Happy path + MCP auto-install | ✅ PASS | `.roadmap.json` written correctly with `historyWindow: "90d"` and full default `stateMap`; mirror files + empty `roadmap/` created; `.gitignore` correctly NOT created (didn't exist before). Side observations: OAuth browser did not auto-open; Claude required restart to surface MCP tools (Linear MCP integration quirk, not a plugin bug). |
| 3 | MCP install fails → no half-state | ⏸ SKIP | Impractical to engineer naturally. Spec walkthrough confirms behaviour. |
| 4 | `files → linear` migration | ✅ PASS functional | 3 tasks pushed correctly (Done → In Progress → Backlog ordering preserved per spec); `backendId` written into each task file's frontmatter; `.gitignore` 4 lines appended without duplicating pre-existing entries. **Surfaced 4 spec gaps** — see "Spec fixes shipped in this PR" below. |
| 5 | Repo without `.gitignore` + mirror | ✅ PASS | Validated harness-side. Spec is unambiguous and there is no path to deviate. |
| 6 | Activation freshness | ✅ PASS | New issue created manually in Linear → fresh Claude session refreshed local mirror and surfaced the new task. |
| 7 | Linear API down → graceful fallback | ⏸ NOT TESTABLE | Bare network outage takes Claude itself offline. The targeted partial-outage (Anthropic up + Linear down) is hard to simulate with simple WiFi toggle. Spec walkthrough during PR #10 pre-merge review confirmed behaviour. |

Plus harness-side: scenarios B1 (linear → files refusal), B2 (argument conflicts), B3 (orphan-`backendId` detection from PR #9), C1 (schema fields consistent across 4 docs), C2 (cross-link integrity — 44 links, 0 failures after filtering code fences + comments), C3 (JSON snippets parse — 3 valid, 1 pseudo-JSON skip), D1 (12/12 expected files present), D2 (`claude plugin validate` exit 0). All ✅ PASS.

#### Spec fixes shipped in this PR

The smoke run for scenario 4 produced a `.roadmap.json` that deviated from the spec on 4 points. All 4 are fixed in the same commit as this status entry, so TASK_001 closes with a clean spec:

| Gap | Severity | Fix |
| :-- | :--- | :--- |
| **A** — `historyWindow` was omitted from `/migrate-roadmap`'s `.roadmap.json` (was present in `/create-roadmap`'s). | 🟡 cosmetic | `commands/migrate-roadmap.md` step 5b.6 now **inlines the full `.roadmap.json` template** instead of just linking to `/create-roadmap`. The LLM-following-spec has the exact JSON to copy. |
| **B** — `/migrate-roadmap`'s output used `"in_progress": [...]` (snake_case) instead of `"inProgress"` (camelCase). The skill's auto-refresh looks for `linear.stateMap.inProgress` and would miss the snake_case variant — **the only real bug that could break runtime**. | 🔴 real bug | Added an explicit naming-convention callout in `docs/RoadmapBackend.md` (Buckets section) and `skills/roadmap-tracking-flow/SKILL.md` (Operations (LinearBackend) preamble); strengthened the language in both `/create-roadmap` and `/migrate-roadmap` Linear-setup steps to say _"bucket `in_progress` ↔ field `linear.stateMap.inProgress`"_ explicitly. The mismatch is intentional (snake_case for programmatic identifiers, camelCase for JSON config) but was previously implicit, which let LLMs deviate. |
| **C** — `/migrate-roadmap`'s `.roadmap.json` had trimmed `stateMap` defaults (one state per bucket instead of the two-state defaults `["Backlog", "Todo"]` / `["Done", "Cancelled"]`). | 🟡 cosmetic | Both `/create-roadmap` and `/migrate-roadmap` step 5b.6 now say _"Ship the full `linear.stateMap` defaults exactly as in the template — do not trim alternatives down to just the state the user happens to be using"_ explicitly. |
| **D** — `/migrate-roadmap` re-ran `claude mcp add` even though MCP was already registered (and Claude Code surfaced a "tools not visible yet; please restart" message even though the MCP was healthy). | 🟡 UX | Both `/create-roadmap` and `/migrate-roadmap` now say _"If already registered ... **skip the install entirely** — do not re-run `claude mcp add`, even though it would be technically idempotent. ... Proceed directly to the next step."_ with explicit reasoning about why re-running causes noise. |

#### Out-of-scope follow-ups noted during testing

These are NOT spec gaps in this plugin; they're observations to track elsewhere:

- **Approval-fatigue during runtime**: the maintainer observed that `file creation`, `mcp list`, and similar routine tool calls all prompted for approval, breaking the autonomous-flow expectation. This is governed by Claude Code's `settings.json` permission allowlist, which is configured by the **atelier** project (separate repo), not by this plugin. Atelier's `settings.template.json` should expand its allowlist to cover these patterns for operator-profile installations.
- **OAuth browser non-launch + restart-required-to-see-MCP-tools**: observed during scenario 1+2. Looks like an integration quirk between Claude Code's MCP startup and Linear's hosted MCP server. Worth filing upstream if reproducible across machines.

#### Version bump

`.claude-plugin/plugin.json` bumped to **`0.2.0`** in this same PR. SemVer minor bump justified by: new `linear` backend, new `.roadmap.json` config file, new operations vocabulary (`linear.stateMap`, `linear.historyWindow`, `linear.teamId`, `offlineMirror`), and new behaviours in both slash commands. No breaking change for `files`-only users — the absence of `.roadmap.json` continues to mean `backend: files`, and the legacy `single-file → indexed` migration path under `/migrate-roadmap` is preserved verbatim under step 5a.

#### Closing actions (this PR)

- Sub-task #8 marked `[x]` above with the full result inline.
- TASK_001 link removed from `IN_PROGRESS.md`.
- New entry added to `HISTORY.md` summarising the task and linking back to this file as the canonical record (per indexed-layout convention: task file stays as source of truth for what was delivered; HISTORY entry is concise).
- This PR (`#12`) is the final one. Closes TASK_001.

### 2026-05-23 — `README.md` updated for multi-backend

Sub-task #7 delivered. Reworked [`README.md`](../README.md) to reflect everything that landed in sub-tasks #1–#6. Concretely:

- **Intro**: now mentions both backends and the optional Linear-backend offline mirror.
- **"It packages"** bullets: reframed `/create-roadmap`, `/migrate-roadmap`, and the skill to describe their multi-backend behaviour. Added a 3-predicate activation summary.
- **Install**: unchanged shape, but the surrounding text is consistent with the new world.
- **Quick start**: split into two sub-sections, `files` (legacy default, same as before) and `linear` (six steps covering the full MCP-install + OAuth + team-pick + mirror prompt flow).
- **New `## Backends` section**: dedicated sub-section per backend, with a complete `.roadmap.json` example and field-by-field notes (including `linear.historyWindow`'s supported values).
- **Layouts at a glance**: ASCII diagram annotated to clarify that the linear+mirror case uses the indexed layout.
- **Design rationale**: reframed to include TASK_001 (the multi-backend extension) alongside the original `atelier` PR #10 extraction, with the dogfooding angle explicit.

Maintainer-confirmed decisions captured during this PR:

- **Linear framing**: presented as a first-class backend, no "experimental" disclaimer. Smoke validation pending (sub-task #8) but the spec and code are complete.
- **No version bump**: `plugin.json` stays at `0.1.0` in this PR. The bump to `0.2.0` lands in the final commit that closes TASK_001 (sub-task #8) for symbolic alignment.

Last remaining sub-task: **#8 — Smoke validation matrix**. That PR will close TASK_001 entirely, moving it from `IN_PROGRESS.md` to `HISTORY.md` per the plugin's own pre-merge tracking rule.

### 2026-05-23 — Skill runtime routing + mirror auto-refresh on activation

Sub-task #6 (`Update the roadmap-tracking-flow skill`) delivered. Three frentes resueltos en [`skills/roadmap-tracking-flow/SKILL.md`](../skills/roadmap-tracking-flow/SKILL.md):

1. **Third activation predicate** added in `## When this skill applies`: `.roadmap.json` presence at the repo root now also triggers the skill. This **closes the transitional gap** noted in PR #7 (sub-task #4): `backend: linear` + `offlineMirror: false` repos that had no local tracking files were previously invisible to the auto-activation flow. The skill's `description` frontmatter was also updated so Claude Code's skill-picker text matches the new behaviour.
2. **Runtime routing layer** documented in a new `## Activation: detecting the active backend` section. On every activation: read `.roadmap.json` (or default to `files` if absent) → pick the matching Operations section → for `linear + mirror`, run the auto-refresh as part of activation. Layout detection for files is unchanged.
3. **Mirror auto-refresh on activation** documented in a new `## Mirror auto-refresh on activation` section. Covers:
   - **Pre-check via `isAvailable()`** (no API call → no OAuth trigger).
   - **Graceful fallback** when MCP unreachable: skill still activates, reads the existing local snapshot, surfaces a clear warning with snapshot timestamp + reconnection command. Read-only operations work against the snapshot; writes throw `backend-unavailable` until MCP is restored. (Decision confirmed with the maintainer for this PR.)
   - **Refresh procedure**: `listTasks` per bucket in order (roadmap → in_progress → history), regenerate local files, match by `backendId` (decision 3), flag orphan local task files without deleting (user decides).
   - **Per-bucket atomicity**: if a `listTasks` call fails, that bucket's local files keep the previous snapshot; other buckets' refreshes that already completed stay applied; surface partial-state clearly.
   - **History window** to bound refresh cost on long-running projects: new `linear.historyWindow` config knob, defaults to `"90d"`, supports `"<N>d"`, bare integer (`"50"`), or `"all"`. (Decision confirmed with the maintainer.) Issues outside the window stay accessible via `getTask(id)` on-demand — the contract is unchanged.

Schema extension in this PR: `linear.historyWindow` added to the config schema in this task file, in [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md) LinearBackend notes, and in the `.roadmap.json` template inside [`commands/create-roadmap.md`](../commands/create-roadmap.md). The three are kept in sync.

Bundled cleanup: removed the obsolete "transitional note" from [`commands/create-roadmap.md`](../commands/create-roadmap.md) step 7 that warned the skill didn't yet auto-activate on `linear + no mirror` — that warning is no longer true after this PR. Replaced with a one-sentence positive confirmation. (Decision confirmed with the maintainer.)

Next sub-tasks: **#7 — README update** (the install / Quick start sections need to mention backend selection + Linear option), then **#8 — smoke validation** (the matrix originally listed in this task; some items already covered ad-hoc during sub-tasks 4/5/6 reviews, but a structured pass is still owed).

### 2026-05-23 — Spec-gap fix: orphan-`backendId` precondition check

Follow-up to [PR #8](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/8). Pre-merge smoke tests of PR #8 surfaced a gap between intent and implementation in `/migrate-roadmap`:

- Step 5b.5 declared _"refuse to retry the migration with `.roadmap.json` absent and some `backendId`s already written; tell the user to reconcile manually and re-run a clean migration."_
- But step 1 (preconditions) did **not** scan for that state. So a partial-failure → re-run on the orphan repo state would skip the refusal and re-push every task, **creating duplicate Linear issues** for the ones already pushed before the failure.

This PR closes the gap by adding an explicit orphan-state detection bullet to step 1: when `.roadmap.json` is absent AND `roadmap/` exists, the command scans `roadmap/TASK_NNN_*.md` files for `backendId` in YAML frontmatter. If any are found, refuse to proceed and instruct the user to clean up (delete the orphan task files + optionally the matching Linear issues, or strip the `backendId` frontmatter to re-include those tasks in a fresh migration).

Sub-task #5 retains its `[x]` — the gap was found via testing PR #8 itself, not a regression introduced afterwards. The next sub-task (#6 — skill reads `.roadmap.json` + routing layer) is unchanged.

### 2026-05-22 — `/migrate-roadmap` extended for cross-backend migrations

Sub-task #5 (`/migrate-roadmap` extensions) delivered. Rewrote [`commands/migrate-roadmap.md`](../commands/migrate-roadmap.md) to support two migration directions in v1:

- **`files (single-file) → files (indexed)`** — current behavior preserved verbatim under step 5a; the legacy callers of this command keep working unchanged.
- **`files (any layout) → linear`** — new path under step 5b. Reuses the Linear setup procedure from `/create-roadmap` step 5b (MCP install + OAuth + team picker + mirror prompt), then parses every task across the three buckets, pushes them to Linear in bucket order (history first, then in_progress, then roadmap), writes `backendId` back into each task file's frontmatter, and either keeps the local files as a mirror (with `.gitignore` append) or deletes them automatically (when `mirror: false`).

Decisions confirmed with the maintainer for this PR:

- **History migration policy**: history entries are pushed to Linear as Done issues, preserving full audit trail. The trade-off (Linear project starts with N closed issues) was accepted.
- **Local files post-migration with `mirror: false`**: auto-delete at the end (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/` recursive). This destructive operation is **previewed in step 5b.3's migration plan** so the user sees it before approving the migration.
- **Auto-flip layout for single-file source** (default I took without asking): when source is single-file and target is linear, the command builds a virtual indexed view in memory, then writes `roadmap/TASK_NNN_*.md` per task as part of the push. No separate "single-file → indexed → linear" two-step required.
- **Partial-failure semantics** (default I took without asking): stop on first push failure, list created Linear ids + unpushed tasks, **do not write `.roadmap.json` and do not delete any local files**. Auto-resume deferred to v2.
- **`.roadmap.json` is the atomic checkpoint**: only written after every Linear push succeeds.

`$ARGUMENTS` parsing extended for `--to`, `--mirror` / `--no-mirror`, `--team`, with explicit conflict detection (e.g. `--to files --mirror` errors out). A `## Direction matrix` table documents what's supported and what errors out as "not yet implemented" so unsupported directions never silently fall back.

Next sub-task: **#6 — Update the `roadmap-tracking-flow` skill** to (a) read `.roadmap.json` on activation, (b) route operations through the backend abstraction (instead of hardcoded file ops), (c) auto-refresh the local mirror from Linear on activation when `backend: linear` + `offlineMirror: true`. This is the PR that **closes the transitional gap** from sub-task #4: today, `backend: linear` with `mirror: false` does not auto-activate the skill because the activation predicate is "presence of all three tracking files". Sub-task #6 adds `.roadmap.json` presence as a third activation predicate and wires the routing layer.

### 2026-05-22 — `/create-roadmap` extended for backend selection

Sub-task #4 (`/create-roadmap` extensions) delivered. Reworked [`commands/create-roadmap.md`](../commands/create-roadmap.md):

- **`## Behavior`** rewritten as a numbered flow with explicit branches per backend (5a files, 5b linear). Both branches converge in steps 6 (report) and 7 (skill activation reminder).
- **Backend-first prompt order** (decision confirmed with the maintainer for this PR): the command asks `files` vs `linear` first; for `linear` it skips the layout question (mirror is always indexed).
- **Linear setup flow**: detect MCP registration → install with `claude mcp add --transport http linear-server https://mcp.linear.app/mcp` if missing (with OAuth browser heads-up) → call MCP team-list (this is what triggers OAuth on first ever use) → interactive team picker → offline-mirror prompt → write `.roadmap.json` → if mirror is on, create the three tracking files + empty `roadmap/`, and append four lines to `.gitignore` **only if it already exists** (idempotent, no duplicates).
- **`backend: files` writes no `.roadmap.json`** — the absence of the file is the signal for the default backend. Keeps existing files-only repos clean.
- **Idempotency**: when `.roadmap.json` already exists, the command echoes the current config and stops — does not reconfigure silently. `/migrate-roadmap` is the path for switching backends later.
- **`$ARGUMENTS`** parsing extended for `--backend`, `--layout`, `--mirror` / `--no-mirror`, `--team`, with explicit conflict detection (e.g. `--backend linear --layout single-file` errors out instead of silently picking a winner). Three concrete examples included in the doc, from fully-interactive to fully non-interactive.
- **New `.roadmap.json` template** added next to the existing markdown templates.
- **Transitional note** in step 7: `linear + offlineMirror: false` does **not** yet auto-activate the skill (its activation predicate today is "presence of all three tracking files"). The skill is still reachable via the second activation predicate ("user explicitly references the flow"). Sub-task #6 adds `.roadmap.json` presence as a third predicate to close this gap.

Next sub-task: `/migrate-roadmap` extensions (sub-task #5) — `--to` flag, `files → linear` migration with ID write-back, "not yet implemented" stubs for other directions.

### 2026-05-22 — `LinearBackend` instructions documented in `SKILL.md`

Sub-task #3 (`Implement LinearBackend`) delivered. Added a new sibling section [`## Operations (LinearBackend)`](../skills/roadmap-tracking-flow/SKILL.md#operations-linearbackend) in `SKILL.md` with per-operation instructions for all six operations: state-map resolution, Linear MCP tool roles (issue-list, issue-fetch, issue-create, issue-update, comment-create), ID translation, OAuth-pending awareness in `isAvailable` (no API call → no browser prompt), and the atomicity caveat for `appendHistoryEntry` (Linear state change is atomic, comment append is a separate call → retry once, surface warning, do not revert state). Mirror-aware behaviour described per operation for `offlineMirror: true`.

The `## Backend protocol` header was updated to reflect that both backends are now documented in this file. The parenthetical at the end of `FilesBackend.isAvailable()` was updated to cross-link to the new `LinearBackend` section.

Next sub-task: `/create-roadmap` extensions (sub-task #4) — backend selection prompts, Linear team selection, `.roadmap.json` write, MCP auto-install via the canonical one-liner, mirror opt-in, `.gitignore` append.

### 2026-05-22 — `FilesBackend` expressed against the contract

Sub-task #2 (`Implement FilesBackend against the new interface`) delivered. Refactored [`skills/roadmap-tracking-flow/SKILL.md`](../skills/roadmap-tracking-flow/SKILL.md) to organize its instructions around the six operations of the `RoadmapBackend` contract (`listTasks`, `getTask`, `addTask`, `moveTask`, `appendHistoryEntry`, `isAvailable`). Behaviour is preserved verbatim — single-file vs indexed detection, the numbering convention, the pre-merge tracking rule, and every format convention stay as they were. The reorganization adds a `## Backend protocol` section pointing at [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md) as the canonical spec, and surfaces one previously-implicit rule that proved load-bearing during the Test 3 smoke check of [PR #4](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/4): in indexed layout, "what's in progress?" answers come from the task file's `## Status` section, **not** from `IN_PROGRESS.md` (which only holds the link).

Next sub-task: `LinearBackend` instructions in `SKILL.md` (per-operation notes for the Linear MCP path), followed by the `/create-roadmap` and `/migrate-roadmap` command extensions.

### 2026-05-22 — Kickoff

Task moved from `ROADMAP.md` to `IN_PROGRESS.md`. First sub-task delivered: the `RoadmapBackend` contract is documented in [`docs/RoadmapBackend.md`](../docs/RoadmapBackend.md). Sub-task checklist above updated. The PR opening this status note also adds a follow-up to `ROADMAP.md` Low Priority for an observation surfaced during the Test 5 smoke check of [PR #3](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/3) (skill should explicitly point at `/create-roadmap` when the flow predicate fires on a repo without tracking files, instead of letting the assistant find a substitute file).

Next sub-task: refactor `skills/roadmap-tracking-flow/SKILL.md` to organize its instructions around the `RoadmapBackend` contract for `FilesBackend` (today's behaviour expressed against the new abstraction, no behaviour change for current users).
