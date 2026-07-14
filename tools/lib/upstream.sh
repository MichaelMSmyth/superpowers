#!/usr/bin/env bash
# tools/lib/upstream.sh — pure helpers for the curated-sync tools
# (sync-upstream.sh, watch-upstream.sh). No side effects: every function only
# reads its arguments / a file and echoes.
#
# NO `set -e` here — this lib is sourced by test harnesses and by watch-upstream.sh,
# both of which capture $? from a plain (non-subshell) call. parse_last_synced uses
# `return 3` on failure (never `exit`), so a sourced caller survives a missing sha.
#
# CORE LAW context: these helpers only REPORT/RECORD drift. Nothing here merges.

# parse_last_synced <path> — echo the 40-hex sha from the
#   "**Fork point / last synced:**" line of <path>.
# Missing marker line / no 40-hex sha on it → gate-contract message to stderr,
# return 3 (so the caller can abort a drift range against a garbage base ref).
parse_last_synced() {
  local path="$1"
  local line sha
  # Isolate the marker line by fixed string, THEN extract the sha, so a stray
  # 40-hex elsewhere in the file cannot masquerade as the sync point.
  line="$(grep -F '**Fork point / last synced:**' "$path" 2>/dev/null | head -1)"
  sha="$(printf '%s\n' "$line" | grep -oE '[0-9a-f]{40}' | head -1)"
  if [ -z "$sha" ]; then
    echo "parse_last_synced: no 40-hex sha on a '**Fork point / last synced:**' line in ${path}" >&2
    echo "  Canonical form: '**Fork point / last synced:** <40-hex-sha> (<version>, <YYYY-MM-DD>)'" >&2
    echo "  Averted: computing a drift range against an empty/garbage base ref." >&2
    return 3
  fi
  printf '%s\n' "$sha"
}

# should_notify <current_count> <last_notified_count> — echo "yes" iff
#   current > last_notified AND current > 0, else "no".
# Suppresses both the no-change case and the zero-drift case (nothing to sync).
should_notify() {
  local cur="$1" last="$2"
  if [ "$cur" -gt "$last" ] && [ "$cur" -gt 0 ]; then
    echo "yes"
  else
    echo "no"
  fi
}
