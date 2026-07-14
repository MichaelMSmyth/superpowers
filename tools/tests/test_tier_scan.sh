#!/usr/bin/env bash
# tools/tests/test_tier_scan.sh — contract tests for tools/tier-scan.sh (C1 rung 3).
# Builds a throwaway git repo per case; never touches the real repo.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER_SCAN="$SCRIPT_DIR/../tier-scan.sh"
PASS=0; FAIL=0

t() { # t <name> <expected_rc> <stderr_must_contain|-> <stderr_must_not_contain|-> <cmd...>
  local name="$1" want_rc="$2" must="$3" mustnot="$4"; shift 4
  local errfile; errfile="$(mktemp)"
  "$@" >/dev/null 2>"$errfile"; local rc=$?
  local ok=1
  [ "$rc" -eq "$want_rc" ] || ok=0
  if [ "$must" != "-" ] && ! grep -q "$must" "$errfile"; then ok=0; fi
  if [ "$mustnot" != "-" ] && grep -q "$mustnot" "$errfile"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS: $name"; else
    FAIL=$((FAIL+1)); echo "FAIL: $name (rc=$rc want=$want_rc)"; sed 's/^/    /' "$errfile"; fi
  rm -f "$errfile"
}

mkrepo() { # mkrepo <n_files> <lines_per_file> -> prints repo dir; leaves diff uncommitted
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  ( cd "$dir" && git commit -q --allow-empty -m base )
  local i
  for i in $(seq 1 "$1"); do
    seq 1 "$2" | sed 's/^/line /' > "$dir/f$i.txt"
  done
  echo "$dir"
}

# 1. T0 under budget (1 file, 10 lines): silent, rc 0
R="$(mkrepo 1 10)"
t "t0-under-budget-silent" 0 - "TIER-SCAN" \
  env -C "$R" "$TIER_SCAN" --tier T0
# 2. T0 over budget (3 files, 60 lines total): WARN to stderr, rc 0 (soft gate)
R="$(mkrepo 3 20)"
t "t0-over-budget-warns-rc0" 0 "TIER-SCAN" "-" \
  env -C "$R" "$TIER_SCAN" --tier T0
# 3. Same but --check: rc 1
R="$(mkrepo 3 20)"
t "t0-over-budget-check-rc1" 1 "TIER-SCAN" - \
  env -C "$R" "$TIER_SCAN" --tier T0 --check
# 4. WARN carries the gate contract (Averted line)
R="$(mkrepo 3 20)"
t "warn-carries-averted" 0 "Averted" - \
  env -C "$R" "$TIER_SCAN" --tier T0
# 5. T2 never warns (10 files, 500 lines)
R="$(mkrepo 10 50)"
t "t2-unlimited-silent" 0 - "TIER-SCAN" \
  env -C "$R" "$TIER_SCAN" --tier T2
# 6. Invalid tier: rc 2, instructive
R="$(mkrepo 1 1)"
t "bad-tier-rc2" 2 "Correct form" - \
  env -C "$R" "$TIER_SCAN" --tier T9
# 7. Missing --tier: rc 2
R="$(mkrepo 1 1)"
t "missing-tier-rc2" 2 "Correct form" - \
  env -C "$R" "$TIER_SCAN"
# 8. Kill switch: over-budget diff, but silent rc 0
R="$(mkrepo 3 20)"
t "kill-switch-silences" 0 - "TIER-SCAN" \
  env -C "$R" SUPERPOWERS_TIER_GUARD=0 "$TIER_SCAN" --tier T0
# 9. Not a git repo: rc 2
D="$(mktemp -d)"
t "not-a-repo-rc2" 2 "git" - \
  env -C "$D" "$TIER_SCAN" --tier T0
# 10. --range mode: committed over-budget range warns
R="$(mkrepo 3 20)"
( cd "$R" && git add . && git commit -q -m big )
t "range-mode-warns" 0 "TIER-SCAN" - \
  env -C "$R" "$TIER_SCAN" --tier T0 --range HEAD~1..HEAD

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
