# TASK_002 — `/adopt-roadmap` command

Add a third initialization command that normalizes a repo whose tracking files **exist but are not canonical** into the `files` backend layout. Fills the gap between `/create-roadmap` (nothing exists) and `/migrate-roadmap` (canonical tracking → other backend/layout).

## Goal

A repo whose `IN_PROGRESS.md` is used as a multi-phase progress tracker (sections like `RLS`, `ADMIN`, `WEB`, `i18n` with `[x]`/`[ ]` items) — a layout that predates this flow — can be normalized in place into `ROADMAP → IN_PROGRESS → HISTORY` without losing content, so single-active-task tooling (e.g. atelier's `/next-task`) stops treating the slot as permanently occupied.

## Sub-tasks

- [x] Add `commands/adopt-roadmap.md` — preconditions (files backend only; refuse linear; nothing-to-adopt → `/create-roadmap`; already-canonical → stop), classification rules (done → history, open → roadmap, explicit-active → in_progress, ambiguous → ask, never drop), editable adoption plan, single-diff apply, safety rules, arguments, atelier delegation note.
- [x] Reuse `/create-roadmap` templates verbatim; add only the relaxed "adopted history entry (no PR / no date)" shape for legacy done-items.
- [x] Update `README.md` to list the third command.
- [x] Bump `.claude-plugin/plugin.json` to `0.3.0` (new command, additive).

## Notes

- **Files backend only.** The command never writes `.roadmap.json` and never changes the backend — that is `/migrate-roadmap`'s job.
- **Never fabricate** type tags, issue ids, estimates, PR numbers, or dates. Unknown structured fields become explicit `TODO`s; legacy done-items with no PR use the relaxed adopted-entry shape.
- Pairs with atelier: `/setup-project` detects a phase-tracker `IN_PROGRESS.md` and offers to delegate here.

## Status

Delivered. See the matching `HISTORY.md` entry for the PR reference.
