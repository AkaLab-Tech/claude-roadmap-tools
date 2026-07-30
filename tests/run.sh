#!/usr/bin/env bash
# Auto-discovers and runs every tests/*.test.sh in this directory.
# Hermetic: no network access, no installs, no mutation of the repo tree.
# Usage: tests/run.sh (from anywhere; resolves paths relative to this file).

set -u

# Resolve this script's own directory so the suite runs correctly regardless
# of the caller's cwd (macOS/BSD-compatible; no `readlink -f`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT

pass_count=0
fail_count=0
failed_files=()

for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -e "$test_file" ] || continue
  name="$(basename "$test_file")"
  if bash "$test_file"; then
    echo "PASS  $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL  $name"
    fail_count=$((fail_count + 1))
    failed_files+=("$name")
  fi
done

total=$((pass_count + fail_count))
echo "---"
echo "$pass_count/$total test files passed"

if [ "$fail_count" -gt 0 ]; then
  echo "Failed: ${failed_files[*]}"
  exit 1
fi

exit 0
