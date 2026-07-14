#!/usr/bin/env bash
# tools/lib/version.sh — pure version helpers for tools/ship.sh.
# No side effects: every function only reads its arguments and echoes.
# ship.sh sources this; tools/tests/test_version.sh pins the contract.

# next_mod_version <ver> — echo <ver> with its -mod.N suffix bumped, or -mod.1 appended.
#   6.0.5-dev         -> 6.0.5-dev-mod.1
#   6.0.5-dev-mod.3   -> 6.0.5-dev-mod.4
#   7.0.0             -> 7.0.0-mod.1
#   ...-mod.10        -> ...-mod.11
next_mod_version() {
  local ver="$1"
  if [[ "$ver" =~ ^(.*)-mod\.([0-9]+)$ ]]; then
    printf '%s-mod.%d\n' "${BASH_REMATCH[1]}" "$(( BASH_REMATCH[2] + 1 ))"
  else
    printf '%s-mod.1\n' "$ver"
  fi
}

# prune_candidates <current_ver> <dir>... — echo, one per line, each dir that is a
# mod dir (contains "-mod.") and is NOT the current version. Non-mod dirs (upstream
# versions like 5.2.8, 6.0.5-dev) are never echoed, so they are never pruned.
prune_candidates() {
  local current="$1"; shift
  local d
  for d in "$@"; do
    case "$d" in
      *-mod.*)
        if [ "$d" != "$current" ]; then
          printf '%s\n' "$d"
        fi
        ;;
    esac
  done
}
