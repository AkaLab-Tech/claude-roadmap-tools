# CLAUDE.md

`claude-roadmap-tools` is a standalone Claude Code plugin that ships a **ROADMAP / IN_PROGRESS / HISTORY** task-tracking flow as a reusable artefact. It supports two storage backends — markdown files at the repo root (default) or Linear via the Linear MCP, with an optional offline mirror — and is distributed through the AkaLab-Tech plugin catalog.

## Stack

- **Language**: Markdown / JSON (no compiled language — the plugin artifact is pure prose + config)
- **Framework**: Claude Code plugin system (slash commands + skills via `.claude-plugin/plugin.json`)
- **Package manager**: none (no build step; plugin is installed via `/plugin install` in Claude Code)
- **Test runner**: TBD — no test config found
- **Linter / formatter**: TBD — no linter config found

## Architecture

The repo is structured as a Claude Code plugin with three top-level concerns:

- `commands/` — slash-command definitions (`create-roadmap.md`, `adopt-roadmap.md`, `migrate-roadmap.md`), each a markdown file that Claude Code loads as a `/command`
- `skills/roadmap-tracking-flow/` — the auto-activating skill (`SKILL.md`) that enforces the `ROADMAP → IN_PROGRESS → HISTORY` flow and the pre-merge tracking rule
- `docs/` — backend operational contract (`RoadmapBackend.md`)
- `.claude-plugin/plugin.json` — plugin manifest (name, version, description, author)
- The repo dogfoods its own tracking flow: `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/TASK_NNN_*.md` task files are live project state

## Conventions

- **No build step**: all deliverables are `.md` and `.json` files; editing them directly is the workflow
- **Tracking flow**: active work goes through `ROADMAP.md → IN_PROGRESS.md → HISTORY.md`; task detail files in `roadmap/` stay in place across all three states
- **PR rule**: removal from `IN_PROGRESS.md` and the new `HISTORY.md` entry must ride on the same PR as the work itself
- **CI**: TBD — no `.github/workflows/` found
- **Versioning**: version lives in `.claude-plugin/plugin.json`; current version is `0.4.0`

## What this project is NOT

- Not a general-purpose project-management app — it is specifically a Claude Code plugin, usable only within Claude Code sessions
- Not a backend service — there is no server, API, or database; state lives in markdown files or Linear

## Out of scope for AI agents

- TBD
