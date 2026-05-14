---
description: Migrate the current repo from single-file tracking to indexed layout (titles in ROADMAP.md, one roadmap/TASK_NNN_<slug>.md per task).
---

# /migrate-roadmap

Convert this repo's task-tracking files from **single-file** layout to **indexed** layout, as defined by the `roadmap-tracking-flow` skill.

This command only runs in one direction: single-file → indexed. There is no reverse migration.

## Context

Run this only at the **root of the target repository**.

## Behavior

1. **Verify preconditions.**
   - `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` must all exist at the repo root. If any is missing, tell the user to run `/create-roadmap` first and stop.
   - If a `roadmap/` directory already exists at the root, the repo is already (or partially) migrated. Stop and tell the user — do **not** attempt to merge.
   - If the working tree has uncommitted changes to any of the three tracking files, ask the user whether to proceed. A clean working tree makes the migration diff easier to review.

2. **Parse `ROADMAP.md` and propose the migration plan.**
   - Treat each `##` and `###` heading as a candidate task. Use judgement: skip section headers that are clearly category buckets (e.g. `## High Priority`, `## Medium Priority`, `## Low Priority / Ideas`, `## Backlog`). Confirm with the user if it is ambiguous.
   - For each real task, derive:
     - `NNN` — sequential, zero-padded to three digits, starting at `001`.
     - `<slug>` — kebab-case, lowercase, ASCII, derived from the heading.
     - The body — everything from the heading down to the next heading at the same or higher level.
   - **Show the user the full plan before writing anything**: a numbered list of the proposed task files with their slugs and a one-line summary each. Ask for confirmation. Let the user rename, merge, drop, or split entries before proceeding.

3. **Also surface tasks living in `IN_PROGRESS.md`.**
   - If `IN_PROGRESS.md` contains task blocks (not just the standard header / workflow note), include them in the plan as candidate task files too. Mark them clearly as "currently in progress" so they get linked from `IN_PROGRESS.md` after migration, not from `ROADMAP.md`.
   - Number these continuing the same sequence. Do not restart numbering between roadmap and in-progress entries.

4. **Apply the migration after the user approves.**
   - Create `roadmap/` if it does not exist.
   - Write each `roadmap/TASK_NNN_<slug>.md` with the parsed body. Add a small header at the top of each file matching the indexed-layout task template:
     ```markdown
     # TASK_NNN — <Original heading>

     <body extracted from ROADMAP.md or IN_PROGRESS.md>
     ```
     Preserve original markdown structure (sub-headings, lists, checkboxes, code blocks).
   - Rewrite `ROADMAP.md` as an index: keep the priority section headings, replace each task block with a single bullet line linking to `roadmap/TASK_NNN_<slug>.md`. Keep tasks under the same priority section they were in.
   - Rewrite `IN_PROGRESS.md`: replace each migrated in-progress task block with a single link line to its `roadmap/TASK_NNN_<slug>.md`. Keep the workflow header and any prose that is not a task block.
   - **Do not touch `HISTORY.md`** — completed entries stay as records of what was delivered. They do not get task files retroactively.

5. **Report.**
   - List every file created and every file modified.
   - Remind the user that progress updates from now on go inside `roadmap/TASK_NNN_<slug>.md`, not in `IN_PROGRESS.md`.
   - Suggest reviewing the diff before committing, ideally on a feature branch (use the `git-wt` skill if applicable).

## Numbering convention

Same as `/create-roadmap`:
- `TASK_NNN_<slug>.md` with `NNN` zero-padded to three digits.
- Numbers assigned sequentially and never reused.
- After migration, the next new task picks the number after the highest existing `TASK_NNN_*.md`.

## Safety rules

- **Never rewrite or overwrite an existing `roadmap/TASK_NNN_*.md` file.** If the directory exists at all, abort at step 1.
- **Never delete content** during migration. If a heading is ambiguous, prefer creating an over-specified task file (the user can collapse it later) over silently dropping the text.
- The migration must be reviewable as a single git diff. Do not split it across multiple commits before the user has approved the plan.
- If the user wants to abort mid-plan, do not leave partial state — either complete the migration or do not start writing files.

## Arguments

`$ARGUMENTS` is ignored. The migration is always interactive.
