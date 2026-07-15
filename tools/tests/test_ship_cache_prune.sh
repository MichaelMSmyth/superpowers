#!/usr/bin/env bash
# tools/tests/test_ship_cache_prune.sh — contract tests for prune_cache_to_governed
# in tools/ship.sh (F0: keep the installed plugin cache == the git-tracked tree).
# Exercised ONLY via the `--prune-check <cache_version_dir> <clone_root>` test seam,
# which runs the prune against throwaway dirs and exits — NO bump/commit/push/install/
# network, NEVER a real ship. Builds a throwaway clone (git repo) + a throwaway fake
# cache dir per case in mktemp scratch; never touches the real clone or install cache.
# (Mirrors test_ship_tree_guard.sh / test_verify_cache_integrity.sh throwaway style.)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP="$SCRIPT_DIR/../ship.sh"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk()  { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi; }   # chk <name> <rc>

# A throwaway clone: tracked files under hooks/ + skills/ + a tracked tools/ file
# (so tools/ is a directory shared between a GOVERNED file and cruft). Echoes the dir.
mkclone() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name  test
  mkdir -p "$dir/hooks" "$dir/skills/using-superpowers" "$dir/tools"
  printf 'echo session-start\n'       > "$dir/hooks/session-start"
  printf '{"hooks":[]}\n'             > "$dir/hooks/hooks.json"
  printf '# using-superpowers body\n' > "$dir/skills/using-superpowers/SKILL.md"
  printf 'echo real tool\n'           > "$dir/tools/real-tool.sh"   # GOVERNED, in tools/
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  echo "$dir"
}

# A fake installed-cache version dir: (a) byte-copies of the governed files, plus
# (b) the cruft a full-worktree install would have swept in. Echoes the dir.
mkcache() { # mkcache <clone>
  local clone="$1" dir; dir="$(mktemp -d)"
  git -C "$clone" archive HEAD | tar -x -C "$dir"                  # (a) governed files
  mkdir -p "$dir/tools/.covenv" "$dir/hooks/__pycache__" "$dir/.claude" "$dir/.code-review-graph"
  printf 'venv junk\n'      > "$dir/tools/.covenv/x"               # (b) cruft
  printf '\x00bytecode\n'   > "$dir/hooks/__pycache__/y.pyc"
  printf 'local settings\n' > "$dir/.claude/settings.local.json"
  printf 'graph junk\n'     > "$dir/.code-review-graph/z"
  echo "$dir"
}

prune() { OUT="$("$SHIP" --prune-check "$1" "$2" 2>&1)"; RC=$?; }  # sets OUT, RC

# ==== Case 1: full prune — governed remain, cruft removed, empty dirs cleaned ====
CLONE="$(mkclone)"; CACHE="$(mkcache "$CLONE")"
prune "$CACHE" "$CLONE"
chk "seam exits 0" "$RC"

# governed files REMAIN (a governed file is NEVER removed)
[ -f "$CACHE/hooks/session-start" ];                       chk "governed hooks/session-start remains" $?
[ -f "$CACHE/hooks/hooks.json" ];                          chk "governed hooks/hooks.json remains" $?
[ -f "$CACHE/skills/using-superpowers/SKILL.md" ];         chk "governed SKILL.md remains" $?
[ -f "$CACHE/tools/real-tool.sh" ];                        chk "governed tools/real-tool.sh remains (dir shared with cruft)" $?

# every cruft file is REMOVED
[ ! -e "$CACHE/tools/.covenv/x" ];                         chk "cruft tools/.covenv/x removed" $?
[ ! -e "$CACHE/hooks/__pycache__/y.pyc" ];                 chk "cruft hooks/__pycache__/y.pyc removed" $?
[ ! -e "$CACHE/.claude/settings.local.json" ];             chk "cruft .claude/settings.local.json removed" $?
[ ! -e "$CACHE/.code-review-graph/z" ];                    chk "cruft .code-review-graph/z removed" $?

# now-empty directories cleaned; a dir still holding a governed file is retained
[ ! -d "$CACHE/tools/.covenv" ];                           chk "empty dir tools/.covenv cleaned" $?
[   -d "$CACHE/tools" ];                                   chk "tools/ retained (holds a governed file)" $?
[ ! -d "$CACHE/hooks/__pycache__" ];                       chk "empty dir hooks/__pycache__ cleaned" $?
[   -d "$CACHE/hooks" ];                                   chk "non-empty dir hooks/ retained" $?
[ ! -d "$CACHE/.claude" ];                                 chk "empty dir .claude cleaned" $?
[ ! -d "$CACHE/.code-review-graph" ];                      chk "empty dir .code-review-graph cleaned" $?

# the function REPORTS the count (exactly the 4 cruft files)
grep -qF "pruned 4 non-governed file(s) from the installed cache" <<<"$OUT"; chk "reports count (4)" $?

# the prune touched ONLY the cache — the clone worktree is untouched (never rm outside target)
[ -z "$(git -C "$CLONE" status --porcelain)" ];            chk "clone worktree untouched by prune" $?

# ==== Case 2 (guard): nonexistent target → no-op, rc 0, no error ====
CLONE2="$(mkclone)"
NOPE="$(mktemp -d)/does-not-exist"
prune "$NOPE" "$CLONE2"
chk "nonexistent target rc 0 (no-op)" "$RC"
grep -qF "nothing to prune" <<<"$OUT";                     chk "nonexistent target reports no-op" $?

# ==== Case 3 (guard): empty target dir → no-op, rc 0, dir untouched ====
EMPTY="$(mktemp -d)"
prune "$EMPTY" "$CLONE2"
chk "empty target rc 0 (no-op)" "$RC"
[ -d "$EMPTY" ];                                           chk "empty target dir untouched" $?

# ==== Case 4 (guard): a governed relpath shared with pruned siblings still survives ====
# A cache with ONLY a governed file (no cruft) must prune 0 and leave it intact.
CLONE3="$(mkclone)"; CLEAN_CACHE="$(mktemp -d)"
git -C "$CLONE3" archive HEAD | tar -x -C "$CLEAN_CACHE"
prune "$CLEAN_CACHE" "$CLONE3"
chk "already-clean cache rc 0" "$RC"
grep -qF "pruned 0 non-governed file(s)" <<<"$OUT";        chk "already-clean cache prunes 0" $?
[ -f "$CLEAN_CACHE/tools/real-tool.sh" ];                  chk "already-clean cache keeps every governed file" $?

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
