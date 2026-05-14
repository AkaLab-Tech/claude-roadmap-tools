# claude-roadmap-tools

Standalone [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) plugin that ships the **ROADMAP / IN_PROGRESS / HISTORY** task-tracking flow as a reusable artefact.

It packages:

- **`/create-roadmap`** — slash command that initializes `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` (and optionally a `roadmap/` folder) at the root of any repository, in either single-file or indexed layout.
- **`/migrate-roadmap`** — slash command that converts a repo already using the single-file layout to the indexed layout (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task).
- **`roadmap-tracking-flow`** skill — auto-activates on any repository whose root contains all three tracking files, and enforces the flow `ROADMAP → IN_PROGRESS → HISTORY` together with the pre-merge tracking rule (both the removal from `IN_PROGRESS.md` and the new `HISTORY.md` entry ride on the same PR as the work itself).

## Install

In a Claude Code session:

```
/plugin marketplace add AkaLab-Tech/claude-roadmap-tools
/plugin install claude-roadmap-tools@akalab-tech
```

The marketplace name is `akalab-tech` (shared namespace for all AkaLab-Tech plugins). After install, restart Claude Code if the new slash commands and the skill do not appear immediately.

## Quick start

1. `cd` into the repository you want to start tracking.
2. Run `/create-roadmap` and pick a layout when prompted:
   - **single-file** — everything lives in `ROADMAP.md`. Good for small projects.
   - **indexed** — titles in `ROADMAP.md`, full descriptions in `roadmap/TASK_NNN_<slug>.md`. Recommended once tasks grow long or when several agents work in parallel.
3. From that point on, the `roadmap-tracking-flow` skill will activate automatically on this repo, propose next tasks from `ROADMAP.md`, and remind you of the pre-merge tracking rule before opening PRs.

If a repo already uses the single-file layout and you want to upgrade it, run `/migrate-roadmap` instead — it converts the existing tracking files in place without losing content.

## Layouts at a glance

```
single-file                         indexed
-----------                         -------
ROADMAP.md     (titles + bodies)    ROADMAP.md            (titles only, links to roadmap/)
IN_PROGRESS.md (task blocks)        IN_PROGRESS.md        (links to roadmap/)
HISTORY.md                          HISTORY.md
                                    roadmap/TASK_001_*.md (full body, progress notes)
                                    roadmap/TASK_002_*.md
                                    ...
```

## Design rationale

This plugin was extracted from the maintainer's `~/.claude-personal/` setup so that the tracking flow can be installed cleanly on any machine, independent of the larger [`atelier`](https://github.com/AkaLab-Tech/atelier) AI-workstation project. The extraction was planned and documented in [`atelier` PR #10](https://github.com/AkaLab-Tech/atelier/pull/10) (milestone **M1.6**); see that PR's `ROADMAP.md` M1.6 block and `PLAN.md` §2 step 12 + §7 for the full motivation, including how `atelier`'s installer and `/doctor` integrate with this plugin.

## License

MIT — see [LICENSE](LICENSE).
