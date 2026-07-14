#!/usr/bin/env bash
# tools/tests/test_plan_lint.sh — property-shaped presence check tests.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PL="$REPO_ROOT/tools/plan-lint.sh"
PASS=0; FAIL=0
t() { local d="$1" w="$2" g="$3" n="${4:-}" h="${5:-}"
  if [ "$w" = "$g" ] && { [ -z "$n" ] || grep -qF "$n" <<<"$h"; }; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $d (want rc=$w got rc=$g needle='$n')"; fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/good.md" <<'EOF'
# Plan
### Task 1: A
**Property-shaped:** yes — associativity over random inputs
### Task 2: B
**Property-shaped:** no — enumerable cases
EOF
out="$("$PL" "$TMP/good.md" 2>&1)"; rc=$?
t "good plan OK rc 0" 0 "$rc" "PLAN LINT OK (2 tasks)" "$out"

cat > "$TMP/bad.md" <<'EOF'
# Plan
### Task 1: A
**Property-shaped:** yes — something
### Task 2: B
no marker in this block
EOF
out="$("$PL" "$TMP/bad.md" 2>&1)"; rc=$?
t "soft mode warns, rc 0" 0 "$rc" "WARN" "$out"
t "offending task named" 0 "$rc" "Task 2" "$out"
out="$("$PL" --check "$TMP/bad.md" 2>&1)"; rc=$?
t "--check exits 1" 1 "$rc" "" ""

out="$("$PL" "$TMP/absent.md" 2>&1)"; rc=$?
t "missing file exits 2" 2 "$rc" "" ""

cat > "$TMP/notasks.md" <<'EOF'
# A doc without task headings
EOF
out="$("$PL" "$TMP/notasks.md" 2>&1)"; rc=$?
t "no-task doc passes vacuously" 0 "$rc" "PLAN LINT OK (0 tasks)" "$out"

echo; if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS asserts)"; exit 0
else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
