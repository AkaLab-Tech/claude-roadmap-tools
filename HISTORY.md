# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-07

### TASK_003 — GitHub Issues backend — 2026-07-13
**PR:** [#34](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/34)

Adds the fourth `RoadmapBackend` implementation — `GitHubIssuesBackend`, mapping one roadmap task to one GitHub Issue via the `gh` CLI, following the contract already implemented by `LinearBackend` (TASK_004/M9.1) and `GitHubProjectBackend` (M9.2). Rounds out the multi-backend foundation opened by TASK_001 with the lightest-weight remote option (plain Issues + labels, no Projects v2 board required).

**Delivered:**
- `docs/RoadmapBackend.md` — new `GitHubIssuesBackend` Identity row, Buckets column, all 9 per-operation bullets (`listTasks`, `getTask`, `addTask`, `moveTask`, `appendHistoryEntry`, `setReady`/`getReady`, `setPlan`/`getPlan`, `isAvailable`), per-backend-notes sub-section, `github-issues → files` reverse-reconstruction fidelity table, v0.9.0 Versioning note.
- `skills/roadmap-tracking-flow/SKILL.md` — backend routing/activation/mirror-refresh extended for `github-issues`, new `## Operations (GitHubIssuesBackend)` section.
- `commands/create-roadmap.md` — `github-issues` backend setup step, `.roadmap.json` template, Arguments section.
- `commands/migrate-roadmap.md` — `files → github-issues` forward leg, `github-issues → files` reverse leg (5d engine), Direction matrix.
- `.claude-plugin/plugin.json` bumped to **`0.9.0`** (additive minor — new backend; existing `files`/`linear`/`github-project` callers unaffected).

**Tests:** prose/JSON coherence — no test runner (pure-prose plugin). `plugin.json` valid JSON at v0.9.0 (`python3 -m json.tool` exit 0); 9-point coherence suite green (delimiter/label byte-consistency, cross-links, direction-matrix completeness, backend-parity regression, end-to-end spec walkthrough, isAvailable contract).

### TASK_007 — Offline mirror is local-only, not `.gitignore`-tracked — 2026-07-09
**PR:** [#33](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/33)

Fixes a gap left by TASK_006 (backend-resident plans): the offline-mirror **write** side for `LinearBackend`/`GitHubProjectBackend` (`addTask`, `moveTask`, `appendHistoryEntry`, `setReady`, `setPlan`) never got a local-only treatment. `/create-roadmap` and `/migrate-roadmap` wired the mirror paths into the committed `.gitignore` instead of `.git/info/exclude`, and `.plan/<id>.md` was missing from both lists entirely — so a resident-plan repo kept committing `.plan/<id>.md` on every `setPlan` call, riding real PRs for a file nothing on origin reads. Reported by the operator ("me crea PRs para tareas nuevas... lo mismo cuando planifica tareas") and confirmed live in `AkaLab-Tech/atelier-dev` (PRs #314, #315 committed 8 `.plan/*.md` files each, the day before this fix).

**Delivered:**
- `skills/roadmap-tracking-flow/SKILL.md` — new "Offline mirror writes are local-only" section (shared invariant for both remote backends), cross-referenced from every offline-mirror write note and from "Things this skill does NOT do".
- `docs/RoadmapBackend.md` — `setPlan` per-backend notes and the two "offline mirror" bullets updated: five local paths (was four, `.plan/` added), local-only via `.git/info/exclude`.
- `commands/create-roadmap.md` — steps 5b.6/5c.6 write `.git/info/exclude` (five lines) instead of the committed `.gitignore`.
- `commands/migrate-roadmap.md` — steps 5b.7/5c.7 same mechanism; the `mirror: true` branch now also `git rm --cached`s any of the five paths already tracked from before this fix (one-time untracking, surfaced in the report).
- `.claude-plugin/plugin.json` bumped to **`0.8.1`** (patch — bugfix, no new operations).

**Tests:** prose/JSON coherence — no test runner (pure-prose plugin). `plugin.json` valid JSON at 0.8.1 (`python3 json.tool` exit 0). Grepped the repo for stray `.gitignore` mentions tied to the offline mirror — none left.

**Follow-ups:**
- Companion fix in `AkaLab-Tech/atelier` ([#320](https://github.com/AkaLab-Tech/atelier/pull/320)) untracks the 42 `.plan/*.md` already committed in `atelier-dev` before this fix existed, and needs `.git/info/exclude` updated locally in that checkout (this PR fixes the tool going forward; existing checkouts still need the one-time exclude-file edit since it's never committed).

### TASK_006 — RoadmapBackend.setPlan/getPlan (backend-resident plans) — 2026-07-01
**PR:** [#31](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/31)

Extends the `RoadmapBackend` contract with `setPlan(id, markdown)` and `getPlan(id)` — the two operations atelier needs to keep task plans backend-resident on remote backends (Linear, GitHub Projects v2), rather than in ephemeral local files. Motivated by the atelier requirement that `plan-task` call `backend.setPlan` so a plan survives a worktree teardown and `next-task` call `backend.getPlan` on re-entry.

**Delivered:**
- `docs/RoadmapBackend.md` — new `setPlan` and `getPlan` operation specs for all three backends (FilesBackend / LinearBackend / GitHubProjectBackend), delimiter semantics (`<!-- atelier:plan:start/end -->`, missing → empty, duplicate → first-match wins), and round-trip entry in the Reverse reconstruction table.
- `skills/roadmap-tracking-flow/SKILL.md` — matching `setPlan/getPlan` sub-sections for FilesBackend, LinearBackend, and GitHubProjectBackend; mirror-refresh reconstruction rule updated to strip and materialize the `atelier:plan` delimited section out of the body during per-task file writes.
- `commands/migrate-roadmap.md` — forward legs (files → linear, files → github-project) fold `.plan/<id>.md` into the item body as a delimited section; the reverse leg (5d) strips it back out and materializes `.plan/<id>.md`; lossiness note updated to include plan.
- `.claude-plugin/plugin.json` bumped to **`0.8.0`** (additive minor — two new public operations; existing callers unaffected).

**Tests:** prose/JSON coherence — no test runner (pure-prose plugin). `plugin.json` valid JSON at v0.8.0 (python3 json.tool exit 0). Delimiter strings byte-consistent across all four files. All 7 acceptance criteria confirmed by tester inspection.

**Follow-ups:**
- atelier implementation: `plan-task` calls `backend.setPlan(id, plan)` after composing the plan; `next-task` calls `backend.getPlan(id)` on re-entry. Tracked in [atelier](https://github.com/AkaLab-Tech/atelier) as the consumer of this contract addition.

## 2026-06

### TASK_002 — `/adopt-roadmap` command — 2026-06-03
**PR:** [#14](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/14)

Adds the third initialization command, filling the gap between `/create-roadmap` (no tracking yet) and `/migrate-roadmap` (canonical tracking → other backend/layout). `/adopt-roadmap` normalizes a repo whose tracking files **exist but are not canonical** — most commonly an `IN_PROGRESS.md` used as a multi-phase tracker (`RLS`, `ADMIN`, `WEB`, `i18n` with `[x]`/`[ ]`) — into `ROADMAP → IN_PROGRESS → HISTORY` without losing content. This unblocks single-active-task tooling (e.g. atelier's `/next-task`) that treats any non-placeholder `IN_PROGRESS.md` as permanently occupied. See [`roadmap/TASK_002_adopt-roadmap-command.md`](roadmap/TASK_002_adopt-roadmap-command.md).

**Delivered:**
- New `commands/adopt-roadmap.md` — files-backend-only normalization: preconditions (refuse `linear`; nothing-to-adopt → `/create-roadmap`; already-canonical → stop), classification (`[x]`/done → `history`, `[ ]`/open → `roadmap`, explicit-active → `in_progress`, ambiguous → ask, **never drop**), editable adoption plan, single-diff apply, abort-leaves-no-partial-state.
- Reuses `/create-roadmap` templates verbatim; adds only a relaxed "adopted history entry (no PR / no date)" shape so legacy done-items are recorded without fabricating PRs or dates.
- `README.md` updated to list the third command.
- `.claude-plugin/plugin.json` bumped to **`0.3.0`** (additive — new command, no breaking changes).

**Tests:** spec walkthrough against a phase-tracker `IN_PROGRESS.md` — open items route to `roadmap`, done items to `history`, the slot resets to the empty placeholder; never-drop and never-fabricate rules verified by inspection. `claude plugin validate` exit 0.

**Follow-ups:**
- atelier integration: `/setup-project` gains detection of a phase-tracker `IN_PROGRESS.md` and offers to delegate to `/adopt-roadmap`. Tracked in [atelier](https://github.com/AkaLab-Tech/atelier).

## 2026-05

### Skill: point at `/create-roadmap` on non-tracking repos (Test 5 follow-up) — 2026-05-23
**PR:** [#13](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/13)

Closes the last bullet in `ROADMAP.md` Low Priority — the _"Tighten `SKILL.md` activation behaviour on non-tracking repos"_ follow-up surfaced during the Test 5 smoke check of [PR #3](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/3) (and re-confirmed during TASK_001's pre-merge testing as not-blocking-but-real).

Previously, when predicate 3 of the activation rules fired alone (the user mentioned the flow on a repo without the three tracking files and without `.roadmap.json`), the skill was silent on what to do, and the assistant tended to substitute another markdown file in the repo (e.g. `REFACTORING_OPPORTUNITIES.md`) by extracting priorities from it as if it were the roadmap. Per the skill's own _Initialization_ section, the correct behaviour is to point the user at `/create-roadmap` and stop. This PR makes that behaviour explicit.

**Delivered:**
- New **Special case** paragraph in `skills/roadmap-tracking-flow/SKILL.md` `## When this skill applies` describing the predicate-3-fires-alone case and the correct response.
- New bullet in `## Things this skill does NOT do` cross-referencing the rule.
- ROADMAP.md Low Priority bullet removed (the work is now in HISTORY).
- `plugin.json` bumped to **v0.2.1** (patch — corrected behaviour, no new features, no breaking changes).

**Tests:** spec walkthrough re-verifies the Test 5 scenario from PR #3 against the new SKILL.md. Activation predicate matrix resolves the same way for predicates 1+2; only the "predicate 3 alone" path changes from _silent substitute file extraction_ to _pointer to `/create-roadmap`_.

**Follow-ups:** none. With this PR, `ROADMAP.md` Low Priority contains only the 3 future-backend bullets — all other tracked items are either in HISTORY (delivered) or deliberately deferred to v2 per TASK_001 design decisions.

### TASK_001 — Multi-backend support (Linear first) — 2026-05-23
**PR:** [#12](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/12) (closes TASK_001; full implementation across PRs [#3](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/3), [#4](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/4), [#5](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/5), [#6](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/6), [#7](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/7), [#8](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/8), [#9](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/9), [#10](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/10), [#11](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/11), and this one).

Ships **v0.2.0**: multi-backend support with `files` (markdown at the repo root, default) and `linear` (via the [Linear MCP](https://linear.app/docs/mcp)) backends, optional offline mirror with auto-refresh on skill activation, end-to-end migration from files to Linear, and runtime routing in the skill via `.roadmap.json`. The plugin dogfoods its own tracking flow on its own development. See [`roadmap/TASK_001_multi-backend-linear-first.md`](roadmap/TASK_001_multi-backend-linear-first.md) for the full record (design decisions, every sub-task delivery, smoke matrix results, spec fixes).

**Delivered:**
- New abstract contract [`docs/RoadmapBackend.md`](docs/RoadmapBackend.md) — identity, buckets, six operations (`listTasks`, `getTask`, `addTask`, `moveTask`, `appendHistoryEntry`, `isAvailable`), atomicity, error semantics, per-backend notes.
- `skills/roadmap-tracking-flow/SKILL.md` reorganised around the contract — separate `## Operations (FilesBackend)` and `## Operations (LinearBackend)` sections; new `## Activation: detecting the active backend` (runtime routing layer reads `.roadmap.json`) and `## Mirror auto-refresh on activation` (refresh procedure, graceful fallback when MCP unreachable, per-bucket atomicity, configurable history window).
- `commands/create-roadmap.md` rewritten — backend prompt, MCP auto-install with OAuth heads-up, team picker via MCP, mirror opt-in, idempotent `.gitignore` append, refuse-to-reconfigure on existing `.roadmap.json`, extended `$ARGUMENTS` parsing.
- `commands/migrate-roadmap.md` rewritten — `--to <backend>` flag, `files → linear` direction with bucket-ordered push and `backendId` write-back, Direction matrix with "not yet implemented" stubs, orphan-`backendId` precondition (added in PR #9 after a pre-merge smoke test caught a spec gap).
- `README.md` rewritten for multi-backend — quickstart per backend, complete `.roadmap.json` example with field-by-field notes.
- `.claude-plugin/plugin.json` bumped to **`0.2.0`**.

**Tests:** end-to-end smoke validation against a real scratch Linear team — 5 PASS (happy path, MCP auto-install, files→linear migration, repo-without-`.gitignore` non-creation, activation freshness), 1 SKIP (MCP install fails — impractical to engineer naturally), 1 NOT TESTABLE (Linear API down with Claude still online — bare network outage kills Claude itself; partial-outage simulation deferred). Harness-side: spec-coherence checks (schema field consistency across 4 docs, 44 markdown cross-links, JSON snippet validity, file-structure regression, `claude plugin validate` exit 0) — all PASS. The smoke run surfaced 4 spec gaps in `/migrate-roadmap` (`historyWindow` omitted from output, `in_progress`/`inProgress` JSON-key naming confusion, `stateMap` defaults trimmed, MCP install ran when already registered) — **all 4 fixed in this same PR** so v0.2.0 closes with a clean spec.

**Follow-ups:**
- Approval-fatigue observed during live testing (file creation, `mcp list`, etc. all prompted for approval). Tracked in [atelier](https://github.com/AkaLab-Tech/atelier) — the operator-profile `settings.template.json` should expand its allowlist for autonomous flow.
- OAuth browser flow did not auto-open on first MCP call; Linear MCP install required a Claude restart to surface tools. Likely a Linear MCP / Claude Code integration issue. Worth filing upstream if reproducible across machines.
- Future backends (`GitHubIssuesBackend`, `JiraBackend`, `TrelloBackend`) remain under Low Priority in [`ROADMAP.md`](ROADMAP.md). Each will reuse the now-stable `RoadmapBackend` contract.

<!-- ## YYYY-MM

### Example title — YYYY-MM-DD
**PR:** [#N](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/N)

One- or two-sentence framing of why this PR existed.

**Delivered:**
- Bullet 1
- Bullet 2

**Tests:** one line on the validation done.

**Follow-ups:** (optional)
- Bullet
-->
