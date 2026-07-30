#!/usr/bin/env bash
# Regression test for the migrate-roadmap step-5d exclude/tracking-cleanup bug
# (task #44).
#
# Bug: the forward legs with mirror (5b.7 / 5c.7 / 5e.7) append ROADMAP.md,
# IN_PROGRESS.md, HISTORY.md, roadmap/, .plan/ to `.git/info/exclude` and
# `git rm --cached` anything already tracked. The reverse leg (step 5d) removed
# `.roadmap.json` (flipping authority to local files) but never reverted those
# exclude entries and never re-tracked the reconstructed files. Result: the
# now-canonical files stayed excluded and untracked -- `git status` hid them,
# the migration was not reviewable as a single git diff, a fresh clone had no
# roadmap, and `git clean -fdx` would delete the only local copy of the source
# of truth (the remote is no longer authority and `backendId`s were stripped).
#
# Fix: a new step 5d.5 was inserted BEFORE the `.roadmap.json` removal. It
# reverts the forward legs' local git tracking changes (surgically removes
# only those exact entries from `.git/info/exclude`, guarded on the repo root
# being inside a git working tree, never touching `.gitignore` or unrelated
# entries) and `git add`s the reconstructed artefacts so the migration is
# reviewable as a single git diff -- without committing. Subsequent steps were
# renumbered (old 5->6, 6->7, 7->8).
#
# This test pins that behaviour by asserting against the prose of
# commands/migrate-roadmap.md. It does not execute the command (there is no
# interpreter for it) -- it is a text-fixture regression test.
#
# Override TARGET_FILE to point at an arbitrary copy of the doc (used to
# verify this test goes RED against the pre-fix text).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILE="${TARGET_FILE:-$REPO_ROOT/commands/migrate-roadmap.md}"

failures=0

fail() {
  echo "  FAIL: $1"
  failures=$((failures + 1))
}

if [ ! -f "$TARGET_FILE" ]; then
  echo "  FAIL: target file not found: $TARGET_FILE"
  exit 1
fi

total_lines="$(wc -l < "$TARGET_FILE" | tr -d ' ')"

# --- Locate the 5d section (`<remote backend> -> files (indexed)`) so
# assertions can be scoped to it. A match in the forward legs (5b.7 / 5c.7 /
# 5e.7), which live outside this range, must NOT satisfy a 5d-scoped
# assertion -- that is the crux of the RED/GREEN distinction for this bug. ---
section_5d_start_line="$(grep -n '^### 5d\.' "$TARGET_FILE" | head -1)"
section_5e_start_line="$(grep -n '^### 5e\.' "$TARGET_FILE" | head -1)"

if [ -z "$section_5d_start_line" ]; then
  fail "could not find the '### 5d.' section header at all"
  echo "  ok: n/a" >/dev/null # placeholder, real exit below
  echo "  (aborting further assertions -- no 5d section to scope them to)"
  exit 1
fi

section_5d_start="${section_5d_start_line%%:*}"
if [ -n "$section_5e_start_line" ]; then
  section_5e_start="${section_5e_start_line%%:*}"
  section_5d_end=$((section_5e_start - 1))
else
  section_5d_end="$total_lines"
fi

section_5d_text="$(sed -n "${section_5d_start},${section_5d_end}p" "$TARGET_FILE")"

# --- Assertion 1: step 5d documents REMOVING the forward legs' entries from
# `.git/info/exclude` -- scoped strictly to the 5d section's line range so a
# match in the forward legs' append (5b.7 / 5c.7 / 5e.7) cannot satisfy it. --
exclude_removal_line="$(printf '%s\n' "$section_5d_text" | grep -niE 'remov(e|ed|ing).*\.git/info/exclude|\.git/info/exclude.*remov(e|ed|ing)' | head -1)"
if [ -z "$exclude_removal_line" ]; then
  fail "step 5d (lines $section_5d_start-$section_5d_end) does not document removing/reverting the forward legs' .git/info/exclude entries"
fi

# --- Assertion 2: step 5d documents re-tracking the reconstructed files
# (`git add`) and the single-reviewable-diff property. -----------------------
if ! printf '%s\n' "$section_5d_text" | grep -q 'git add'; then
  fail "step 5d does not document 'git add'-ing the reconstructed artefacts to re-track them"
fi
if ! printf '%s\n' "$section_5d_text" | grep -qi 'reviewable.*git diff\|single reviewable'; then
  fail "step 5d does not state the single-reviewable-diff property for the re-tracked artefacts"
fi

# --- Assertion 3: FAIL-SAFE ORDERING -- the exclude-cleanup / re-track step
# appears BEFORE the `.roadmap.json` removal step within 5d, and the
# fail-safe rationale is stated in the prose. --------------------------------
cleanup_step_line="$(grep -n "re-track the reconstructed files" "$TARGET_FILE" | head -1)"
removal_step_line="$(grep -n 'Remove `\.roadmap\.json` as the inverse atomic checkpoint' "$TARGET_FILE" | head -1)"

if [ -z "$cleanup_step_line" ]; then
  fail "could not find the exclude-cleanup / re-track step ('re-track the reconstructed files') at all"
fi
if [ -z "$removal_step_line" ]; then
  fail "could not find the '.roadmap.json' removal step ('Remove .roadmap.json as the inverse atomic checkpoint') at all"
fi
if [ -n "$cleanup_step_line" ] && [ -n "$removal_step_line" ]; then
  cleanup_step_lineno="${cleanup_step_line%%:*}"
  removal_step_lineno="${removal_step_line%%:*}"
  if [ "$cleanup_step_lineno" -ge "$removal_step_lineno" ]; then
    fail "exclude-cleanup/re-track step (line $cleanup_step_lineno) does not come BEFORE the .roadmap.json removal step (line $removal_step_lineno) -- the fail-safe ordering is missing"
  fi
  if ! printf '%s\n' "$section_5d_text" | grep -qi 're-runnable\|leave.*\.roadmap\.json.*in place\|still present and the migration is cleanly re-runnable'; then
    fail "step 5d does not state the fail-safe rationale (that running cleanup before removing .roadmap.json keeps the migration re-runnable on failure)"
  fi
fi

# --- Assertion 4: NO DANGLING CROSS-REFERENCES -- every self-referential
# `5d.N` reference in the file points at a step number that actually exists
# in the renumbered 5d sequence (1..8: precondition, pull, show-plan,
# reconstruct, revert-exclude+re-track, remove-roadmap-json,
# partial-failure-guard, continue-to-report).
#
# Deliberate exception: the 5e.1 line references "steps 5d.1-5d.4 of
# `/create-roadmap`" -- that is about a DIFFERENT file's (create-roadmap.md's)
# own step numbering, not this file's 5d sequence. It is identified and
# excluded by its co-occurring "/create-roadmap" reference, not by line
# number, so the exclusion stays correct if the file is edited further. ------
min_valid_step=1
max_valid_step=8

dangling_found=0
while IFS=: read -r lineno linetext; do
  case "$linetext" in
    *"/create-roadmap"*)
      continue # the documented exception: a different file's numbering
      ;;
  esac
  refs="$(printf '%s' "$linetext" | grep -oE '5d\.[0-9]+' | sed 's/^5d\.//')"
  for n in $refs; do
    if [ "$n" -lt "$min_valid_step" ] || [ "$n" -gt "$max_valid_step" ]; then
      fail "dangling cross-reference '5d.$n' at line $lineno (valid range is 5d.$min_valid_step-5d.$max_valid_step): $linetext"
      dangling_found=1
    fi
  done
done <<EOF
$(grep -n '5d\.[0-9]' "$TARGET_FILE")
EOF

# --- Assertion 5: FORWARD LEGS INTACT -- 5b.7 / 5c.7 / 5e.7 still describe
# the exclude append + `git rm --cached` behaviour (guard against the fix
# over-correcting and gutting the forward direction). ------------------------
section_5b_start_line="$(grep -n '^### 5b\.' "$TARGET_FILE" | head -1)"
section_5c_start_line="$(grep -n '^### 5c\.' "$TARGET_FILE" | head -1)"

if [ -z "$section_5b_start_line" ] || [ -z "$section_5c_start_line" ]; then
  fail "could not locate the '### 5b.' or '### 5c.' section headers to verify the forward legs"
else
  section_5b_start="${section_5b_start_line%%:*}"
  section_5c_start="${section_5c_start_line%%:*}"
  section_5b_text="$(sed -n "${section_5b_start},$((section_5c_start - 1))p" "$TARGET_FILE")"
  section_5c_text="$(sed -n "${section_5c_start},$((section_5d_start - 1))p" "$TARGET_FILE")"
  section_5e_text="$(sed -n "${section_5e_start:-$((total_lines + 1))},${total_lines}p" "$TARGET_FILE")"

  check_forward_leg_intact() {
    label="$1"
    text="$2"
    if ! printf '%s\n' "$text" | grep -Eqi 'append.*\.git/info/exclude|\.git/info/exclude.*append'; then
      fail "$label no longer documents appending to .git/info/exclude on mirror:true"
    fi
    if ! printf '%s\n' "$text" | grep -q 'git rm --cached'; then
      fail "$label no longer documents 'git rm --cached' for already-tracked files"
    fi
  }

  check_forward_leg_intact "step 5b.7 (files -> linear)" "$section_5b_text"
  check_forward_leg_intact "step 5c.7 (files -> github-project)" "$section_5c_text"
  if [ -z "$section_5e_start_line" ]; then
    fail "could not locate the '### 5e.' section header to verify step 5e.7"
  else
    check_forward_leg_intact "step 5e.7 (files -> github-issues)" "$section_5e_text"
  fi
fi

# --- Assertion 6: `.gitignore` is NOT introduced as the reverse leg's
# cleanup mechanism -- the forward legs are explicit these are local-only
# artefacts and `.gitignore` is never used. Any mention of `.gitignore`
# inside 5d must be in a "never touch it" sense, not an editing instruction. -
if printf '%s\n' "$section_5d_text" | grep -Ei 'edit \.gitignore|add.*to \.gitignore|update \.gitignore|write.*\.gitignore|modify \.gitignore' | grep -viq 'never'; then
  fail "step 5d appears to instruct editing .gitignore -- these must stay local-only via .git/info/exclude, never the committed .gitignore"
fi
if printf '%s\n' "$section_5d_text" | grep -qi '\.gitignore'; then
  if ! printf '%s\n' "$section_5d_text" | grep -i '\.gitignore' | grep -qi 'never'; then
    fail "step 5d mentions .gitignore but not in a 'never touch it' sense"
  fi
fi

# --- Assertion 7: EXCLUDE REMOVAL IS UNCONDITIONAL, NOT SCOPED TO WHAT WAS
# RECONSTRUCTED -- step 5d.5's exclude-removal bullet must (a) name all five
# entries the forward legs may have added (`ROADMAP.md`, `IN_PROGRESS.md`,
# `HISTORY.md`, `roadmap/`, `.plan/`) as the removal set, so a future edit
# that silently drops `.plan/` from the list is caught, and (b) state the
# removal is unconditional -- not restricted/scoped to whichever artefacts
# step 5d.4 actually reconstructed. `.plan/` is only reconstructed when a
# task body carried an `atelier:plan` section, so a "restricted to what was
# reconstructed" qualifier would silently leave `.plan/` excluded for the
# common no-plans case after authority flips to files -- exactly the class
# of bug this PR fixes. Scoped strictly to the 5d section's line range. -----
exclude_removal_bullet="$(printf '%s\n' "$section_5d_text" | grep -i 'Remove from `\.git/info/exclude`' | head -1)"
if [ -z "$exclude_removal_bullet" ]; then
  fail "step 5d (lines $section_5d_start-$section_5d_end) has no 'Remove from \`.git/info/exclude\`' bullet to check for unconditional scope"
else
  for entry in 'ROADMAP.md' 'IN_PROGRESS.md' 'HISTORY.md' 'roadmap/' '.plan/'; do
    if ! printf '%s' "$exclude_removal_bullet" | grep -qF "$entry"; then
      fail "step 5d's exclude-removal bullet does not name '$entry' in the removal set"
    fi
  done
  if ! printf '%s' "$exclude_removal_bullet" | grep -qi 'unconditionally'; then
    fail "step 5d's exclude-removal bullet does not state the removal is unconditional"
  fi
  if printf '%s' "$exclude_removal_bullet" | grep -Eqi 'restrict(ed)?[[:space:]]+to|only\b[^.]*reconstruct|scoped\b[^.]*reconstruct|correspond(s|ing)?[[:space:]]+to\b[^.]*reconstruct'; then
    fail "step 5d's exclude-removal bullet appears to restrict/scope the removal to whichever artefacts were actually reconstructed -- the removal must be unconditional (all five entries, always), or the next backend with no plans will leave '.plan/' silently excluded after authority flips to files"
  fi
fi

if [ "$failures" -eq 0 ]; then
  echo "  ok: step 5d reverts the forward legs' .git/info/exclude entries (unconditionally, naming all five entries) and re-tracks the reconstructed files before removing .roadmap.json, cross-references are intact, forward legs are untouched, and .gitignore is never the mechanism"
  exit 0
fi

exit 1
