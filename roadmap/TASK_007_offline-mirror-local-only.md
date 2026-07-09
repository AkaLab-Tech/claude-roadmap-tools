# TASK_007 — Offline mirror is local-only, not `.gitignore`-tracked

Fix a gap in TASK_006's backend-resident plans: the offline-mirror write side (`addTask`, `moveTask`, `appendHistoryEntry`, `setReady`, `setPlan`) for `LinearBackend`/`GitHubProjectBackend` never established that the local mirror files must stay untracked by git. `/create-roadmap` and `/migrate-roadmap` wired the mirror paths into the **committed** `.gitignore` instead of a local-only mechanism, and `.plan/<id>.md` was never added to either list at all — so a resident-plan repo kept committing `.plan/<id>.md` on every `setPlan` call, riding real PRs for a file nothing on origin reads (observed live in `AkaLab-Tech/atelier-dev`, PRs #314/#315).

## Goal

For any remote backend (`linear`/`github-project`) with `offlineMirror: true`, every local mirror write — `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`, **and `.plan/<id>.md`** — must be local-only: never tracked, never committed, never riding a PR. `/create-roadmap` and `/migrate-roadmap` must set this up via `.git/info/exclude`, not the committed `.gitignore`, and untrack anything already tracked.

## Sub-tasks

- [x] `skills/roadmap-tracking-flow/SKILL.md` — new "Offline mirror writes are local-only" section (shared invariant for `LinearBackend`/`GitHubProjectBackend`); cross-referenced from every write-op's offline-mirror note and from "Things this skill does NOT do".
- [x] `docs/RoadmapBackend.md` — `setPlan` per-backend notes and the two "offline mirror" bullets updated: five paths (was four), local-only via `.git/info/exclude`.
- [x] `commands/create-roadmap.md` — steps 5b.6/5c.6 write `.git/info/exclude` (five lines, including `.plan/`) instead of `.gitignore`.
- [x] `commands/migrate-roadmap.md` — steps 5b.7/5c.7 same mechanism; `mirror: true` branch now also `git rm --cached`s any of the five paths that are already tracked (one-time untracking, surfaced in the report).
- [x] Bump `.claude-plugin/plugin.json` (patch — bugfix, no new operations).

## Notes

- The `mirror: false` deletion path (four artefacts: `ROADMAP.md`/`IN_PROGRESS.md`/`HISTORY.md`/`roadmap/`) is unaffected — `.plan/<id>.md` is only ever written when `offlineMirror: true`, so there is nothing to delete for it in the `false` case.
- `FilesBackend`'s committed `.plan/<id>.md` is unaffected — this only concerns the two remote backends' *offline-mirror copy* of a plan that is otherwise resident in the issue/item body.
- Companion fix landed in `AkaLab-Tech/atelier` (PR #320): untracks the 42 `.plan/*.md` files already committed in `atelier-dev` before this fix existed.

## Status

Delivered directly (fix + HISTORY entry in the same PR) — reported by the operator, root-caused and shipped in one session.
