---
description: Initialize task tracking at the current repo root. Pick a backend (files-based markdown layout, Linear via MCP, or GitHub Projects v2 via the GitHub MCP) and write its setup (tracking files, .roadmap.json, MCP registration, .gitignore entries).
---

# /create-roadmap

Initialize task tracking at the root of the current repo. The command picks a backend (`files`, `linear`, or `github-project`), creates only the artefacts that backend needs (markdown tracking files for `files`; `.roadmap.json` + MCP registration + optional mirror files for `linear` or `github-project`), and reports exactly what was done. The `roadmap-tracking-flow` skill auto-activates afterwards.

## Context

Run this only at the **root of the target repository**. Do not create the files in subdirectories or in the user's home folder. If the working directory is not a git repository, ask the user whether to proceed anyway before creating anything.

## Behavior

1. **Detect existing state.** Check whether any of the following exist at the repo root:
   - `.roadmap.json` (config file — present means the repo has already chosen a backend).
   - `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`.
   - `roadmap/` directory.

2. **Decide whether to proceed:**
   - If `.roadmap.json` **already exists**, this repo is already configured. Echo the current `backend` (plus `offlineMirror` and `linear.teamId` if `backend: "linear"`, or `githubProject.owner`/`projectNumber` if `backend: "github-project"`) and **stop**. Mention `/migrate-roadmap` if the user wants to switch backends. Never overwrite `.roadmap.json` from this command.
   - If `.roadmap.json` is absent but **all four** tracking artefacts (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `roadmap/`) already exist: the repo is already initialized as `backend: files` in indexed layout (implicit — no `.roadmap.json` needed). Stop.
   - If `.roadmap.json` is absent and **the three files** exist but `roadmap/` does not: the repo is already initialized as `backend: files` in single-file layout (implicit). Mention `/migrate-roadmap` if they want to switch to indexed. Stop.
   - Otherwise: continue to step 3.

3. **Ask the user which backend to use** (unless `$ARGUMENTS` already specifies one — see [Arguments](#arguments) below):
   - **`files`** — markdown tracking files at the repo root. The default. **No `.roadmap.json` is written** — the absence of the file is the signal for `files` mode.
   - **`linear`** — task state lives in [Linear](https://linear.app); the plugin drives state changes via the Linear MCP. `.roadmap.json` is written to record the choice. An optional offline mirror keeps local markdown files in sync with Linear.
   - **`github-project`** — task state lives in a GitHub Project (Projects v2), driven via the hosted GitHub MCP. `.roadmap.json` is written to record the choice. An optional offline mirror keeps local markdown files in sync with the Project.

4. **Branch on backend.** Use step 5a for `files`, step 5b for `linear`, step 5c for `github-project`.

5a. **`files` backend setup:**
   1. Ask the user which layout to use (unless `$ARGUMENTS` already specifies one): **single-file** (everything in `ROADMAP.md`) or **indexed** (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task — recommended for projects with long task descriptions or parallel agent workflows).
   2. Create only the missing tracking files per the chosen layout (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and — indexed only — an empty `roadmap/` directory plus a `roadmap/TASK_001_example.md` starter). Never overwrite an existing file.
   3. **Do not** write `.roadmap.json` — the absence of the file already means `backend: files`.
   4. Continue to step 6.

5b. **`linear` backend setup:**
   1. **Ensure the Linear MCP is registered.** Inspect the MCP server list. Look for a server whose host is `mcp.linear.app` or whose name matches `linear-server`.
      - If **not registered**, run the canonical install command:
        ```
        claude mcp add --transport http linear-server https://mcp.linear.app/mcp
        ```
        Tell the user: _"A browser window will open the first time we call the Linear MCP so you can authorize via OAuth. The token is cached after that for this Claude Code installation."_
      - **If already registered** under any name (host match on `mcp.linear.app` or name match on `linear-server`), **skip the install entirely** — do not re-run `claude mcp add` even though it would be technically idempotent. The CLI may print "already registered" but the user sees noise; worse, some Claude Code versions surface a "tools not visible yet; please restart" instruction even when the MCP is healthy. **Proceed directly to the next step.**
   2. **List Linear teams** by calling the Linear MCP team-list tool. This is typically the first ever Linear MCP call in this Claude Code installation, so the OAuth browser flow triggers here. Wait for the user to complete OAuth before proceeding. If OAuth fails or is cancelled, abort step 5b without writing any file or making any further changes.
   3. **Show the teams** (key + name, e.g. `ENG — Engineering`) and ask the user to pick one. Capture the team UUID for `linear.teamId`. Unless `$ARGUMENTS` includes `--team <key-or-uuid>`, in which case validate the supplied value against the MCP team list instead.
   4. **Ask whether to enable the offline mirror** (unless `$ARGUMENTS` includes `--mirror` / `--no-mirror`):
      - **`true`** — the plugin also maintains local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `roadmap/` files as a read-only one-way mirror of Linear's state (refreshed on every skill activation per [TASK_001 — Offline mirror semantics](../roadmap/TASK_001_multi-backend-linear-first.md#offline-mirror-semantics)).
      - **`false`** — Linear is the only source of truth. No local markdown files are created.
   5. **Write `.roadmap.json`** at the repo root using the [`.roadmap.json` template](#roadmapjson--linear-backend) below. Fill `linear.teamId` with the UUID from step 5b.3. **Ship the full `linear.stateMap` defaults exactly as in the template** — do not trim alternatives down to just the state the user happens to be using; users edit later if their team's workflow uses different state names. **Do not omit `historyWindow`** even though it has a default. **Field-naming convention**: bucket names in operation arguments use snake_case (`in_progress`); the JSON config field uses camelCase (`inProgress`). The mapping is fixed: bucket `in_progress` ↔ field `linear.stateMap.inProgress`. The template below is the single source of truth — copy it verbatim, only substituting the values from the prior steps.
   6. **If `offlineMirror: true`:**
      - Create the three tracking files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) using the indexed-layout templates (the mirror always uses indexed layout — each Linear issue maps 1:1 to a `roadmap/TASK_NNN_*.md` file).
      - Create an empty `roadmap/` directory (the next time the skill activates it will be populated from Linear).
      - **If `.gitignore` exists at the repo root**, append these four lines to it, **each only if not already present** (so re-runs are idempotent — do not duplicate entries):
        ```
        ROADMAP.md
        IN_PROGRESS.md
        HISTORY.md
        roadmap/
        ```
        **If `.gitignore` does not exist**, do nothing — the user may be working without git, which is a valid setup. Do not auto-create `.gitignore` or `.git`.
   7. Continue to step 6.

5c. **`github-project` backend setup:**
   1. **Ensure the GitHub MCP is registered.** Inspect the MCP server list. Look for a server whose host matches `api.githubcopilot.com/mcp` or whose registered name matches `github`.
      - **If already registered** under any matching name/host, **skip the install entirely** — do not re-run `claude mcp add` even though it would be technically idempotent, for the same noise/restart-warning reasons as step 5b.1. Proceed directly to the next bullet.
      - **If not registered**, run the canonical install command:
        ```
        claude mcp add --transport http github https://api.githubcopilot.com/mcp/
        ```
        Tell the user: _"A browser window will open the first time we call the GitHub MCP so you can authorize via OAuth 2.1 + PKCE."_
      - The `projects` toolset is **not** enabled by default. It requires the `project` OAuth scope. An unscoped token makes the toolset look absent — treat a missing toolset as a missing scope, not a missing server. If the toolset is not visible after registration, instruct the user to re-authorize with the `project` scope enabled.
   2. **List the user's Projects** by calling the GitHub MCP `projects_list` tool. This is typically the first Projects call in this Claude Code installation, so the OAuth 2.1 + PKCE browser flow triggers here. Wait for the user to complete OAuth before proceeding. If OAuth fails or is cancelled, abort step 5c without writing any file or making any further changes.
   3. **Show the Projects** (owner + project number + title, e.g. `acme/7 — Sprint Board`) and ask the user to pick one. Capture `owner` and `projectNumber` (or the Project node id as `projectId` — acceptable alternative). Unless `$ARGUMENTS` includes `--project <owner/number-or-id>`, in which case validate the supplied value against the MCP project list instead.
   4. **Ask whether to enable the offline mirror** (unless `$ARGUMENTS` includes `--mirror` / `--no-mirror`) — same semantics as step 5b.4.
   5. **Write `.roadmap.json`** at the repo root using the [`.roadmap.json` template](#roadmapjson--github-project-backend) below. Fill `githubProject.owner` and `githubProject.projectNumber` from step 5c.3. **Ship the full `githubProject.stateMap` defaults exactly as in the template.** Same field-naming convention as linear: bucket `in_progress` ↔ `githubProject.stateMap.inProgress`.
   6. **If `offlineMirror: true`** — identical to step 5b.6: create `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` (indexed layout), an empty `roadmap/` directory, and append the four `.gitignore` lines idempotently (if `.gitignore` exists). If `.gitignore` does not exist, do nothing.
   7. Continue to step 6.

6. **Report**, in order, every artefact created or modified during this run:
   - `.roadmap.json` (only when `backend: linear` or `backend: github-project` — flag as "created").
   - Each tracking file (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) and the `roadmap/` directory — flag as "created" / "skipped (already existed)".
   - The MCP server registration (only if performed in step 5b.1 or 5c.1) — flag as "registered" / "skipped (already registered as <name>)".
   - `.gitignore` modifications (only if performed in step 5b.6 or 5c.6) — list each line added, or note "all four entries already present".

7. **Remind the user** that the `roadmap-tracking-flow` skill auto-activates on this repo because the tracking files are now in place. Specifically:
   - For `backend: files`: the skill follows [Operations (`FilesBackend`)](../skills/roadmap-tracking-flow/SKILL.md) — see the section in `SKILL.md`.
   - For `backend: linear`: the skill follows [Operations (`LinearBackend`)](../skills/roadmap-tracking-flow/SKILL.md) — see the section in `SKILL.md`. The first call to a Linear MCP tool (e.g. when the user asks "what's in progress?") will trigger the OAuth browser prompt if it has not already. The skill activates on this repo via the `.roadmap.json`-presence activation predicate regardless of whether `offlineMirror` is on or off.
   - For `backend: github-project`: the skill follows [Operations (`GitHubProjectBackend`)](../skills/roadmap-tracking-flow/SKILL.md) — see the section in `SKILL.md`. The skill activates via the `.roadmap.json`-presence predicate regardless of whether `offlineMirror` is on or off.

## Templates

All templates are written in **English** regardless of the chat language, matching the user's project-language rule for code, docs, and commits.

### `ROADMAP.md` — single-file layout

```markdown
# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

---

## High Priority

<!-- ### Example task title

Short framing of what the task is and why it matters.

- [ ] Sub-task 1
- [ ] Sub-task 2

**Acceptance:** what "done" looks like.
-->

## Medium Priority

## Low Priority / Ideas
```

### `ROADMAP.md` — indexed layout

```markdown
# Roadmap

Backlog index. Each entry links to its detailed task file in `roadmap/`.

Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`. The detail file (`roadmap/TASK_NNN_<slug>.md`) stays put across all three states; `IN_PROGRESS.md` and `HISTORY.md` only link to it.

---

## High Priority

<!-- - [TASK_001 — Example title](roadmap/TASK_001_example-title.md) -->

## Medium Priority

## Low Priority / Ideas
```

### `IN_PROGRESS.md` — both layouts

```markdown
# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->
```

### `HISTORY.md` — both layouts

```markdown
# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

<!-- ## YYYY-MM

### Example title — YYYY-MM-DD
**PR:** [#N](https://github.com/<org>/<repo>/pull/N)

One- or two-sentence framing of why this PR existed.

**Delivered:**
- Bullet 1
- Bullet 2

**Tests:** one line on the validation done.

**Follow-ups:** (optional)
- Bullet
-->
```

### `roadmap/TASK_001_example.md` — indexed layout only

When creating the indexed layout, also create one example file inside `roadmap/` as a starting point so the user has a template to copy. Use this content:

```markdown
# TASK_001 — Example title

One-paragraph description of what this task is and why it matters. Replace this with the real task.

## Goal

What "done" looks like for this task.

## Sub-tasks

- [ ] Step 1
- [ ] Step 2

## Notes

Design decisions, links to issues, anything worth keeping with the task.

## Status

(Updated as the task progresses. While in `IN_PROGRESS.md`, log changes here, not in `IN_PROGRESS.md`.)
```

### `.roadmap.json` — linear backend

When `backend: linear`, write the following at the repo root. Fill `linear.teamId` with the UUID picked from the Linear MCP team-list call; keep the `linear.stateMap` and `linear.historyWindow` defaults unless the user explicitly customizes them.

```json
{
  "backend": "linear",
  "offlineMirror": false,
  "linear": {
    "teamId": "<team-uuid>",
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

- `offlineMirror` — set to whatever the user chose in step 5b.4.
- `linear.stateMap` — defaults match the workflow Linear ships for new teams.
- `linear.historyWindow` — bounds the cost of refreshing `HISTORY.md` from Linear on every skill activation. Supported values: `"90d"` (default), any `"<N>d"`, a bare integer like `"50"` (last N entries), or `"all"` (no limit). Only meaningful with `offlineMirror: true`; harmless to leave when the mirror is off. See [Mirror auto-refresh on activation](../skills/roadmap-tracking-flow/SKILL.md) for the full semantics.

Do **not** write `.roadmap.json` when `backend: files` — the absence of the file is the signal for `files` mode, and the skill defaults accordingly.

### `.roadmap.json` — github-project backend

When `backend: github-project`, write the following at the repo root. Fill `githubProject.owner` and `githubProject.projectNumber` from the Project picked in step 5c.3; keep the `githubProject.stateMap` and `githubProject.historyWindow` defaults unless the user explicitly customizes them.

```json
{
  "backend": "github-project",
  "offlineMirror": false,
  "githubProject": {
    "owner": "<org-or-user>",
    "projectNumber": 7,
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

- `offlineMirror` — set to whatever the user chose in step 5c.4.
- `githubProject.projectNumber` — the integer that appears in the Project URL (`/projects/<N>`). Alternatively, the Project node id (`PVT_...`) may be stored as `projectId` in place of `owner` + `projectNumber`; either selector is valid for the MCP calls.
- `githubProject.stateMap` — defaults match the single-select Status options GitHub ships for new Projects v2 boards.
- `githubProject.historyWindow` — same semantics and supported values as `linear.historyWindow` (see above). Only meaningful with `offlineMirror: true`; harmless to leave when the mirror is off.
- **Field-naming convention**: bucket names in operation arguments use snake_case (`in_progress`); the JSON config field uses camelCase (`inProgress`). The mapping is fixed: bucket `in_progress` ↔ field `githubProject.stateMap.inProgress`. Same convention as the linear backend.

## Numbering convention (indexed layout)

- Files are named `TASK_NNN_<slug>.md` where `NNN` is zero-padded to **three digits** (`TASK_001`, `TASK_042`, `TASK_113`).
- `<slug>` is kebab-case, lowercase, ASCII only, derived from the task title.
- Numbers are **assigned sequentially** and never reused, even after a task is completed or cancelled. When picking the next number, find the highest existing `TASK_NNN_*.md` in `roadmap/` and add 1.

## Arguments

`$ARGUMENTS` is parsed as a space-separated list of bare values and/or flags. Each value/flag suppresses the matching interactive prompt:

- A bare value `files`, `linear`, or `github-project`, or `--backend <files|linear|github-project>` — selects the backend.
- A bare value `single-file` or `indexed`, or `--layout <single-file|indexed>` — selects the layout. **`files` backend only.** When combined with `--backend linear` or `--backend github-project`, error out: both remote backends are always indexed-layout (the mirror layout is implicit; do not let the user pick conflicting options).
- `--mirror` / `--no-mirror` — enables / disables the offline mirror. **`linear` and `github-project` backends only.** With `--backend files`, error out.
- `--team <key-or-uuid>` — pre-selects the Linear team without going through the interactive picker. **`linear` backend only.** The MCP team-list call is still made to validate the value; if the key/UUID does not match any team for the authenticated Linear user, error out. Error out if combined with `--backend github-project`.
- `--project <owner/number-or-id>` — pre-selects the GitHub Project without going through the interactive picker. **`github-project` backend only.** Validated against the user's Projects list via the GitHub MCP `projects_list` tool. Accepts `<owner>/<number>` (e.g. `acme/7`) or a bare Project node id (`PVT_...`). Error out if combined with `--backend files` or `--backend linear`.

If `$ARGUMENTS` includes conflicting flags (e.g. `--backend linear --layout single-file`, `--mirror --backend files`, `--team ENG --backend github-project`, or `--project acme/7 --backend linear`), error out with a clear message naming the conflict; do **not** silently pick a winner.

Interactive prompting only fires for choices not already specified in `$ARGUMENTS`. Examples:

- `/create-roadmap files indexed` — fully non-interactive for the files backend with indexed layout.
- `/create-roadmap linear --team ENG --mirror` — fully non-interactive for the linear backend with team `ENG` and offline mirror enabled (the team-list call is still made to validate `ENG`; the user still completes OAuth if it has not been authorized yet).
- `/create-roadmap github-project --project acme/7 --mirror` — fully non-interactive for the github-project backend with project `acme/7` and offline mirror enabled (the projects-list call is still made to validate `acme/7`; the user still completes OAuth if it has not been authorized yet).
- `/create-roadmap` — fully interactive (prompts for backend → then either layout for files, team + mirror for linear, or project + mirror for github-project).
