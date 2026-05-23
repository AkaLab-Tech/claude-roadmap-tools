# Roadmap

Backlog index. Each entry links to its detailed task file in `roadmap/`.

Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`. The detail file (`roadmap/TASK_NNN_<slug>.md`) stays put across all three states; `IN_PROGRESS.md` and `HISTORY.md` only link to it.

---

## High Priority

<!-- - [TASK_NNN — Example title](roadmap/TASK_NNN_example-title.md) -->

## Medium Priority

<!-- - [TASK_NNN — Example title](roadmap/TASK_NNN_example-title.md) -->

## Low Priority / Ideas

> Future backends, to be materialized into `TASK_NNN_<slug>.md` files once the multi-backend foundation from TASK_001 lands and a concrete user need is confirmed for each one.

- **GitHub Issues backend** — map ROADMAP/IN_PROGRESS/HISTORY to repo issues + labels (`status:roadmap`, `status:in-progress`, `status:done`) or a project board column. Useful for OSS projects already centred around GitHub.
- **Jira backend** — map to Jira issues + workflow states. Useful for enterprise teams already on Jira.
- **Trello backend** — map to Trello board lists. Useful for lighter, non-engineering project tracking.
