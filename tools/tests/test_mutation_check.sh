#!/usr/bin/env bash
# tools/tests/test_mutation_check.sh — B3 audit-tool contract tests.
# Fast asserts always; the real mutmut smoke only under RUN_MUTATION_SMOKE=1.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MC="$REPO_ROOT/tools/mutation-check.sh"
PASS=0; FAIL=0
t() { local d="$1" w="$2" g="$3" n="${4:-}" h="${5:-}"
  if [ "$w" = "$g" ] && { [ -z "$n" ] || grep -qF "$n" <<<"$h"; }; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $d (want rc=$w got rc=$g needle='$n')"; fi; }

# 1. syntax
bash -n "$MC"; t "bash -n clean" 0 $? "" ""

# 2. --help exits 0 and documents the safety invariant
out="$("$MC" --help 2>&1)"; rc=$?
t "--help exits 0" 0 "$rc" "scratch" "$out"

# 3. instructive refusal when python3.12 is absent (PATH stripped to a stub dir)
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
for c in bash cp mktemp grep sed awk dirname basename cat rm mkdir git timeout; do
  p="$(command -v "$c")" && ln -s "$p" "$STUB/$c"
done
out="$(PATH="$STUB" bash "$MC" 2>&1)"; rc=$?
t "missing python3.12 refused instructively" 2 "$rc" "python3.12" "$out"

# 4. live smoke (gated): synthetic weak module must yield survivors
if [ "${RUN_MUTATION_SMOKE:-0}" = "1" ]; then
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/tools/tests"
  cat > "$FIX/tools/mod_a.py" <<'EOF'
def add(a, b):
    return a + b
def clamp(x, lo, hi):
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x
EOF
  cat > "$FIX/tools/tests/test_mod_a.py" <<'EOF'
import importlib.util, os, unittest
spec = importlib.util.spec_from_file_location("mod_a", os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mod_a.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class T(unittest.TestCase):
    def test_weak(self):
        m.add(1, 2)          # calls but asserts nothing: mutants survive
        m.clamp(5, 0, 10)
if __name__ == "__main__":
    unittest.main()
EOF
  git -C "$FIX" init -q && git -C "$FIX" add -A && git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm fix
  out="$("$MC" --repo "$FIX" --modules "mod_a" 2>&1)"; rc=$?
  t "smoke exits 0" 0 "$rc" "mod_a" "$out"
  surv="$(grep -E '^ *mod_a' <<<"$out" | awk '{print $(NF-1)}')"
  [ "${surv:-0}" -ge 1 ]; t "smoke reports >=1 survivor" 0 $? "" ""
  # safety: the fixture working tree must be pristine afterwards
  [ -z "$(git -C "$FIX" status --porcelain)" ]; t "fixture tree untouched" 0 $? "" ""
  rm -rf "$FIX"
else
  echo "  (mutation smoke skipped — set RUN_MUTATION_SMOKE=1 to include it)"
fi

echo; if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS asserts)"; exit 0
else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
