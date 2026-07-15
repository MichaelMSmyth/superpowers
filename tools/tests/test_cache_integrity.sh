#!/usr/bin/env bash
# tools/tests/test_cache_integrity.sh — contract tests for hooks/cache-integrity-check (F0).
#
# The real cache/clone layout is hard to fixture, so the comparison logic reads
# its two surfaces from env overrides (CACHE_HOOKS_DIR / CLONE_DIR) — a test seam
# only; the production auto-locate path is untouched. Each case builds a throwaway
# git clone (hooks/ committed at HEAD) and a throwaway cache hooks dir, then
# asserts the advisory is emitted iff they diverge, always exits 0, and any
# emitted advisory is valid JSON naming the diverged file. Mirrors
# tools/tests/test_tier_scan.sh style.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO/hooks/cache-integrity-check"
PASS=0; FAIL=0

# mkclone <name=content ...> -> prints a git-repo dir whose hooks/ holds the
# named files, committed at HEAD.
mkclone() {
  local dir kv; dir="$(mktemp -d)"
  git -C "$dir" init -q >/dev/null 2>&1
  git -C "$dir" config user.email t@t >/dev/null 2>&1
  git -C "$dir" config user.name t >/dev/null 2>&1
  mkdir -p "$dir/hooks"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$dir/hooks/${kv%%=*}"; done
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -q -m base >/dev/null 2>&1
  printf '%s' "$dir"
}

# mkcache <name=content ...> -> prints a plain dir holding the named files
# (stands in for the running cache's hooks/ directory).
mkcache() {
  local dir kv; dir="$(mktemp -d)"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$dir/${kv%%=*}"; done
  printf '%s' "$dir"
}

run_hook() { # run_hook <cache_hooks_dir> <clone_dir>
  # CLAUDE_PLUGIN_ROOT points nowhere real: with both overrides set, auto-locate
  # is never reached, so a test can never accidentally hit the machine's clone.
  env CACHE_HOOKS_DIR="$1" CLONE_DIR="$2" CLAUDE_PLUGIN_ROOT="/nonexistent" bash "$HOOK"
}

# tcase <name> <silent|advisory> <cache_dir> <clone_dir> [must_contain]
tcase() {
  local name="$1" expect="$2" cache="$3" clone="$4" must="${5:-}"
  local out rc ok=1 msg=""
  out="$(run_hook "$cache" "$clone")"; rc=$?
  [ "$rc" -eq 0 ] || { ok=0; msg="$msg [rc=$rc want 0]"; }
  if [ "$expect" = silent ]; then
    [ -z "$out" ] || { ok=0; msg="$msg [expected no output, got: ${out:0:80}]"; }
  else
    [ -n "$out" ] || { ok=0; msg="$msg [expected advisory, got none]"; }
    printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 || { ok=0; msg="$msg [invalid JSON]"; }
    [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must" || { ok=0; msg="$msg [missing '$must']"; }
  fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name$msg"; fi
}

CLONE="$(mkclone session-start=AAA claims_evidence.py=BBB run-hook.cmd=CCC)"

# 1. Matching cache: byte-identical to governed HEAD -> silent, exit 0.
CACHE_OK="$(mkcache session-start=AAA claims_evidence.py=BBB run-hook.cmd=CCC)"
tcase "matching-silent" silent "$CACHE_OK" "$CLONE"

# 2. Tampered cache: one hook file's bytes changed -> advisory names it, exit 0,
#    valid JSON.
CACHE_TAMPER="$(mkcache session-start=AAA claims_evidence.py=TAMPERED run-hook.cmd=CCC)"
tcase "tampered-advisory" advisory "$CACHE_TAMPER" "$CLONE" "claims_evidence.py"

# 3. Missing / non-git clone: cannot establish truth -> silent, exit 0 (fail open).
tcase "missing-clone-silent" silent "$CACHE_OK" "/nonexistent/no/such/repo"

# 4. Injected cache file with no governed counterpart -> advisory names it.
CACHE_ADD="$(mkcache session-start=AAA claims_evidence.py=BBB run-hook.cmd=CCC evil-hook=PWN)"
tcase "added-in-cache-advisory" advisory "$CACHE_ADD" "$CLONE" "evil-hook"

# 5. Governed file removed from the cache -> advisory names it.
CACHE_DEL="$(mkcache session-start=AAA run-hook.cmd=CCC)"
tcase "missing-from-cache-advisory" advisory "$CACHE_DEL" "$CLONE" "claims_evidence.py"

# 6. Advisory carries the gate contract (Averted line) and the RUNNING-differs framing.
CACHE_TAMPER2="$(mkcache session-start=XXX claims_evidence.py=BBB run-hook.cmd=CCC)"
tcase "advisory-carries-averted" advisory "$CACHE_TAMPER2" "$CLONE" "Averted"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
