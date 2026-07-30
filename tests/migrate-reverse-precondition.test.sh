#!/usr/bin/env bash
# Regression test for the migrate-roadmap step-1 precondition bug.
#
# Bug: step 1 used to demand ROADMAP.md/IN_PROGRESS.md/HISTORY.md
# unconditionally, before resolving the source backend. That deadlocked
# `/migrate-roadmap --to files` for a remote source with offlineMirror:false,
# since those files legitimately do not exist for a remote-backed repo.
#
# Fix: resolve the source backend from .roadmap.json FIRST, then scope the
# three-file demand to a `files` source only; remote sources must NOT demand
# them (step 5d reconstructs them from the remote instead).
#
# This test pins that behaviour by asserting against the prose of
# commands/migrate-roadmap.md. It does not execute the command (there is no
# interpreter for it) — it is a text-fixture regression test.
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

# --- Assertion 1: the three-files precondition is scoped to a `files` source,
# not an unconditional demand. -----------------------------------------------
# Find the bullet that states the three files must exist, and require that
# the SAME bullet also carries a `files`-only qualifier ("only when" /
# "source backend ... files").
three_files_line="$(grep -n 'ROADMAP\.md.*IN_PROGRESS\.md.*HISTORY\.md.*must all exist' "$TARGET_FILE" | head -1)"
if [ -z "$three_files_line" ]; then
  fail "could not find the 'ROADMAP.md, IN_PROGRESS.md, HISTORY.md must all exist' precondition bullet at all"
else
  three_files_lineno="${three_files_line%%:*}"
  three_files_text="${three_files_line#*:}"
  case "$three_files_text" in
    *"only when"*"files"*) : ;;
    *) fail "the three-files precondition bullet is not scoped to a 'files' source (looks unconditional again): $three_files_text" ;;
  esac
fi

# --- Assertion 2: the remote-source path explicitly does NOT demand the
# three files. -----------------------------------------------------------
if ! grep -Eiq 'remote.*(linear|github-project|github-issues).*do not demand|do not demand.*(linear|github-project|github-issues)' "$TARGET_FILE"; then
  fail "no explicit statement that a remote source (linear/github-project/github-issues) must NOT demand the three tracking files"
fi

# --- Assertion 3: source backend is determined BEFORE the file-existence
# demand -- the ordering fix itself. --------------------------------------
determine_backend_line="$(grep -n 'Determine the source backend' "$TARGET_FILE" | head -1)"
if [ -z "$determine_backend_line" ]; then
  fail "could not find a 'Determine the source backend' step"
elif [ -z "$three_files_line" ]; then
  : # already reported by assertion 1
else
  determine_backend_lineno="${determine_backend_line%%:*}"
  if [ "$determine_backend_lineno" -ge "$three_files_lineno" ]; then
    fail "source-backend resolution (line $determine_backend_lineno) does not come BEFORE the three-files precondition (line $three_files_lineno) -- the deadlock-fixing order is missing"
  fi
fi

# --- Assertion 4: the files-source precondition is still present and
# intact (guard against over-correcting by deleting the check entirely). --
if ! grep -q 'ROADMAP.md' "$TARGET_FILE" || ! grep -q 'IN_PROGRESS.md' "$TARGET_FILE" || ! grep -q 'HISTORY.md' "$TARGET_FILE"; then
  fail "one or more of ROADMAP.md / IN_PROGRESS.md / HISTORY.md is no longer mentioned at all -- the files-source precondition may have been deleted"
fi
if ! grep -q '/create-roadmap' "$TARGET_FILE"; then
  fail "the 'run /create-roadmap first' remediation for a missing files-source is gone"
fi

# --- Assertion 5: Direction-matrix consistency -- <remote> -> files stays
# Supported / reachable. ---------------------------------------------------
for remote in linear github-project github-issues; do
  row="$(grep -n "^| \`${remote} → files\`" "$TARGET_FILE" | head -1)"
  if [ -z "$row" ]; then
    fail "direction matrix has no '${remote} → files' row"
  elif ! printf '%s' "$row" | grep -q 'Supported'; then
    fail "direction matrix row for '${remote} → files' is not marked Supported: $row"
  fi
done

if [ "$failures" -eq 0 ]; then
  echo "  ok: step 1 precondition correctly scoped to files-source, ordering fixed, remote paths exempted, matrix intact"
  exit 0
fi

exit 1
