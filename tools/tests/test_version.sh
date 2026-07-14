#!/usr/bin/env bash
# Tests for tools/lib/version.sh — run: bash tools/tests/test_version.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
source tools/lib/version.sh
fails=0
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fails=$((fails+1)); fi
}
assert_eq "first bump"        "6.0.5-dev-mod.1" "$(next_mod_version '6.0.5-dev')"
assert_eq "increment"         "6.0.5-dev-mod.4" "$(next_mod_version '6.0.5-dev-mod.3')"
assert_eq "plain semver"      "7.0.0-mod.1"     "$(next_mod_version '7.0.0')"
assert_eq "double digits"     "6.0.5-dev-mod.11" "$(next_mod_version '6.0.5-dev-mod.10')"
assert_eq "prune picks stale mod dirs only" "6.0.5-dev-mod.3" \
  "$(prune_candidates '6.0.5-dev-mod.4' '5.2.8' '6.0.5-dev' '6.0.5-dev-mod.3' '6.0.5-dev-mod.4')"
assert_eq "prune keeps current, no stale"   "" \
  "$(prune_candidates '6.0.5-dev-mod.1' '5.2.8' '6.0.5-dev-mod.1')"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILURES"; exit 1; }
