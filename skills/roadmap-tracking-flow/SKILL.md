---
name: roadmap-tracking-flow
description: Consult this skill whenever the current repository's root contains all three of `ROADMAP.md`, `IN_PROGRESS.md` and `HISTORY.md`, or when the user explicitly mentions task tracking, the roadmap, what is in progress, history of completed work, or moving a task between those files. The skill defines the flow `ROADMAP → IN_PROGRESS → HISTORY`, the pre-merge tracking rule, how to propose the next task, and the entry format for each file. It supports two layouts: single-file (everything in `ROADMAP.md`) and indexed (titles in `ROADMAP.md`, one `roadmap/TASK_NNN_<slug>.md` per task). Skip for read-only chats that do not touch tracking, for trivial edits, and once the user has declined applying it earlier in the session.
---

# roadmap-tracking-flow skill

Keep the user's task tracking consistent across the three top-level files (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`) and, when the repo uses it, the `roadmap/` folder of per-task files.

## When this skill applies

Activate the rules below when **either**:

1. The current repository's root contains **all three** of `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, **or**
2. The user explicitly references the flow ("move this to HISTORY", "what is in progress?", "next task from the roadmap", "log this PR").

Otherwise, leave it alone — do not invent these files, and do not suggest the flow on repos that do not use it. If the user asks to set the flow up on a repo that does not yet have it, point them at `/create-roadmap`.

## Layouts: single-file vs indexed

Detect which layout the repo uses **before** acting:

- **Indexed layout** — a `roadmap/` folder exists at the repo root and contains files named `TASK_NNN_<slug>.md`. `ROADMAP.md` is an index of titles linking to those files; the long descriptions live inside each `TASK_NNN_<slug>.md`. `IN_PROGRESS.md` links to the same task files; progress updates are written **inside** the task file, not in `IN_PROGRESS.md`.
- **Single-file layout** — no `roadmap/` folder. `ROADMAP.md` itself contains both titles and full descriptions. `IN_PROGRESS.md` holds the active task content directly (checkboxes, sub-stories, etc.).

When unsure, run a quick check: list the repo root and look for `roadmap/`. Pick the layout that matches; do not mix them in the same operation.

## The flow

```
ROADMAP.md  ──(start work)──▶  IN_PROGRESS.md  ──(merge PR)──▶  HISTORY.md
```

- A task moves to `IN_PROGRESS.md` only when work actually starts. Do not pre-stage tasks there "for later".
- A task is logged in `HISTORY.md` when its PR(s) are ready to merge. See the pre-merge rule below.
- `ROADMAP.md` is the backlog. It can hold ideas that may never ship; that is fine.

## Pre-merge tracking rule (load-bearing)

When a PR closes a tracked task, **the same PR** must contain both:

1. The removal of the task from `IN_PROGRESS.md`.
2. The new entry in `HISTORY.md` referencing that PR.

Never defer either step to a follow-up commit on the protected branch after merge. The user's flow treats `main` (or equivalent) as a place that should never carry orphan tracking commits.

If the PR is opened without the tracking updates, push them as additional commits to the **same branch** before requesting merge — not after.

## Proposing the next task

When the user asks "what's next?" or equivalent:

1. **Read `IN_PROGRESS.md` first.** If something is active there, surface it as the default — do not propose a fresh task while another is mid-flight unless the user explicitly wants to switch.
2. **Then read `ROADMAP.md`.** Propose **1–3 candidates** with:
   - Title and a one-line summary.
   - The main tradeoff or risk (what makes it big/risky/blocking).
   - Any obvious dependencies between candidates.
3. **Ask before starting.** Do not move anything to `IN_PROGRESS.md` without the user's OK.

In **indexed layout**, open the corresponding `roadmap/TASK_NNN_<slug>.md` to read the full description before proposing — do not summarize from the title alone.

## Adding a new task to the `ROADMAP`

When the user asks to add a new task (or to "put X on the roadmap"):

1. **Confirm scope and priority.** If the user has not specified a priority section (`High`, `Medium`, `Low / Ideas`, or whatever sections the file uses), ask. Do not invent new sections without asking.
2. **Apply the layout-specific procedure below.**
3. **Do not touch `IN_PROGRESS.md` or `HISTORY.md`.** A new task starts in the backlog only. It moves to `IN_PROGRESS.md` when work actually begins (see the next section).

### Single-file layout

Append a new task block under the chosen priority section in `ROADMAP.md`. Match the structure already used by surrounding entries:

```markdown
### <Title>

Short framing of what the task is and why it matters.

- [ ] Sub-task 1
- [ ] Sub-task 2

**Acceptance:** what "done" looks like.
```

If sibling tasks use a richer template (e.g. they include "Design notes" or "Out of scope" subsections), match that. Consistency wins over the minimal template above.

### Indexed layout

1. **Pick the next number.** List `roadmap/` and find the highest existing `TASK_NNN_*.md`. The new file gets `NNN + 1`, zero-padded to three digits. Numbers are never reused — even if older tasks were cancelled or are missing, do not fill gaps.
2. **Derive the slug.** Kebab-case, lowercase, ASCII only, derived from the title. Strip articles (`the`, `a`) and stop-words at the user's discretion. Keep it short — 3 to 6 words is a good target.
3. **Create `roadmap/TASK_NNN_<slug>.md`** using the standard task template:
   ```markdown
   # TASK_NNN — <Title>

   <Description paragraph: what this is and why it matters.>

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
   Adapt the sub-headings to whatever fits the task. The `# TASK_NNN — <Title>` top heading is mandatory; everything else is a starting point.
4. **Add the index entry to `ROADMAP.md`** under the chosen priority section:
   ```markdown
   - [TASK_NNN — <Title>](roadmap/TASK_NNN_<slug>.md)
   ```
   Match whatever bullet style the existing entries use (some users add a one-line summary after the link; if so, do the same).
5. **Report what was created** so the user can review the diff before committing.

### Common pitfalls to avoid

- Do not number tasks based on git history or epic boundaries — it is a strict global counter over `roadmap/`.
- Do not pre-stage a "scaffold" task file with no real description. If the user has not told you enough to fill the file, ask first.
- Do not move existing tasks around in `ROADMAP.md` while adding a new one. Append-only, unless the user asks for a reorganization.

## Moving a task `ROADMAP → IN_PROGRESS`

After the user confirms the next task:

- **Single-file layout:** cut the task block out of `ROADMAP.md` and paste it into `IN_PROGRESS.md` under a clear heading. Keep checkboxes intact.
- **Indexed layout:** remove (or strike through) the line in `ROADMAP.md`'s index and add a link to the same `roadmap/TASK_NNN_<slug>.md` from `IN_PROGRESS.md`. **Do not move or rename the task file.** Progress updates (checkbox flips, design decisions, follow-ups) go inside `roadmap/TASK_NNN_<slug>.md`. `IN_PROGRESS.md` only holds the link plus, optionally, a one-line status note.

## Logging completed work in `HISTORY.md`

Newest first. Group by month with `## YYYY-MM`. Each entry uses this shape:

```markdown
### <Title> — YYYY-MM-DD
**PR:** [#N](<full GitHub URL>)

<1–2 sentence framing of why this PR existed.>

**Delivered:**
- <bullet>
- <bullet>

**Tests:** <one line on the validation done>

**Follow-ups:** (optional)
- <bullet>
```

Conventions:

- Date is the day the PR was **opened or merged**, whichever the user prefers — match the existing entries in the file.
- The PR number is the actual one (open or merged is fine; the link works either way).
- Keep bullets concrete: name the file, function, or behavior that changed, not vague wins like "improved performance".
- "Follow-ups" is for items spawned by this PR that go back to `ROADMAP.md` (or `IN_PROGRESS.md` if the user wants them next). Cross-link them; do not leave them only in `HISTORY.md`.

In **indexed layout**, the `roadmap/TASK_NNN_<slug>.md` file is **kept as the source of truth** for what was delivered. The `HISTORY.md` entry should be a concise summary that links to both the PR and (optionally) the task file. Do not delete the task file.

## Format conventions

- All three files (and the `roadmap/` task files) are written in **English**, regardless of the chat language. Same rule the user applies to code, commits, and PR descriptions.
- Markdown only. No emojis unless the file already uses them.
- Use checkboxes (`- [ ]` / `- [x]`) inside `IN_PROGRESS.md` and inside `roadmap/TASK_NNN_<slug>.md` for sub-tasks. Do not add checkboxes inside `HISTORY.md` — entries there are immutable records, not work lists.
- Keep `ROADMAP.md` short in indexed layout. If it starts holding paragraphs again, suggest running `/migrate-roadmap` (or splitting the offending block into a new task file manually).

## When the layout needs to change

- Repo currently single-file but `ROADMAP.md` is becoming long / hard to scan: suggest `/migrate-roadmap` to switch to indexed.
- Repo currently indexed but the user wants to collapse back: do this manually — the migration command only runs forward (single-file → indexed). Do not invent a reverse migration; ask the user before touching it.

## Initialization

If the user asks to set up tracking on a repo that does not have these files yet, do not create them silently. Point them at the slash command:

> "Run `/create-roadmap` — it will ask whether you want single-file or indexed layout and create only the files that don't exist yet."

## Things this skill does NOT do

- Does not edit `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` without the user's request.
- Does not push tracking commits to a protected branch directly. Tracking updates ride on the same PR branch as the work they describe.
- Does not assume one layout — always detects first.
- Does not invent PR numbers. If the PR is not yet open, log the entry with a placeholder and ask the user to confirm the number once it exists, **before** the PR is merged.
