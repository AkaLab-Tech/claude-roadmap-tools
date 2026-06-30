# TASK_006 — `RoadmapBackend.setPlan` / `getPlan`

Add plan storage/retrieval to the `RoadmapBackend` contract so a consumer (atelier) can keep the task **plan** resident in the backend for remote backends, instead of requiring a committed `.plan/<id>.md` file in the repo.

## Goal

atelier wants, for any non-`files` backend, the roadmap truth AND the plan to live only in the backend — nothing required in `files`. The roadmap content already lives in the backend; the missing piece is the **plan artifact**. Add two operations, mirroring the existing `setReady` pattern (`docs/RoadmapBackend.md`):

- `setPlan(id, markdown)` — store the plan markdown for task `id` in the backend.
- `getPlan(id)` — return the stored plan markdown for task `id` (or empty/none if absent).

## Sub-tasks

- [ ] Add `setPlan` / `getPlan` to `docs/RoadmapBackend.md` with per-backend semantics.
- [ ] `GitHubProjectBackend`: store/read the plan in the **item body**, inside a delimited section `<!-- atelier:plan:start -->` … `<!-- atelier:plan:end -->`, via the existing item-write / project-detail operations. Define behaviour for missing markers (→ "no plan") and duplicate markers (first match wins).
- [ ] `LinearBackend`: analogue — the delimited section in the issue description.
- [ ] `FilesBackend`: read/write the tracked `.plan/<id>.md` so the contract is uniform across backends.
- [ ] Offline-mirror reconstruction and `/migrate-roadmap --to files` must **strip / relocate** the `atelier:plan` delimited section from the item body so it does not pollute `roadmap/TASK_NNN_*.md`; ideally materialize it as `.plan/<id>.md` on `<remote> → files`, and inversely fold a committed `.plan` into the body on `files → <remote>`. Keep the migration matrix lossless.
- [ ] Bump `.claude-plugin/plugin.json` (additive minor).

## Notes

- Mirrors the existing `setReady` operation (`docs/RoadmapBackend.md`) — same shape, same drive-through-the-skill pattern.
- This is the cross-repo blocker for atelier task `#37` (backend-resident plans). atelier wires plan-task/next-task to call these ops; this task only provides the capability.
- The `files` backend keeps its committed `.plan/<id>.md` behaviour; the contract just makes it uniform.

## Status

Filed. Not yet planned.
