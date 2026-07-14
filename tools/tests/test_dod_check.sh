#!/usr/bin/env bash
# tools/tests/test_dod_check.sh — B2 dod-check.sh contract tests. No network.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOD="$REPO_ROOT/tools/dod-check.sh"
PASS=0; FAIL=0
t() { # t <desc> <expected_rc> <actual_rc> [<needle> <haystack>]
  local desc="$1" want="$2" got="$3" needle="${4:-}" hay="${5:-}"
  if [ "$want" = "$got" ] && { [ -z "$needle" ] || grep -qF "$needle" <<<"$hay"; }; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: $desc (want rc=$want got rc=$got needle='$needle')"
  fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1. green config: all lines runnable and passing
printf '# comment\n\ntrue\necho ok\n' > "$TMP/green.config"
out="$("$DOD" --config "$TMP/green.config" 2>&1)"; rc=$?
t "green config exits 0" 0 "$rc" "DOD: 2/2 checks green" "$out"

# 2. failing line: honest exit 1, names the line
printf 'true\nfalse\n' > "$TMP/red.config"
out="$("$DOD" --config "$TMP/red.config" 2>&1)"; rc=$?
t "failing line exits 1" 1 "$rc" "FAIL" "$out"
t "failing line is named" 1 "$rc" "false" "$out"

# 3. prose line: refused BEFORE anything runs (gate contract, exit 2)
# DEVIATION (pre-authorized): first token changed from 'code' to
# 'qwzxy_definitely_not_a_command' because `command -v code` resolves on this
# box (/snap/bin/code). With 'code' the pinned line would EXECUTE, not refuse.
# Semantics preserved: first token resolves neither via command -v nor as a file.
printf 'qwzxy_definitely_not_a_command is clean and good\ntouch "%s/marker"\n' "$TMP" > "$TMP/vague.config"
out="$("$DOD" --config "$TMP/vague.config" 2>&1)"; rc=$?
t "prose criterion refused with exit 2" 2 "$rc" "runnable command" "$out"
t "gate contract states averted failure" 2 "$rc" "Averted" "$out"
[ ! -e "$TMP/marker" ]; t "nothing executed after refusal" 0 $? "" ""

# 4. missing config
out="$("$DOD" --config "$TMP/nope.config" 2>&1)"; rc=$?
t "missing config exits 2" 2 "$rc" "" ""

# 5. kill switch
out="$(SUPERPOWERS_DOD_GUARD=0 "$DOD" --config "$TMP/red.config" 2>&1)"; rc=$?
t "kill switch exits 0 on red config" 0 "$rc" "skip" "$out"

echo; if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS asserts)"; exit 0
else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
