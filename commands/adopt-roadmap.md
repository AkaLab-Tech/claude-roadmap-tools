---
description: Normalize existing but non-canonical tracking files into the canonical `files` backend layout. For repos whose `ROADMAP.md` / `IN_PROGRESS.md` predate this flow (e.g. `IN_PROGRESS.md` used as a multi-phase tracker instead of a single active-task slot). Reshapes content into `ROADMAP → IN_PROGRESS → HISTORY` without losing anything.
---

# /adopt-roadmap

Adopt an existing repo whose tracking files **exist but are not canonical** into the `files` backend layout this plugin expects. This is the third initialization state, sitting between the other two commands:

| Situation | Command |
| :--- | :--- |
| No tracking exists yet → create fresh | `/create-roadmap` |
| **Tracking files exist in an ad-hoc / legacy format → normalize in place** | **`/adopt-roadmap`** |
| Canonical tracking exists → switch backend or layout | `/migrate-roadmap` |

The canonical case it fixes: a repo where `IN_PROGRESS.md` is used as a **multi-phase progress tracker** (sections like `RLS`, `ADMIN`, `WEB`, `i18n` with `[x]`/`[ ]` items) rather than the single active-task slot the flow expects. Tools that read `IN_PROGRESS.md` as a one-task slot (e.g. atelier's `/next-task`) treat any non-placeholder content as "a task is already in progress" and refuse to proceed. `/adopt-roadmap` redistributes that content into the right buckets and resets `IN_PROGRESS.md` to an empty slot.

This command **only** targets the `files` backend and **never** changes the backend or pushes to a remote. It is a content-normalization step, not a backend/layout migration (that is `/migrate-roadmap`).

## Context

Run this only at the **root of the target repository**. Do not operate on subdirectories or the user's home folder. If the working directory is not a git repository, ask the user whether to proceed anyway before writing anything.

## Behavior

1. **Verify preconditions.**
   - **Determine the backend** by reading `.roadmap.json` if present:
     - File present + `backend: "linear"` → **refuse.** This command normalizes `files`-backend markdown; a Linear-backed repo has no local freeform tracking to adopt. Stop and point at `/migrate-roadmap` if the user wanted a backend change.
     - File present + `backend: "files"`, or file absent → backend is `files`. Continue.
   - **Confirm there is something to adopt.** Check the repo root for `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`:
     - **None of the three exist** → there is nothing to normalize. Stop and point at `/create-roadmap` to initialize from scratch.
     - **They exist and are already canonical** — `IN_PROGRESS.md` contains only its header plus the placeholder comment(s) (an empty slot), and `ROADMAP.md` already follows the priority-section structure — then there is nothing to adopt. Say so and stop; suggest `/migrate-roadmap` if the user wanted a layout/backend change instead.
     - **Otherwise** (any tracking file holds non-canonical content — most commonly `IN_PROGRESS.md` carrying phase sections with checkboxes) → continue to step 2.
   - **Working tree check.** If the working tree has uncommitted changes to any tracking file, ask the user whether to proceed. A clean tree makes the adoption diff easy to review.

2. **Resolve the target layout.** From `$ARGUMENTS` (`--layout <single-file|indexed>`) or via an interactive prompt. Default to **single-file** unless a `roadmap/` directory already exists at the root (then default to **indexed**). Never mix layouts.

3. **Parse the legacy content and classify every item.** Read all tracking files that exist and extract each discrete item (a checkbox line, a heading-level task, a bullet). Classify each into exactly one target bucket:
   - **`history`** — items that are clearly **done**: `- [x]` checkboxes, items under headings like `Done` / `Completed` / `Shipped` / `Released`, or struck-through text.
   - **`in_progress`** — items explicitly marked active: `WIP`, `In progress`, `Current`, `🚧`, or an item the user designates in step 4. The single-active-task slot holds **at most one** task. If the legacy content marks several as active, surface them and ask the user to pick one (the rest go to `roadmap`).
   - **`roadmap`** — everything else open: `- [ ]` checkboxes, pending bullets, phase sections not yet started.
   - **Ambiguous items** — never guess silently. Ask, or default to `roadmap` and flag it in the plan. **Never drop an item.**
   - **Preserve legacy grouping as context.** Phase / section names (`RLS`, `ADMIN`, `WEB`, `i18n`, …) are not priorities. Carry each phase name into the adopted task (in its title or body) so the grouping is not lost, and map the items to priority sections in step 4.

4. **Show the full adoption plan before writing anything.** Group the proposed result by target bucket (`history` / `in_progress` / `roadmap`), and for each item show the canonical entry it will become. Make the plan editable: let the user reassign buckets, set priorities, rename, merge, split, or designate the one `in_progress` task. Specifically:
   - For `roadmap` items, propose a priority section and let the user re-sort:
     - **Default (tracking-flow) layout:** `High` / `Medium` / `Low / Ideas` — default to `Medium` when unknown.
     - **Atelier (`--format atelier`) layout:** `P0` / `P1` / `P2` (see [Atelier layout](#atelier-layout)). Map legacy priority words by default: `High`/`Alta` → `P1`, `Medium`/`Media` → `P2`, `Low`/`Baja` → `P2`, unknown → `P2`. **`P0` is for blockers only** — never auto-assign it; let the operator promote an item to `P0` explicitly.
   - For fields the legacy format does not carry (type tag, id, estimate), insert an explicit `TODO` placeholder rather than inventing a value. **Never fabricate** a type, an issue id, an estimate, a PR number, or a completion date. In atelier layout this means `` `TODO-type` `` for an uninferable type and `` `~TODO` `` for a missing estimate; infer the type only when the legacy text is unambiguous (a `bug`/`fix` heading → `bug`, `feature`/`feat` → `feat`, etc.).
   - For `in_progress`, default to **empty slot** (placeholder) unless the user designates a task or passes `--in-progress`. In a phase tracker there is usually no single active task; an empty slot lets the user pick the next one with their normal flow afterwards.
   - Ask for confirmation. If the user aborts here, leave **no** files touched.

5. **Apply the adoption after the user approves**, as a single reviewable change set:
   - **`ROADMAP.md`** — rewrite to the canonical header + priority sections, then place every `roadmap` item under its assigned section. The section structure depends on the format:
     - **Default (tracking-flow):** `High` / `Medium` / `Low / Ideas` per the `/create-roadmap` template for the chosen layout. In **indexed** layout, create one `roadmap/TASK_NNN_<slug>.md` per item (numbering per the [convention](#numbering-convention)) and leave index links in `ROADMAP.md`.
     - **Atelier (`--format atelier`):** the `P0`/`P1`/`P2` section structure and per-item line shape in [Atelier layout](#atelier-layout). Each item becomes a `- [ ] \`<type>\` <title> \`#<id>\` \`~<estimate>\`` line (no `[ready]` marker — that is added later by `/atelier:plan-task`). **Preserve a legacy numeric id**: `TASK-68` → `#68`; assign a fresh sequential `#NN` only when the item has no id. Carry the legacy phase/section name into the title or body so the grouping is not lost.
   - **`HISTORY.md`** — append the `history` items as adopted records. Legacy done-items usually have **no PR and no date**; use the relaxed adopted-entry shape in [Templates](#templates) — do not invent a PR link or a date. Group them under a single `## <YYYY-MM>` section dated the day the adoption runs, with a one-line note that these were adopted from prior tracking. Preserve any real dates/PR refs the legacy content did carry.
   - **`IN_PROGRESS.md`** — rewrite to the canonical header + the placeholder comment (empty slot). If the user designated one `in_progress` task in step 4, place that one task (single-file) or its link (indexed) instead of the placeholder.
   - Create any missing tracking file using the matching `/create-roadmap` template so the repo ends fully canonical.

6. **Report**, in order, every file created or modified:
   - `ROADMAP.md` — modified (N items placed); `roadmap/TASK_NNN_*.md` files created (indexed only).
   - `IN_PROGRESS.md` — reset to empty slot (or the one active task).
   - `HISTORY.md` — N adopted entries appended.
   - List any items flagged `TODO` (missing type/id/estimate) so the user knows what to fill in.
   - Remind the user to review the diff before committing, ideally on a feature branch, and that from now on `/create-roadmap`-style flow applies: `IN_PROGRESS.md` is the single active-task slot, picked via their normal next-task flow.

## Safety rules

- **Never delete content.** If an item is ambiguous, prefer creating an over-specified `roadmap` entry (the user can collapse it later) over dropping the text. Every line of the original tracking content must land in exactly one bucket.
- **Never fabricate** type tags, issue ids, estimates, PR numbers, or completion dates. Use explicit `TODO` placeholders for unknown structured fields; use the relaxed adopted-entry shape for history items with no PR.
- **Single reviewable change set.** Do not split the adoption across multiple commits before the user has approved the plan.
- **Abort leaves no partial state.** If the user rejects the plan in step 4, no files are created, modified, or deleted.
- **Files backend only.** Refuse on `backend: "linear"` repos (step 1). This command never writes `.roadmap.json` and never changes the backend.

## Templates

The canonical `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` templates (single-file and indexed) and the `roadmap/TASK_NNN_*.md` task template are the ones in [`/create-roadmap`](create-roadmap.md#templates) — reuse them verbatim so an adopted repo is indistinguishable from a freshly-created one.

### Adopted history entry (no PR / no date)

For `history` items carried over from legacy tracking that have no PR or date, use this relaxed shape instead of the standard PR-anchored entry. It omits the `**PR:**` line and notes the provenance:

```markdown
### <Title> — adopted from prior tracking
Carried over from the repo's pre-existing tracking on adoption. No PR record.

**Delivered:** <one line from the legacy item, or "see prior tracking">
```

When the legacy item *did* carry a real PR ref or date, prefer the standard `appendHistoryEntry` shape from the [skill](../skills/roadmap-tracking-flow/SKILL.md) and fill in the real values.

### Atelier layout

When `--format atelier` is set, `ROADMAP.md` uses atelier's PLAN.md §5 structure instead of the `High`/`Medium`/`Low` sections — the layout atelier's `task-discovery` / `/atelier:next-task` parse. Three priority sections, matched on the `P0`/`P1`/`P2` token (the emoji is decorative):

```markdown
# Roadmap

## 🔥 P0 — Blockers

- [ ] `bug` Login redirects to 404 after OAuth `#23` `~2h`

## 🎯 P1 — Next

- [ ] `feat` Store logo upload + display `#68` `~TODO` `blocked_by:#23`

## 💭 P2 — Backlog

- [ ] `TODO-type` Asset library `#63` `~TODO`
```

Per item: a leading checkbox, a backtick-quoted **type tag** (`bug`/`feat`/`chore`/`docs`/`refactor`, or `` `TODO-type` `` when uninferable), the **title**, a backtick `#id`, an optional backtick `~estimate` (`` `~TODO` `` when missing), and an optional `blocked_by:#id` / `blocked_by:<token>#id`. **Do not** add a `[ready]` marker — a task is only made `[ready]` (with a committed `.plan/<id>.md`) by `/atelier:plan-task`, so the adopted roadmap is the *backlog* the product lead plans from, one task at a time. `IN_PROGRESS.md` / `HISTORY.md` are unchanged from the default layout.

## Numbering convention

Same as `/create-roadmap` and `/migrate-roadmap` (indexed layout): `TASK_NNN_<slug>.md`, `NNN` zero-padded to three digits, assigned sequentially in the order items appear in the adoption plan (`history` first, then `in_progress`, then `roadmap`, in document order), starting after the highest existing `TASK_NNN_*.md`. Numbers are never reused.

## Arguments

`$ARGUMENTS` is parsed as a space-separated list of bare values and/or flags. Each suppresses the matching interactive prompt:

- `--format <tracking-flow|atelier>` — selects the `ROADMAP.md` section/item format. Default `tracking-flow` (`High`/`Medium`/`Low` + plain checkboxes). `atelier` emits the PLAN.md §5 layout (`P0`/`P1`/`P2` + backtick type tags, `#id`, `~estimate`) that atelier's `task-discovery` / `/atelier:next-task` parse — see [Atelier layout](#atelier-layout). Only affects `ROADMAP.md`; `IN_PROGRESS.md` / `HISTORY.md` are identical either way.
- `--layout <single-file|indexed>` — selects the target layout. Default: `single-file`, or `indexed` if a `roadmap/` directory already exists.
- `--in-progress <none|"<title>">` — pre-selects the single active-task slot. `none` (default) leaves an empty slot; a quoted title designates that item as the one `in_progress` task.
- `--yes` / `-y` — non-interactive: accept the auto-classified plan without the interactive review in step 4. **Use with care** — auto-classification places every open item under `Medium Priority` and every unknown field as `TODO`. Conflicts or ambiguities still stop with an error rather than guessing.

Conflicting flags (e.g. `--in-progress "X"` together with content that marks a different task active) surface the conflict and stop; they do not silently pick a winner.

Examples:

- `/adopt-roadmap` — fully interactive: detects the legacy layout, proposes a plan, lets the user edit it before writing.
- `/adopt-roadmap --layout indexed` — adopt into indexed layout (one task file per item).
- `/adopt-roadmap --yes` — non-interactive adoption with auto-classification; everything open → `Medium Priority`, empty in-progress slot, unknown fields → `TODO`.
- `/adopt-roadmap --format atelier` — adopt into the PLAN.md §5 layout (`P0`/`P1`/`P2` + type tags) so the result is ready for `/atelier:plan-task` → `/atelier:next-task`.

## Invoked by atelier

atelier's `/setup-project` detects a non-conforming `IN_PROGRESS.md` (a phase tracker rather than an empty slot) and offers to run this command. When invoked that way it runs interactively by default so the operator reviews the plan; the delegation is opt-in and never overwrites tracking files without confirmation. For an atelier-managed project the delegation passes `--format atelier`, so the adopted `ROADMAP.md` lands in the PLAN.md §5 layout that `task-discovery` parses — the operator then fills any `` `TODO-type` `` / `` `~TODO` `` placeholders and runs `/atelier:plan-task <id>` to make a task claimable. Without `--format atelier`, adoption normalizes the tracking files (and clears a phase-tracker `IN_PROGRESS.md`) but leaves `ROADMAP.md` in the `High`/`Medium`/`Low` layout.
