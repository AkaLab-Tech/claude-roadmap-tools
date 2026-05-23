# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

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
