# TASK_003 — GitHub Issues backend

Map ROADMAP/IN_PROGRESS/HISTORY to GitHub repo issues + labels (`status:roadmap`, `status:in-progress`, `status:done`), following the `RoadmapBackend` contract (`docs/RoadmapBackend.md`) already implemented by `LinearBackend` (M9.1) and `GitHubProjectBackend` (M9.2).

## Approach

1. **Mapping.** One roadmap task → one GitHub Issue. Bucket → labels `status:roadmap` / `status:in-progress` / `status:done`, swapped via `gh issue edit --add-label/--remove-label` on `moveTask`. Priority (P0/P1/P2) → labels `priority:P0` etc. `Ready` → a dedicated `ready` label.
2. **Plan storage.** Plan lives in the issue body's delimited `<!-- atelier:plan:start -->`/`<!-- atelier:plan:end -->` section, per the backend-resident-plans pattern (`setPlan`/`getPlan`).
3. **`listTasks`/`getTask`.** `gh issue list --label status:roadmap --json number,title,body,labels` / `gh issue view <n> --json ...`, translated into the `RoadmapBackend` task-record shape.
4. **Offline mirror.** Reuse the existing offline-mirror mechanism (`.roadmap.json` → `offlineMirror: true`, local-only via `.git/info/exclude`).
5. **Command wiring.** Extend `/create-roadmap --backend github-issues` and `/migrate-roadmap` per the existing backend-selection pattern.

## Sub-tasks

- [ ] `GitHubIssuesBackend` implements the full `RoadmapBackend` contract (`listTasks`, `getTask`, `moveTask`, `appendHistoryEntry`, `setReady`/`getReady`, `setPlan`/`getPlan`).
- [ ] `docs/RoadmapBackend.md` — new `GitHubIssuesBackend` section.
- [ ] `skills/roadmap-tracking-flow/SKILL.md` — backend routing extended.
- [ ] `commands/create-roadmap.md` / `commands/migrate-roadmap.md` — `github-issues` backend wiring.
- [ ] Offline mirror works per the existing pattern.
- [ ] New smoke/regression tests mirroring the existing `github-project` backend suite.
- [ ] Bump `.claude-plugin/plugin.json`.

## Notes

- Full plan and risks: see `.plan/3.md` (approved 2026-07-07).
- Open question carried from planning: whether this backend duplicates value already covered by `github-project` closely enough that building it isn't worth the ~6h before a real requester exists.
