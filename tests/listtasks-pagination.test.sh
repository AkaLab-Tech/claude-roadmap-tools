#!/usr/bin/env bash
# Regression test for the listTasks pagination/truncation bug (task #45, P1).
#
# Bug: `listTasks` specs silently truncated results past a single page/call:
# - `GitHubIssuesBackend.listTasks` ran `gh issue list ... --json
#   number,title,body,labels` with NO `--limit` -- `gh` defaults to 30 and
#   silently drops everything past the 30th matching issue.
# - The `LinearBackend` and `GitHubProjectBackend` `listTasks` specs never
#   mandated exhausting cursor pagination, so a single default page of
#   results was implicitly assumed to be the complete bucket.
# - The mirror auto-refresh (SKILL.md) and the reverse migration's step 5d.2
#   (commands/migrate-roadmap.md) both rebuild local tracking files straight
#   from `listTasks` and promise losslessness -- with more than a page/limit
#   worth of items, they silently dropped entries with no error.
#
# Fix: five places now mandate exhausting pagination / a non-truncating
# limit and verifying completeness before any file gets (re)written:
# 1. SKILL.md LinearBackend `listTasks` -- exhaust cursor pagination to
#    `hasNextPage: false`.
# 2. SKILL.md GitHubProjectBackend `listTasks` -- same, for
#    `project-item-list`.
# 3. SKILL.md GitHubIssuesBackend `listTasks` -- mandatory `gh issue list
#    --limit 1000` plus a count-verification re-issue rule when a call
#    returns exactly the limit.
# 4. SKILL.md mirror auto-refresh -- a completeness-verification paragraph
#    before regenerating bucket files, routing an unconfirmable bucket to
#    the Safe failure mode instead of writing a partial result.
# 5. commands/migrate-roadmap.md step 5d.2 (+ docs/RoadmapBackend.md) --
#    completeness verification before step 3 (writing the reconstruction
#    plan), and the same per-backend pagination/limit mandates restated in
#    the canonical operation contract.
#
# This test pins that behaviour by asserting against the prose of SKILL.md,
# commands/migrate-roadmap.md, and docs/RoadmapBackend.md. It does not
# execute anything (there is no interpreter for these specs) -- it is a
# text-fixture regression test, following the style of the existing
# migrate-reverse-*.test.sh tests in this directory.
#
# Override TARGET_SKILL_FILE / TARGET_MIGRATE_FILE / TARGET_DOCS_FILE to
# point at arbitrary copies of the docs (used to verify this test goes RED
# against the pre-fix text).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILL_FILE="${TARGET_SKILL_FILE:-$REPO_ROOT/skills/roadmap-tracking-flow/SKILL.md}"
MIGRATE_FILE="${TARGET_MIGRATE_FILE:-$REPO_ROOT/commands/migrate-roadmap.md}"
DOCS_FILE="${TARGET_DOCS_FILE:-$REPO_ROOT/docs/RoadmapBackend.md}"

failures=0

fail() {
  echo "  FAIL: $1"
  failures=$((failures + 1))
}

for f in "$SKILL_FILE" "$MIGRATE_FILE" "$DOCS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "  FAIL: target file not found: $f"
    exit 1
  fi
done

# --- Helpers ------------------------------------------------------------
# first_line_after FILE PATTERN AFTER
#   Line number of the first occurrence of the fixed-string PATTERN in FILE
#   that is strictly after line AFTER. Empty if not found.
first_line_after() {
  local file="$1" pattern="$2" after="$3"
  grep -Fn "$pattern" "$file" | awk -F: -v a="$after" '$1 > a {print $1; exit}'
}

# section_text FILE START END
#   Lines START..END (inclusive) of FILE.
section_text() {
  local file="$1" start="$2" end="$3"
  sed -n "${start},${end}p" "$file"
}

# ==========================================================================
# Part 1: SKILL.md -- per-backend listTasks() pagination/limit mandates.
# ==========================================================================

linear_ops_line="$(first_line_after "$SKILL_FILE" '## Operations (`LinearBackend`)' 0)"
ghproject_ops_line="$(first_line_after "$SKILL_FILE" '## Operations (`GitHubProjectBackend`)' 0)"
ghissues_ops_line="$(first_line_after "$SKILL_FILE" '## Operations (`GitHubIssuesBackend`)' 0)"
mirror_line="$(first_line_after "$SKILL_FILE" '## Mirror auto-refresh on activation' 0)"
format_conventions_line="$(first_line_after "$SKILL_FILE" '## Format conventions' 0)"

for pair in "linear_ops_line:## Operations (\`LinearBackend\`)" \
            "ghproject_ops_line:## Operations (\`GitHubProjectBackend\`)" \
            "ghissues_ops_line:## Operations (\`GitHubIssuesBackend\`)" \
            "mirror_line:## Mirror auto-refresh on activation" \
            "format_conventions_line:## Format conventions"; do
  var="${pair%%:*}"
  label="${pair#*:}"
  val="$(eval echo "\$$var")"
  if [ -z "$val" ]; then
    fail "could not locate the '$label' section header in $SKILL_FILE"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "  (aborting SKILL.md section assertions -- required section headers missing)"
  exit 1
fi

# Scope each backend's `listTasks(bucket)` prose to just that subsection:
# from the `### \`listTasks(bucket)\`` heading (first occurrence AFTER the
# backend's own `## Operations (...)` heading, so this can never accidentally
# match a different backend's listTasks section) to just before the next
# `### \`getTask(id)\`` heading.
extract_listtasks_section() {
  local ops_line="$1"
  local start end_heading end
  start="$(first_line_after "$SKILL_FILE" '### `listTasks(bucket)`' "$ops_line")"
  if [ -z "$start" ]; then
    echo ""
    return 1
  fi
  end_heading="$(first_line_after "$SKILL_FILE" '### `getTask(id)`' "$start")"
  if [ -z "$end_heading" ]; then
    end="$(wc -l < "$SKILL_FILE" | tr -d ' ')"
  else
    end=$((end_heading - 1))
  fi
  section_text "$SKILL_FILE" "$start" "$end"
  return 0
}

linear_listtasks_text="$(extract_listtasks_section "$linear_ops_line")" || fail "could not find LinearBackend's 'listTasks(bucket)' subsection"
ghproject_listtasks_text="$(extract_listtasks_section "$ghproject_ops_line")" || fail "could not find GitHubProjectBackend's 'listTasks(bucket)' subsection"
ghissues_listtasks_text="$(extract_listtasks_section "$ghissues_ops_line")" || fail "could not find GitHubIssuesBackend's 'listTasks(bucket)' subsection"

# --- Assertion 1: LinearBackend listTasks mandates exhausting cursor
# pagination. -------------------------------------------------------------
if [ -n "$linear_listtasks_text" ]; then
  if ! printf '%s\n' "$linear_listtasks_text" | grep -qi 'exhaust pagination'; then
    fail "LinearBackend's listTasks(bucket) does not mandate exhausting pagination ('Exhaust pagination')"
  fi
  if ! printf '%s\n' "$linear_listtasks_text" | grep -q 'hasNextPage'; then
    fail "LinearBackend's listTasks(bucket) does not reference 'hasNextPage' cursor semantics"
  fi
  if ! printf '%s\n' "$linear_listtasks_text" | grep -qi 'union all pages'; then
    fail "LinearBackend's listTasks(bucket) does not state that all pages must be unioned before building task elements"
  fi
  if ! printf '%s\n' "$linear_listtasks_text" | grep -qi 'truncat'; then
    fail "LinearBackend's listTasks(bucket) does not warn that stopping early silently truncates the bucket"
  fi
fi

# --- Assertion 2: GitHubProjectBackend listTasks mandates exhausting cursor
# pagination. -------------------------------------------------------------
if [ -n "$ghproject_listtasks_text" ]; then
  if ! printf '%s\n' "$ghproject_listtasks_text" | grep -qi 'exhaust pagination'; then
    fail "GitHubProjectBackend's listTasks(bucket) does not mandate exhausting pagination ('Exhaust pagination')"
  fi
  if ! printf '%s\n' "$ghproject_listtasks_text" | grep -q 'hasNextPage'; then
    fail "GitHubProjectBackend's listTasks(bucket) does not reference 'hasNextPage' cursor semantics"
  fi
  if ! printf '%s\n' "$ghproject_listtasks_text" | grep -qi 'union all pages'; then
    fail "GitHubProjectBackend's listTasks(bucket) does not state that all pages must be unioned before filtering"
  fi
  if ! printf '%s\n' "$ghproject_listtasks_text" | grep -qi 'truncat'; then
    fail "GitHubProjectBackend's listTasks(bucket) does not warn that stopping early silently truncates the bucket"
  fi
fi

# --- Assertion 3: GitHubIssuesBackend listTasks -- every `gh issue list`
# invocation carries an explicit `--limit`, the limit is stated as
# mandatory, and a count-verification re-issue rule exists for the
# limit-hit case. -----------------------------------------------------------
if [ -n "$ghissues_listtasks_text" ]; then
  gh_issue_list_lines="$(printf '%s\n' "$ghissues_listtasks_text" | grep -F 'gh issue list')"
  if [ -z "$gh_issue_list_lines" ]; then
    fail "GitHubIssuesBackend's listTasks(bucket) does not contain a 'gh issue list' invocation at all"
  else
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if ! printf '%s' "$line" | grep -q -- '--limit'; then
        fail "a 'gh issue list' invocation in GitHubIssuesBackend's listTasks(bucket) has no explicit --limit: $line"
      fi
      # Guard: the fix must not have dropped the --json field list while
      # adding --limit.
      if ! printf '%s' "$line" | grep -q -- '--json number,title,body,labels'; then
        fail "a 'gh issue list' invocation lost its '--json number,title,body,labels' field list: $line"
      fi
    done <<EOF
$gh_issue_list_lines
EOF
  fi

  if ! printf '%s\n' "$ghissues_listtasks_text" | grep -qi -- '--limit 1000.*mandatory\|mandatory.*--limit'; then
    fail "GitHubIssuesBackend's listTasks(bucket) does not state that an explicit --limit is mandatory"
  fi
  if ! printf '%s\n' "$ghissues_listtasks_text" | grep -qi 're-issue.*higher.*--limit\|re-issue the call with a higher'; then
    fail "GitHubIssuesBackend's listTasks(bucket) does not mandate re-issuing with a higher --limit when a call returns exactly the limit"
  fi
  if ! printf '%s\n' "$ghissues_listtasks_text" | grep -qi 'fewer than its limit'; then
    fail "GitHubIssuesBackend's listTasks(bucket) does not state the stopping condition (a call returning fewer than its limit confirms completeness)"
  fi
fi

# --- Assertion 4: Mirror auto-refresh mandates completeness verification
# before regenerating bucket files, and routes an unconfirmable bucket to
# the Safe failure mode. ---------------------------------------------------
mirror_end=$((format_conventions_line - 1))
mirror_text="$(section_text "$SKILL_FILE" "$mirror_line" "$mirror_end")"

if ! printf '%s\n' "$mirror_text" | grep -qi 'exhaust pagination\|non-truncating limit'; then
  fail "mirror auto-refresh does not mandate exhausting pagination / a non-truncating limit before regenerating bucket files"
fi
if ! printf '%s\n' "$mirror_text" | grep -qi 'verify the returned set is complete'; then
  fail "mirror auto-refresh does not mandate verifying the returned set is complete before regenerating a bucket's files"
fi
if ! printf '%s\n' "$mirror_text" | grep -qi 'safe failure mode'; then
  fail "mirror auto-refresh does not route an unconfirmable/incomplete bucket to the Safe failure mode"
fi
if ! printf '%s\n' "$mirror_text" | grep -qi 'partial result'; then
  fail "mirror auto-refresh does not explicitly forbid regenerating a bucket from a partial result"
fi

# ==========================================================================
# Part 2: commands/migrate-roadmap.md -- step 5d.2 completeness
# verification before writing (step 3).
# ==========================================================================

section_5d_start_line="$(grep -n '^### 5d\.' "$MIGRATE_FILE" | head -1 | cut -d: -f1)"
section_5e_start_line="$(grep -n '^### 5e\.' "$MIGRATE_FILE" | head -1 | cut -d: -f1)"

if [ -z "$section_5d_start_line" ]; then
  fail "could not find the '### 5d.' section header in $MIGRATE_FILE at all"
else
  if [ -n "$section_5e_start_line" ]; then
    section_5d_end=$((section_5e_start_line - 1))
  else
    section_5d_end="$(wc -l < "$MIGRATE_FILE" | tr -d ' ')"
  fi
  section_5d_text="$(section_text "$MIGRATE_FILE" "$section_5d_start_line" "$section_5d_end")"

  if ! printf '%s\n' "$section_5d_text" | grep -Fq 'returned the full result set'; then
    fail "step 5d does not mandate verifying each listTasks call returned the full result set"
  fi
  if ! printf '%s\n' "$section_5d_text" | grep -Fq 'stop before step 3'; then
    fail "step 5d does not stop before step 3 (writing the reconstruction plan) when completeness cannot be confirmed"
  fi
  if ! printf '%s\n' "$section_5d_text" | grep -qi 'page/limit boundary'; then
    fail "step 5d does not state the rationale (silently dropping items past a page/limit boundary breaks losslessness)"
  fi

  # Ordering: the completeness-verification bullet must sit within step 2
  # ("Pull all three buckets"), i.e. after that step's own heading and
  # before step 3's heading ("Show the full reconstruction plan").
  pull_line="$(grep -Fn '**Pull all three buckets.**' "$MIGRATE_FILE" | awk -F: -v s="$section_5d_start_line" '$1 > s {print $1; exit}')"
  verify_line="$(grep -Fn 'returned the full result set' "$MIGRATE_FILE" | awk -F: -v s="$section_5d_start_line" '$1 > s {print $1; exit}')"
  show_plan_line="$(grep -Fn '**Show the full reconstruction plan before writing anything.**' "$MIGRATE_FILE" | awk -F: -v s="$section_5d_start_line" '$1 > s {print $1; exit}')"

  if [ -z "$pull_line" ]; then
    fail "could not find step 5d's 'Pull all three buckets' heading"
  fi
  if [ -z "$show_plan_line" ]; then
    fail "could not find step 5d's 'Show the full reconstruction plan before writing anything' heading"
  fi
  if [ -n "$pull_line" ] && [ -n "$verify_line" ] && [ -n "$show_plan_line" ]; then
    if [ "$verify_line" -le "$pull_line" ] || [ "$verify_line" -ge "$show_plan_line" ]; then
      fail "the completeness-verification bullet (line $verify_line) is not between 'Pull all three buckets' (line $pull_line) and 'Show the full reconstruction plan' (line $show_plan_line)"
    fi
  fi
fi

# ==========================================================================
# Part 3: docs/RoadmapBackend.md -- the canonical listTasks(bucket) contract
# restates the same per-backend mandates, and the buckets table restates the
# completeness-before-reconstruction rule.
# ==========================================================================

docs_listtasks_start="$(first_line_after "$DOCS_FILE" '### `listTasks(bucket)`' 0)"
if [ -z "$docs_listtasks_start" ]; then
  fail "could not find the '### \`listTasks(bucket)\`' section header in $DOCS_FILE"
else
  docs_end_heading="$(first_line_after "$DOCS_FILE" '### `getTask(id)`' "$docs_listtasks_start")"
  if [ -z "$docs_end_heading" ]; then
    docs_listtasks_end="$(wc -l < "$DOCS_FILE" | tr -d ' ')"
  else
    docs_listtasks_end=$((docs_end_heading - 1))
  fi
  docs_listtasks_text="$(section_text "$DOCS_FILE" "$docs_listtasks_start" "$docs_listtasks_end")"

  linear_bullet="$(printf '%s\n' "$docs_listtasks_text" | grep -F '**`LinearBackend`**' | head -1)"
  ghproject_bullet="$(printf '%s\n' "$docs_listtasks_text" | grep -F '**`GitHubProjectBackend`**' | head -1)"
  ghissues_bullet="$(printf '%s\n' "$docs_listtasks_text" | grep -F '**`GitHubIssuesBackend`**' | head -1)"

  if [ -z "$linear_bullet" ]; then
    fail "docs/RoadmapBackend.md listTasks(bucket) has no LinearBackend bullet"
  elif ! printf '%s' "$linear_bullet" | grep -qi 'must exhaust pagination'; then
    fail "docs/RoadmapBackend.md LinearBackend listTasks(bucket) bullet does not mandate exhausting pagination: $linear_bullet"
  fi

  if [ -z "$ghproject_bullet" ]; then
    fail "docs/RoadmapBackend.md listTasks(bucket) has no GitHubProjectBackend bullet"
  elif ! printf '%s' "$ghproject_bullet" | grep -qi 'must exhaust pagination'; then
    fail "docs/RoadmapBackend.md GitHubProjectBackend listTasks(bucket) bullet does not mandate exhausting pagination: $ghproject_bullet"
  fi

  if [ -z "$ghissues_bullet" ]; then
    fail "docs/RoadmapBackend.md listTasks(bucket) has no GitHubIssuesBackend bullet"
  else
    if ! printf '%s' "$ghissues_bullet" | grep -q -- '--limit 1000'; then
      fail "docs/RoadmapBackend.md GitHubIssuesBackend listTasks(bucket) bullet does not mandate '--limit 1000': $ghissues_bullet"
    fi
    if ! printf '%s' "$ghissues_bullet" | grep -qi 'mandatory'; then
      fail "docs/RoadmapBackend.md GitHubIssuesBackend listTasks(bucket) bullet does not state the limit is mandatory: $ghissues_bullet"
    fi
  fi
fi

if ! grep -qi 'completeness must be verified' "$DOCS_FILE"; then
  fail "docs/RoadmapBackend.md's buckets table does not state that each listTasks call's completeness must be verified before a bucket is reconstructed"
fi

if [ "$failures" -eq 0 ]; then
  echo "  ok: listTasks pagination/limit mandates present across SKILL.md (linear/github-project/github-issues/mirror-refresh), migrate-roadmap.md step 5d.2, and docs/RoadmapBackend.md"
  exit 0
fi

exit 1
