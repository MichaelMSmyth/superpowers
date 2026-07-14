#!/usr/bin/env bash
# tools/ship.sh [--dry-run] — one-command edit-test loop for the superpowers-extended-cc fork.
#
# Bumps the plugin's -mod.N version, commits + pushes, re-reads the local directory
# marketplace, re-installs the plugin, verifies the installed gitCommitSha == HEAD,
# and prunes stale -mod.* cache dirs. Runnable from anywhere — repo root is resolved
# from this script's own path.
#
# CANARY FACTS (empirical, 2026-07-14), encoded below:
#   (1) same-version cache pickup FAILS — every shipped change needs a version bump.
#   (2) plugin update/install need the FULLY-QUALIFIED name
#       superpowers-extended-cc@superpowers-extended-cc-marketplace (unqualified fails).
#   (3) stale -mod.* cache dirs accumulate and must be pruned (never touch upstream
#       non-mod dirs like 5.2.8 / 6.0.5-dev).
#
# GATE CONTRACT for every error path: on failure (1) do what's safely inferable or
# nothing, (2) print the canonical correct command/form, (3) state what was averted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
PLUGIN_NAME="superpowers-extended-cc"
MARKETPLACE_NAME="superpowers-extended-cc-marketplace"
QUALIFIED="${PLUGIN_NAME}@${MARKETPLACE_NAME}"
INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"
CACHE_PARENT="$HOME/.claude/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_NAME}"

# --- arg parse -------------------------------------------------------------
DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "")        ;;
  *)
    echo "ERROR: unknown argument '$1'." >&2
    echo "  Correct form: tools/ship.sh [--dry-run]" >&2
    echo "  Averted: running an unrecognised flag as if it were a no-op." >&2
    exit 2
    ;;
esac

# --- step 2 (compute) ------------------------------------------------------
OLD_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_JSON")"
NEW_VER="$(next_mod_version "$OLD_VER")"

# --- step 1 (clean-tree gate) ----------------------------------------------
STATUS="$(git -C "$REPO_ROOT" status --porcelain)"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== ship.sh --dry-run (writes nothing, runs nothing) ==="
  if [ -z "$STATUS" ]; then
    echo "Step 1  working tree: CLEAN — a real ship would proceed."
  else
    echo "Step 1  working tree: DIRTY ($(printf '%s\n' "$STATUS" | wc -l) entr(y/ies)) — a real ship would ABORT."
    echo "        Correct form: commit first, then ship. Averted: installing untested state."
  fi
  echo "Step 2  version bump: ${OLD_VER} -> ${NEW_VER}"
  echo "        would write: ${PLUGIN_JSON#"$REPO_ROOT"/} .version"
  echo "        would write: ${MARKETPLACE_JSON#"$REPO_ROOT"/} plugins[name=${PLUGIN_NAME}].version (if present)"
  echo "=== end dry-run ==="
  exit 0
fi

if [ -n "$STATUS" ]; then
  echo "ERROR: working tree not clean — refusing to ship." >&2
  echo "  Correct form: commit first, then ship:" >&2
  echo "    git -C \"$REPO_ROOT\" add -A && git -C \"$REPO_ROOT\" commit -m '<msg>'" >&2
  echo "    tools/ship.sh" >&2
  echo "  Averted: shipping uncommitted work would install untested state." >&2
  exit 2
fi

echo "=== ship.sh: ${OLD_VER} -> ${NEW_VER} ==="

# --- step 2 (write) --------------------------------------------------------
python3 - "$PLUGIN_JSON" "$NEW_VER" <<'PY'
import json, sys
path, newver = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["version"] = newver
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

MKT_RESULT="$(python3 - "$MARKETPLACE_JSON" "$NEW_VER" "$PLUGIN_NAME" <<'PY'
import json, sys
path, newver, pname = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    d = json.load(f)
touched = []
for p in d.get("plugins", []):
    if p.get("name") == pname and "version" in p:
        p["version"] = newver
        touched.append("plugins[name=%s].version" % pname)
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(",".join(touched) if touched else "none (no per-plugin version field)")
PY
)"
echo "Step 2  plugin.json.version <- ${NEW_VER}; marketplace.json ${MKT_RESULT}"

# --- step 3 (commit + push) ------------------------------------------------
git -C "$REPO_ROOT" add -A
git -C "$REPO_ROOT" commit -m "chore: ship ${NEW_VER}" >/dev/null
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
echo "Step 3  committed 'chore: ship ${NEW_VER}' @ ${HEAD_SHA}"

if git -C "$REPO_ROOT" push origin main >/dev/null 2>&1; then
  echo "Step 3  pushed origin main"
else
  echo "WARN: 'git push origin main' failed — the LOCAL directory still drives this"
  echo "      install (marketplace source type = directory), so the ship continues."
  echo "  Correct form once connectivity returns: git -C \"$REPO_ROOT\" push origin main"
  echo "  Averted: aborting a working local install over a remote-sync hiccup."
fi

# --- step 4 (marketplace update + plugin update) ---------------------------
# Canary (2): the plugin update needs the FULLY-QUALIFIED name.
echo "Step 4  claude plugin marketplace update ${MARKETPLACE_NAME}"
claude plugin marketplace update "${MARKETPLACE_NAME}" 2>&1 | sed 's/^/        | /' || true
echo "Step 4  claude plugin update ${QUALIFIED}"
claude plugin update "${QUALIFIED}" 2>&1 | sed 's/^/        | /' || true

# --- step 5 (verify installed sha == HEAD) ---------------------------------
INSTALLED_SHA="$(python3 - "$INSTALLED_JSON" "$QUALIFIED" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
for e in d.get("plugins", {}).get(key, []):
    sha = e.get("gitCommitSha")
    if sha:
        print(sha)
        break
else:
    print("")
PY
)"

if [ "$INSTALLED_SHA" != "$HEAD_SHA" ]; then
  echo "ERROR: installed gitCommitSha does not match HEAD after update." >&2
  echo "  HEAD:      $HEAD_SHA" >&2
  echo "  installed: ${INSTALLED_SHA:-<none>}" >&2
  echo "  Correct form — re-run the update pair with the FULLY-QUALIFIED name:" >&2
  echo "    claude plugin marketplace update ${MARKETPLACE_NAME}" >&2
  echo "    claude plugin update ${QUALIFIED}" >&2
  echo "  Averted: reporting a ship as landed while the session would load stale code." >&2
  exit 1
fi
echo "Step 5  installed gitCommitSha == HEAD (${HEAD_SHA})  ✓"

# --- step 6 (prune stale mod cache dirs) -----------------------------------
DIRS=()
if [ -d "$CACHE_PARENT" ]; then
  for d in "$CACHE_PARENT"/*/; do
    [ -d "$d" ] || continue
    DIRS+=("$(basename "$d")")
  done
fi

PRUNED=()
if [ "${#DIRS[@]}" -gt 0 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    rm -rf -- "${CACHE_PARENT:?}/${name}"
    PRUNED+=("$name")
  done < <(prune_candidates "$NEW_VER" "${DIRS[@]}")
fi

if [ "${#PRUNED[@]}" -gt 0 ]; then
  echo "Step 6  pruned stale mod cache dir(s): ${PRUNED[*]}"
else
  echo "Step 6  no stale mod cache dirs to prune"
fi

# --- step 7 (receipt) ------------------------------------------------------
echo ""
echo "=== SHIP RECEIPT ==="
echo "  version:    ${OLD_VER} -> ${NEW_VER}"
echo "  HEAD sha:   ${HEAD_SHA}"
echo "  installed:  ${INSTALLED_SHA} (== HEAD)"
if [ "${#PRUNED[@]}" -gt 0 ]; then
  echo "  pruned:     ${PRUNED[*]}"
else
  echo "  pruned:     (none)"
fi
echo "  next step:  restart session to load ${NEW_VER}"
echo "===================="
