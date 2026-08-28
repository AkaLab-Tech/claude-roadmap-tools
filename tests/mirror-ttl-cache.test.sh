#!/usr/bin/env bash
# Regression test for the offline-mirror TTL + cache-service contract.
#
# Problem this pins: a consumer's backlog discovery did a full paginated
# sweep of the remote board on every call, plus a per-candidate round-trip
# just to learn whether an item's content was an Issue or a DraftIssue. On a
# ~600-item board that exhausts the backend's point budget. Two competing
# refresh cadences existed and neither bounded the cost: this document said
# the mirror refreshes "every time the skill activates", while the consuming
# side throttled to once per calendar day.
#
# The contract now says:
#  1. `listTasks` gained an optional `maxStaleness`; OMITTING it is
#     authoritative, so no pre-existing call site changes meaning. Cache
#     service is explicit at the call site, never implicit.
#  2. `getTask(id)` is NEVER served from a snapshot -- it is the fresh
#     single-item read that makes cached discovery safe.
#  3. `mirrorTTL` (default "1h") replaces both the every-activation rule and
#     any calendar-day stamp; freshness is computed from an ISO-8601
#     `fetchedAt`, not inferred from a date string.
#  4. Writes are write-through: they never read the board back, and never
#     advance `fetchedAt` (a write is not a refresh -- advancing it would
#     extend every other record's staleness by a full TTL).
#  5. The task record carries `contentType` / `issueNumber` / `issueRepo` as
#     OPTIONAL, omittable fields, so the per-candidate round-trip collapses
#     into a field read without disturbing `linear` / `github-issues`.
#  6. A snapshot is untrusted input: `schemaVersion` + `complete` are checked
#     before a single record is served, else it is a cache miss.
#
# Like the other tests here, this is a text-fixture test over the prose --
# there is no interpreter for these specs. Override TARGET_SKILL_FILE /
# TARGET_DOCS_FILE to run it against arbitrary copies (used to verify it goes
# RED against the pre-fix text).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILL_FILE="${TARGET_SKILL_FILE:-$REPO_ROOT/skills/roadmap-tracking-flow/SKILL.md}"
DOCS_FILE="${TARGET_DOCS_FILE:-$REPO_ROOT/docs/RoadmapBackend.md}"

failures=0

fail() {
  echo "  FAIL: $1"
  failures=$((failures + 1))
}

for f in "$SKILL_FILE" "$DOCS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "  FAIL: target file not found: $f"
    exit 1
  fi
done

# --- Helpers ---------------------------------------------------------------
# first_line_after FILE PATTERN AFTER -- line number of the first fixed-string
# match strictly after line AFTER; empty when absent.
first_line_after() {
  local file="$1" pattern="$2" after="$3"
  grep -Fn "$pattern" "$file" | awk -F: -v a="$after" '$1 > a {print $1; exit}'
}

# section_text FILE START END
section_text() {
  local file="$1" start="$2" end="$3"
  sed -n "${start},${end}p" "$file"
}

# section_from_heading FILE HEADING NEXT_HEADING_PREFIX
#   Text from HEADING up to just before the next line starting with
#   NEXT_HEADING_PREFIX, or EOF.
section_from_heading() {
  local file="$1" heading="$2" next_prefix="$3"
  local start end
  start="$(first_line_after "$file" "$heading" 0)"
  [ -n "$start" ] || return 1
  end="$(awk -v s="$start" -v p="$next_prefix" \
    'NR > s && index($0, p) == 1 { print NR - 1; exit }' "$file")"
  [ -n "$end" ] || end="$(wc -l < "$file" | tr -d ' ')"
  section_text "$file" "$start" "$end"
}

# ==========================================================================
# Part 1: docs/RoadmapBackend.md -- listTasks staleness option.
# ==========================================================================
listtasks_text="$(section_from_heading "$DOCS_FILE" '### `listTasks(bucket' '### ')" \
  || fail "could not find the listTasks section header in $DOCS_FILE"

if [ -n "${listtasks_text:-}" ]; then
  if ! printf '%s\n' "$listtasks_text" | grep -Fq 'maxStaleness'; then
    fail "listTasks does not document a maxStaleness option (cache service must be explicit at the call site)"
  fi
  # The load-bearing default: omitting the option must be authoritative, or
  # every pre-existing call site silently changes meaning.
  if ! printf '%s\n' "$listtasks_text" | grep -qi 'omitting it means authoritative\|omitted.*authoritative'; then
    fail "listTasks does not state that omitting maxStaleness is authoritative (pre-existing call sites must not change meaning)"
  fi
  if ! printf '%s\n' "$listtasks_text" | grep -Fq 'mirrorTTL'; then
    fail "listTasks does not reference mirrorTTL as the 'mirror' staleness budget"
  fi
  # The pagination mandate must survive: it governs the authoritative read.
  if ! printf '%s\n' "$listtasks_text" | grep -qi 'govern an authoritative read\|governs an authoritative read'; then
    fail "listTasks does not scope the pagination mandates to the authoritative read"
  fi
  if ! printf '%s\n' "$listtasks_text" | grep -qi 'never implicit\|explicit, never'; then
    fail "listTasks does not state that cache service is explicit and never implicit"
  fi
fi

# ==========================================================================
# Part 2: docs -- getTask is never served from a snapshot.
# ==========================================================================
gettask_text="$(section_from_heading "$DOCS_FILE" '### `getTask(id)`' '### ')" \
  || fail "could not find the getTask(id) section header in $DOCS_FILE"

if [ -n "${gettask_text:-}" ]; then
  if ! printf '%s\n' "$gettask_text" | grep -qi 'never served from a snapshot'; then
    fail "getTask(id) does not state that it is never served from a snapshot (this is the correctness guard for a cached listing)"
  fi
  if ! printf '%s\n' "$gettask_text" | grep -qi 'takes no .maxStaleness'; then
    fail "getTask(id) does not state that it takes no maxStaleness -- it must always be authoritative"
  fi
fi

# ==========================================================================
# Part 3: docs -- content identity fields, optional and omittable.
# ==========================================================================
for field in contentType issueNumber issueRepo; do
  if ! grep -Fq "$field" "$DOCS_FILE"; then
    fail "the task record does not carry '$field' (without it, a consumer must re-query every candidate by node id)"
  fi
done

identity_text="$(section_from_heading "$DOCS_FILE" '#### Content identity' '## ')" \
  || fail "could not find the 'Content identity' subsection in $DOCS_FILE"

if [ -n "${identity_text:-}" ]; then
  if ! printf '%s\n' "$identity_text" | grep -qi 'optional and omittable'; then
    fail "content identity fields are not declared optional and omittable (linear / github-issues must stay untouched)"
  fi
  if ! printf '%s\n' "$identity_text" | grep -qi 'tolerate their absence'; then
    fail "content identity does not require consumers to tolerate absent fields"
  fi
  if ! printf '%s\n' "$identity_text" | grep -qi 'not extra.*calls\|extra fields, not extra'; then
    fail "content identity does not state the fields cost no extra round-trip"
  fi
fi

# ==========================================================================
# Part 4: docs -- mirror TTL, write-through, and snapshot trust.
# ==========================================================================
mirror_text="$(section_from_heading "$DOCS_FILE" '## Offline mirror: freshness, snapshot layout, and cache service' '## ')" \
  || fail "could not find the offline-mirror freshness/cache section in $DOCS_FILE"

if [ -n "${mirror_text:-}" ]; then
  if ! printf '%s\n' "$mirror_text" | grep -Fq 'mirrorTTL'; then
    fail "the offline-mirror section does not define mirrorTTL"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -Fq '"1h"'; then
    fail "mirrorTTL does not document a 1h default"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -Fq 'fetchedAt'; then
    fail "the offline-mirror section does not define a fetchedAt stamp"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'ISO-8601'; then
    fail "fetchedAt is not specified as an ISO-8601 instant (staleness must be computed, not inferred from a date string)"
  fi
  # Write-through, and the reason it must not advance the stamp.
  if ! printf '%s\n' "$mirror_text" | grep -qi 'never read the board back'; then
    fail "write-through does not forbid reading the board back after a write"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'never advance .fetchedAt'; then
    fail "write-through does not forbid advancing fetchedAt on a write"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'full TTL'; then
    fail "the contract does not carry the REASON a write must not advance fetchedAt (it would extend every other record's staleness by a full TTL)"
  fi
  # Snapshot trust boundary.
  if ! printf '%s\n' "$mirror_text" | grep -Fq 'schemaVersion'; then
    fail "the snapshot has no schemaVersion (the reader's trust boundary)"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'untrusted input'; then
    fail "the snapshot directory is not declared untrusted input"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'cache miss'; then
    fail "an unvalidated / incomplete snapshot is not routed to a cache miss (discard and refetch)"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'complete'; then
    fail "the snapshot carries no completeness flag"
  fi
  # Dead columns.
  if ! printf '%s\n' "$mirror_text" | grep -qi 'always .null. is worse\|structurally always'; then
    fail "the snapshot schema does not forbid permanently-null columns"
  fi
  if ! printf '%s\n' "$mirror_text" | grep -qi 'provenance'; then
    fail "priority has no declared provenance in the snapshot schema"
  fi
  # One cache, not two.
  if ! printf '%s\n' "$mirror_text" | grep -qi 'not two caches'; then
    fail "the offline-mirror section does not state that the two faces are one cache, not two"
  fi
fi

# ==========================================================================
# Part 5: the retired cadences must be gone from both files.
# ==========================================================================
for f in "$DOCS_FILE" "$SKILL_FILE"; do
  if grep -Fq 'refreshes automatically every time the skill activates' "$f"; then
    fail "$(basename "$f") still claims the mirror refreshes every time the skill activates (retired by mirrorTTL)"
  fi
  if grep -Fq 'refreshed automatically on every skill activation' "$f"; then
    fail "$(basename "$f") still claims the mirror is refreshed on every skill activation (retired by mirrorTTL)"
  fi
done

# ==========================================================================
# Part 6: SKILL.md -- the activation-time TTL gate.
# ==========================================================================
gate_text="$(section_from_heading "$SKILL_FILE" '### Freshness gate (TTL)' '### ')" \
  || fail "could not find the 'Freshness gate (TTL)' subsection in $SKILL_FILE"

if [ -n "${gate_text:-}" ]; then
  if ! printf '%s\n' "$gate_text" | grep -Fq 'mirrorTTL'; then
    fail "the activation freshness gate does not consult mirrorTTL"
  fi
  # The whole point: a fresh snapshot means NO board read at all.
  if ! printf '%s\n' "$gate_text" | grep -qi 'no board read'; then
    fail "the freshness gate does not state that a fresh snapshot means no board read at all"
  fi
  if ! printf '%s\n' "$gate_text" | grep -qi 'calendar day\|calendar-day'; then
    fail "the freshness gate does not retire the once-per-calendar-day cadence"
  fi
fi

snapshot_text="$(section_from_heading "$SKILL_FILE" '### Snapshot index (the machine face)' '### ')" \
  || fail "could not find the 'Snapshot index' subsection in $SKILL_FILE"

if [ -n "${snapshot_text:-}" ]; then
  if ! printf '%s\n' "$snapshot_text" | grep -qi 'outside the repo'; then
    fail "the snapshot index is not documented as living outside the repo"
  fi
  if ! printf '%s\n' "$snapshot_text" | grep -qi 'rather than the repo\|board rather than'; then
    fail "the snapshot is not documented as keyed by the board rather than the repo"
  fi
  if ! printf '%s\n' "$snapshot_text" | grep -Fq 'schemaVersion'; then
    fail "the snapshot index subsection does not require a schemaVersion check before trusting a snapshot"
  fi
fi

# The refresh must write BOTH faces from one read.
if ! grep -qi 'both faces of the mirror from this one read' "$SKILL_FILE"; then
  fail "the refresh procedure does not write both mirror faces from a single read"
fi

if [ "$failures" -eq 0 ]; then
  echo "  ok: mirror TTL, explicit cache service, authoritative getTask, content-identity fields, write-through and snapshot-trust rules present across docs/RoadmapBackend.md and SKILL.md"
  exit 0
fi

exit 1
