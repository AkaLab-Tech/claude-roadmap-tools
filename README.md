# claude-roadmap-tools

Standalone [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) plugin that ships the **ROADMAP / IN_PROGRESS / HISTORY** task-tracking flow as a reusable artefact. Supports two storage backends — **markdown files** at the repo root (the default) or **[Linear](https://linear.app)** via the Linear MCP, with an optional offline mirror.

It packages:

- **`/create-roadmap`** — initialize task tracking in the current repo. Picks a backend (`files` or `linear`), creates the matching artefacts (markdown tracking files for `files`; `.roadmap.json` + Linear MCP registration + optional mirror files for `linear`), and wires `.gitignore` when appropriate.
- **`/migrate-roadmap`** — migrate between layouts or backends. Supports `files (single-file) → files (indexed)` (the legacy direction) and `files (any layout) → linear` (with `backendId` write-back into each task file's frontmatter, plus optional auto-delete of local files when the mirror is off).
- **`roadmap-tracking-flow` skill** — auto-activates on any repository where the tracking flow is in place. Enforces the flow `ROADMAP → IN_PROGRESS → HISTORY` and the pre-merge tracking rule (both the removal from `IN_PROGRESS.md` and the new `HISTORY.md` entry ride on the same PR as the work itself).

The skill activates when **any** of:
1. The repo root contains all three of `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, **or**
2. The repo root contains a `.roadmap.json` config file (any backend), **or**
3. The user explicitly references the flow (`"what's in progress?"`, `"move this to HISTORY"`, etc.).

## Install

This plugin is published through the **[AkaLab-Tech plugin catalog](https://github.com/AkaLab-Tech/claude-plugins)** — a single marketplace that lists every plugin AkaLab-Tech publishes. In a Claude Code session, register the catalog once and install the plugin:

```
/plugin marketplace add AkaLab-Tech/claude-plugins
/plugin install claude-roadmap-tools@akalab-tech
```

The marketplace is named `akalab-tech`, so any other AkaLab-Tech plugin can be installed later from the same catalog with `/plugin install <name>@akalab-tech` — no extra `marketplace add` step needed. After install, restart Claude Code if the new slash commands and the skill do not appear immediately.

## Quick start

### `files` backend (default)

1. `cd` into the repository you want to start tracking.
2. Run `/create-roadmap` and pick a layout when prompted:
   - **single-file** — everything lives in `ROADMAP.md`. Good for small projects.
   - **indexed** — titles in `ROADMAP.md`, full descriptions in `roadmap/TASK_NNN_<slug>.md`. Recommended once tasks grow long or when several agents work in parallel.
3. From that point on, the `roadmap-tracking-flow` skill activates automatically on this repo, proposes next tasks from `ROADMAP.md`, and reminds you of the pre-merge tracking rule before opening PRs.

If a repo already uses the single-file layout and you want to upgrade it, run `/migrate-roadmap` instead — it converts the existing tracking files in place without losing content.

### `linear` backend

1. `cd` into the target repository.
2. Run `/create-roadmap --backend linear` (or `/create-roadmap` and pick `linear` interactively).
3. If the Linear MCP isn't registered yet, the command runs the canonical install (`claude mcp add --transport http linear-server https://mcp.linear.app/mcp`) and warns you that a browser window will open for OAuth on the next Linear call.
4. The MCP team-list call happens next (this is what triggers the OAuth browser flow on first ever use). Pick your Linear team from the list — or pre-select with `--team <key-or-uuid>` to skip the interactive picker.
5. The command asks whether to enable the offline mirror (or use `--mirror` / `--no-mirror` to skip the prompt). See [Backends → `linear`](#linear) below for what the mirror does.
6. `.roadmap.json` is written at the repo root with your selections. If you enabled the mirror, the three tracking files and `roadmap/` directory are also created; and if `.gitignore` already exists, the four tracking paths are appended (idempotently — re-runs do not duplicate entries).

To migrate an existing `files`-based repo to Linear in one shot, run `/migrate-roadmap --to linear` — it reuses the same Linear-setup flow and pushes every existing task into Linear, writing the new Linear ID back into each local file's frontmatter as `backendId`.

## Backends

### `files` (default)

Markdown tracking files at the repo root, in one of two layouts:

- **single-file** — `ROADMAP.md` holds full task descriptions. `IN_PROGRESS.md` holds the active task content directly. `HISTORY.md` holds completed-work entries. Good for small projects.
- **indexed** — `ROADMAP.md` is an index of titles linking to `roadmap/TASK_NNN_<slug>.md`. `IN_PROGRESS.md` and `HISTORY.md` reference the same task files (progress updates live inside the task file, not in `IN_PROGRESS.md`). Better for large projects or when running multiple agents in parallel.

The skill handles all operations directly against the local markdown files — no external service required. The absence of `.roadmap.json` at the repo root is the implicit signal that this is the active backend.

### `linear`

Task state lives in [Linear](https://linear.app); the skill drives it via the [Linear MCP](https://linear.app/docs/mcp). Each Linear issue is a task in the flow:

- Linear states in `Backlog`/`Todo` → `roadmap` bucket.
- Linear states in `In Progress` → `in_progress` bucket.
- Linear states in `Done`/`Cancelled` → `history` bucket.

The mapping is customizable per team via `linear.stateMap` in `.roadmap.json`.

Optionally enable an **offline mirror** (`offlineMirror: true`): the skill maintains local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `roadmap/` files as a read-only one-way mirror of Linear's state. The mirror auto-refreshes on every skill activation (no explicit `/refresh-roadmap` command — refresh happens as part of activation). When the Linear MCP is unreachable the skill falls back gracefully to the last successful snapshot and surfaces a clear warning; read-only operations keep working against the snapshot, writes throw `backend-unavailable` until the MCP is restored.

`.roadmap.json` at the repo root records the choice:

```json
{
  "backend": "linear",
  "offlineMirror": true,
  "linear": {
    "teamId": "<your-team-uuid>",
    "historyWindow": "90d",
    "stateMap": {
      "roadmap": ["Backlog", "Todo"],
      "inProgress": ["In Progress"],
      "history": ["Done", "Cancelled"]
    }
  }
}
```

Field notes:

- `offlineMirror` — `true` keeps the local mirror files (and adds them to `.gitignore` if `.gitignore` already exists); `false` makes Linear the only source of truth, with no local markdown.
- `linear.teamId` — written by `/create-roadmap` from the MCP team-list call.
- `linear.stateMap` — customize per your team's Linear workflow. Defaults match the workflow Linear ships for new teams.
- `linear.historyWindow` — bounds the cost of refreshing `HISTORY.md` from Linear on every skill activation. Defaults to `"90d"`. Supports any `"<N>d"`, a bare integer like `"50"` (last N entries), or `"all"` (no limit). Only meaningful with `offlineMirror: true`. Issues older than the window remain accessible via the skill's `getTask(id)` operation on-demand.

For the full operational contract per backend (operation-by-operation), see [`docs/RoadmapBackend.md`](docs/RoadmapBackend.md).

## Layouts at a glance

```
single-file                         indexed (and the linear mirror)
-----------                         -------
ROADMAP.md     (titles + bodies)    ROADMAP.md            (titles only, links to roadmap/)
IN_PROGRESS.md (task blocks)        IN_PROGRESS.md        (links to roadmap/)
HISTORY.md                          HISTORY.md
                                    roadmap/TASK_001_*.md (full body, progress notes)
                                    roadmap/TASK_002_*.md
                                    ...
```

For the `linear` backend with the offline mirror on, each `roadmap/TASK_NNN_*.md` file carries `backend: linear` + `backendId: <linear-issue-id>` in YAML frontmatter linking it to the corresponding Linear issue.

## Design rationale

This plugin was extracted from the maintainer's `~/.claude-personal/` setup so that the tracking flow can be installed cleanly on any machine, independent of the larger [`atelier`](https://github.com/AkaLab-Tech/atelier) AI-workstation project. The original extraction was planned in [`atelier` PR #10](https://github.com/AkaLab-Tech/atelier/pull/10) (milestone **M1.6**). The multi-backend extension (Linear + offline mirror) is tracked inside this repo as [TASK_001](roadmap/TASK_001_multi-backend-linear-first.md) — the plugin dogfoods its own tracking flow on its own development.

## License

MIT — see [LICENSE](LICENSE).
