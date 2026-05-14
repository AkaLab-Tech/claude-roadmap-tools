---
description: Initialize the ROADMAP / IN_PROGRESS / HISTORY tracking files at the current repo root, in either single-file or indexed layout.
---

# /create-roadmap

Initialize the task-tracking files defined by the `roadmap-tracking-flow` skill.

## Context

Run this only at the **root of the target repository**. Do not create the files in subdirectories or in the user's home folder. If the working directory is not a git repository, ask the user whether to proceed anyway before creating anything.

## Behavior

1. **Detect existing state.** Check whether `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` or a `roadmap/` directory already exist at the repo root.

2. **Decide what to do based on what is present:**
   - If **all four** (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, and `roadmap/`) already exist: tell the user the repo is already initialized in indexed layout and stop.
   - If **the three files** exist but `roadmap/` does not: tell the user the repo is already initialized in single-file layout and stop. Mention that `/migrate-roadmap` is available if they want to switch to indexed.
   - Otherwise: continue to step 3.

3. **Ask the user which layout to use** (unless they passed it as an argument):
   - **single-file** — everything in `ROADMAP.md`. Recommended for small projects.
   - **indexed** — titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task. Recommended once tasks have long descriptions or when running multiple agents in parallel.

4. **Create only the missing pieces.** Never overwrite an existing file. After creation, report exactly which files were created and which were skipped because they already existed.

5. After the operation, remind the user that the `roadmap-tracking-flow` skill will now activate automatically on this repo because the three files are present.

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

## Numbering convention (indexed layout)

- Files are named `TASK_NNN_<slug>.md` where `NNN` is zero-padded to **three digits** (`TASK_001`, `TASK_042`, `TASK_113`).
- `<slug>` is kebab-case, lowercase, ASCII only, derived from the task title.
- Numbers are **assigned sequentially** and never reused, even after a task is completed or cancelled. When picking the next number, find the highest existing `TASK_NNN_*.md` in `roadmap/` and add 1.

## Arguments

If `$ARGUMENTS` contains `single-file` or `indexed`, use that layout without asking. Otherwise, ask interactively.
