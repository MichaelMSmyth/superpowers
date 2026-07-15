#!/usr/bin/env bash
# tools/ship.sh [--dry-run | --check-tree | --prune-check <cache_dir> <clone>] —
# one-command edit-test loop for the superpowers-extended-cc fork.
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
# F4 HARDENING (2026-07-15): the ship commit stages ONLY the manifest files this
#   script writes for the version bump (.claude-plugin/plugin.json and
#   .claude-plugin/marketplace.json), by explicit path — never a blanket `add -A`. Before
#   the bump, ship_tree_guard() REFUSES (fail-closed) if the working tree holds any
#   OTHER uncommitted/untracked change, so a stray/planted file can never ride the
#   ship commit out to public origin and into the installed plugin as executing code.
#   --check-tree is a test seam: it runs ONLY that guard against the git repo at CWD
#   and exits (no bump, no commit, no push, no install, no network) — it is exercised
#   by tools/tests/test_ship_tree_guard.sh and never used by a real ship.
#
# F0 HARDENING (2026-07-15): the plugin install is a FULL recursive copy of the clone's
#   working tree — it respects NO .gitignore/manifest exclusion (measured + doc-confirmed:
#   docs/findings/2026-07-15-plugin-install-copies-worktree.md, PROJECT repo one level up).
#   So after the SHA-parity verify, prune_cache_to_governed() removes every file in the
#   freshly-installed cache version dir whose cache-relative path is NOT in the shipped
#   governed tree (git ls-tree -r HEAD), leaving cache == git-tracked set exactly. It NEVER
#   removes a governed file and operates only within the resolved cache version dir.
#   --prune-check <cache_version_dir> <clone_root> is a test seam: it runs ONLY that prune
#   against throwaway dirs and exits (no bump/commit/push/install/network) — exercised by
#   tools/tests/test_ship_cache_prune.sh and never used by a real ship.
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

# --- clean-tree guard (F4) -------------------------------------------------
# The ONLY paths ship.sh itself writes for the version bump. Staging is by these
# explicit paths — never a blanket `add -A` — so a ship commit contains nothing but the
# bump even if the working tree has other uncommitted changes. Single source of
# truth for both the guard's allowlist and the staging step.
MANIFEST_RELPATHS=( ".claude-plugin/plugin.json" ".claude-plugin/marketplace.json" )

# ship_tree_guard <repo_root> — echo (to stdout), one per line, every uncommitted
# or untracked entry that is NOT a manifest file ship.sh is about to write. Return 0
# when the tree is clean enough to ship (empty, or ONLY manifests dirty); return 1
# when OTHER changes are present. Pure inspection: no writes, no network, no install.
ship_tree_guard() {
  local repo="$1" line path m allowed
  local -a offending=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"                       # porcelain: 2 status chars + 1 space, then path
    allowed=0
    for m in "${MANIFEST_RELPATHS[@]}"; do
      [ "$path" = "$m" ] && { allowed=1; break; }
    done
    [ "$allowed" -eq 1 ] || offending+=("$path")
  done < <(git -C "$repo" status --porcelain)
  if [ "${#offending[@]}" -gt 0 ]; then
    printf '%s\n' "${offending[@]}"
    return 1
  fi
  return 0
}

# ship_tree_refuse <offending-list> — print the F4 gate contract to stderr.
ship_tree_refuse() {
  local offending="$1"
  echo "ERROR: uncommitted changes present at ship time —" >&2
  printf '%s\n' "$offending" | sed 's/^/         /' >&2
  echo "  Correct form: commit or stash all intended changes before shipping;" >&2
  echo "                ship stages only the version bump." >&2
  echo "  Averted: an unreviewed dirty file pushed to public origin and installed as executing code." >&2
}

# --- installed-cache governed prune (F0) -----------------------------------
# prune_cache_to_governed <cache_version_dir> <clone_root> — remove every file under
# the freshly-installed cache version dir whose cache-relative path is NOT in the shipped
# governed set (git ls-tree -r HEAD of the clone), then drop now-empty directories, and
# echo a one-line summary "pruned N non-governed file(s) from the installed cache".
# The plugin install is a full recursive copy of the working tree (no ignore mechanism —
# see docs/findings/2026-07-15-plugin-install-copies-worktree.md), so this leaves the
# installed cache byte-equal to the git-tracked tree. SAFETY (all mandatory):
#   * NEVER removes a file whose relpath IS in the governed allowlist (checked per file);
#   * guards the target with ${TARGET:?} so an empty var can never rm outside it;
#   * operates ONLY within the resolved (absolute) cache version dir;
#   * empty/nonexistent target → no-op, rc 0, no error (never touches anything).
# Always returns 0 (a reporter, like the other organs); pure to its two path arguments.
prune_cache_to_governed() {
  local target="$1" clone="$2"
  if [ -z "$target" ] || [ ! -d "$target" ]; then
    echo "prune: no cache dir at '${target:-<empty>}' — nothing to prune (0 files)"
    return 0
  fi
  local TARGET; TARGET="$(cd "$target" && pwd)"    # resolve to an absolute path
  # governed allowlist: cache-relative paths of the shipped tree, as a set.
  local -A governed=()
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] && governed["$rel"]=1
  done < <(git -C "$clone" ls-tree -r HEAD --name-only)
  # SAFETY: an empty governed set (a git failure) would mark EVERY cache file as
  # non-governed and rm the whole cache. Refuse to prune against an empty allowlist.
  if [ "${#governed[@]}" -eq 0 ]; then
    echo "prune: governed set empty (git ls-tree returned nothing) — skipping prune (safety)" >&2
    return 0
  fi
  local pruned=0 f
  while IFS= read -r -d '' f; do
    rel="${f#"${TARGET}/"}"
    if [ -n "${governed[$rel]:-}" ]; then
      continue                                     # SAFETY: never remove a governed file
    fi
    rm -f -- "${TARGET:?}/$rel"
    pruned=$((pruned + 1))
  done < <(find "${TARGET:?}" -type f -print0)
  # drop now-empty directories (deepest first; never the target root itself).
  find "${TARGET:?}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  echo "pruned ${pruned} non-governed file(s) from the installed cache"
  return 0
}

# --- arg parse -------------------------------------------------------------
DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --check-tree)
    # F4 test seam: run ONLY the clean-tree guard against the git repo at CWD, then
    # exit — no bump, no commit, no push, no install, no network. Resolves its target
    # from CWD (not this script's path) so throwaway repos can be checked in tests.
    TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      echo "ERROR: --check-tree must be run inside a git repository." >&2
      echo "  Correct form: cd into the repo, then tools/ship.sh --check-tree." >&2
      exit 2
    }
    if OFFENDING="$(ship_tree_guard "$TARGET")"; then
      echo "CHECK-TREE: working tree clean enough to ship — would stage only: ${MANIFEST_RELPATHS[*]}"
      exit 0
    else
      ship_tree_refuse "$OFFENDING"
      exit 2
    fi
    ;;
  --prune-check)
    # F0 test seam: run ONLY prune_cache_to_governed against the given cache version
    # dir + clone root, then exit — no bump/commit/push/install/network. Exercised by
    # tools/tests/test_ship_cache_prune.sh; never used by a real ship.
    if [ "$#" -lt 3 ]; then
      echo "ERROR: --prune-check requires <cache_version_dir> <clone_root>." >&2
      echo "  Correct form: tools/ship.sh --prune-check <cache_version_dir> <clone_root>" >&2
      echo "  Averted: running the installed-cache prune with missing arguments." >&2
      exit 2
    fi
    prune_cache_to_governed "$2" "$3"
    exit 0
    ;;
  "")        ;;
  *)
    echo "ERROR: unknown argument '$1'." >&2
    echo "  Correct form: tools/ship.sh [--dry-run | --check-tree | --prune-check <cache_dir> <clone>]" >&2
    echo "  Averted: running an unrecognised flag as if it were a no-op." >&2
    exit 2
    ;;
esac

# --- step 2 (compute) ------------------------------------------------------
OLD_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_JSON")"
NEW_VER="$(next_mod_version "$OLD_VER")"

# --- step 1 (clean-tree gate, F4) ------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== ship.sh --dry-run (writes nothing, runs nothing) ==="
  if OFFENDING="$(ship_tree_guard "$REPO_ROOT")"; then
    echo "Step 1  working tree: clean enough to ship — a real ship would proceed."
    echo "        would stage only: ${MANIFEST_RELPATHS[*]}"
  else
    echo "Step 1  working tree: has changes OTHER than the version bump — a real ship would REFUSE:"
    printf '%s\n' "$OFFENDING" | sed 's/^/          - /'
    echo "        Correct form: commit or stash them first. Averted: pushing an unreviewed dirty file to public origin."
  fi
  echo "Step 2  version bump: ${OLD_VER} -> ${NEW_VER}"
  echo "        would write: ${PLUGIN_JSON#"$REPO_ROOT"/} .version"
  echo "        would write: ${MARKETPLACE_JSON#"$REPO_ROOT"/} plugins[name=${PLUGIN_NAME}].version (if present)"
  echo "=== end dry-run ==="
  exit 0
fi

# Fail-closed: refuse the ship if any change other than the manifest files is present.
if ! OFFENDING="$(ship_tree_guard "$REPO_ROOT")"; then
  ship_tree_refuse "$OFFENDING"
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
# Stage ONLY the manifest files the bump wrote (explicit paths, never a blanket `add -A`):
# even if the tree had other changes the guard missed, the ship commit is bump-only.
git -C "$REPO_ROOT" add -- "${MANIFEST_RELPATHS[@]}"
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

# --- step 5b (prune the freshly-installed cache to the governed set, F0) ----
# The install copied the WHOLE working tree; remove any file in the new version's
# cache dir that is not in the shipped tree, so cache == git-tracked set exactly.
CACHE_VERSION_DIR="$CACHE_PARENT/$NEW_VER"
PRUNE_LINE="$(prune_cache_to_governed "$CACHE_VERSION_DIR" "$REPO_ROOT")"
echo "Step 5b installed-cache prune: ${PRUNE_LINE}"

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
echo "  cache:      ${PRUNE_LINE}"
echo "  next step:  restart session to load ${NEW_VER}"
echo "===================="
