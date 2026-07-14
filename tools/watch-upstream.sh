#!/usr/bin/env bash
# tools/watch-upstream.sh — cron WATCHER for upstream drift (runs Mondays 09:17).
#
# CORE LAW: reports only. It NEVER merges, cherry-picks, or writes git history.
# It fetches, counts drift, and desktop-notifies ONLY when the upstream count has
# GROWN past the last count we already notified about (no repeat nagging).
#
# CRON-SAFE: any failure exits 0; all errors are swallowed to the log. A watcher
# that spins or errors loudly under cron is worse than a silent stale one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/upstream.sh
source "$SCRIPT_DIR/lib/upstream.sh"

STATE_DIR="$HOME/.cache/superpower-mod"
STATE_FILE="$STATE_DIR/watch-state"       # last NOTIFIED upstream count (single int)
LOG_FILE="$STATE_DIR/watch.log"           # one appended line per run
LATEST_FILE="$STATE_DIR/watch-latest.txt" # overwritten each run: human two-liner
UPSTREAM_MD="$REPO_ROOT/UPSTREAM.md"

# Everything runs inside main(); any early `return 0` still lands on `exit 0`.
main() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0

  # two SEPARATE remotes → --multiple (bare `fetch upstream obra` reads obra as a
  # ref on upstream and fails); spec intent "fetch upstream+obra" = both remotes.
  git -C "$REPO_ROOT" fetch --multiple upstream obra --quiet 2>>"$LOG_FILE" || true

  local sha
  sha="$(parse_last_synced "$UPSTREAM_MD" 2>>"$LOG_FILE")" || return 0

  local upstream_n obra_m
  upstream_n="$(git -C "$REPO_ROOT" rev-list --no-merges --count "${sha}..upstream/main" 2>>"$LOG_FILE")" || upstream_n=0
  obra_m="$(git -C "$REPO_ROOT" rev-list --count "upstream/main..obra/main" 2>>"$LOG_FILE")" || obra_m=0
  [[ "$upstream_n" =~ ^[0-9]+$ ]] || upstream_n=0
  [[ "$obra_m"     =~ ^[0-9]+$ ]] || obra_m=0

  local last_notified=0
  if [ -f "$STATE_FILE" ]; then
    last_notified="$(cat "$STATE_FILE" 2>/dev/null)"
    [[ "$last_notified" =~ ^[0-9]+$ ]] || last_notified=0
  fi

  local notified="no"
  if [ "$(should_notify "$upstream_n" "$last_notified")" = "yes" ]; then
    notify-send "Superpower Mod" \
      "upstream pcvelz +${upstream_n} since last sync (obra +${obra_m}). tools/sync-upstream.sh for the report." \
      2>>"$LOG_FILE" || true
    printf '%s\n' "$upstream_n" > "$STATE_FILE" 2>>"$LOG_FILE" || true
    notified="yes"
  fi

  local iso
  iso="$(date -Iseconds)"
  printf '%s upstream=%s obra=%s notified=%s\n' "$iso" "$upstream_n" "$obra_m" "$notified" >> "$LOG_FILE" 2>/dev/null || true
  {
    printf 'Superpower Mod upstream watch — %s\n' "$iso"
    printf 'upstream pcvelz +%s since last sync; obra +%s ahead of pcvelz (visibility only). notified=%s\n' \
      "$upstream_n" "$obra_m" "$notified"
  } > "$LATEST_FILE" 2>/dev/null || true
}

main
exit 0
