#!/usr/bin/env bash
# tools/sync-upstream.sh [--record <sha>] — curated-sync RITUAL RUNNER.
#
# CORE LAW: upstream (pcvelz) is a CONTRIBUTOR, not an authority. obra is the
# original we merely watch. This tool REPORTS drift and RECORDS a completed sync.
# It NEVER merges, never cherry-picks, never writes to git history. Merging is a
# human review act — take / adapt / decline, one change at a time.
#
# Modes:
#   (default)          report mode — fetch upstream+obra, print the drift the human
#                      must review, then the canonical next-steps. Writes nothing.
#   --record <sha>     stamp UPSTREAM.md AFTER the human has merged & reviewed:
#                      rewrite the "**Fork point / last synced:**" line and append a
#                      sync-log row. Does NOT commit (the human reviews, then commits).
#
# Hidden flag (testing only, documented per plan): --file <path> overrides the
#   UPSTREAM.md path so --record can be exercised against a throwaway copy without
#   touching the live tracking file. Report mode ignores it in practice (no reason
#   to fetch against a fixture), but it is honoured for symmetry.
#
# Runnable from anywhere — repo root is resolved from this script's own path.
#
# GATE CONTRACT for every error path: (1) act only when safely inferable (or do
# nothing), (2) print the canonical correct form, (3) state what was averted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/upstream.sh
source "$SCRIPT_DIR/lib/upstream.sh"

UPSTREAM_MD="$REPO_ROOT/UPSTREAM.md"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

# --- arg parse -------------------------------------------------------------
MODE="report"
RECORD_SHA=""
FILE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --record)
      MODE="record"
      shift
      RECORD_SHA="${1:-}"
      [ $# -gt 0 ] && shift
      ;;
    --file)
      shift
      FILE_OVERRIDE="${1:-}"
      [ $# -gt 0 ] && shift
      ;;
    *)
      echo "ERROR: unknown argument '$1'." >&2
      echo "  Correct form: tools/sync-upstream.sh [--record <40-hex-sha>]" >&2
      echo "  Averted: running an unrecognised flag as if it were report mode." >&2
      exit 2
      ;;
  esac
done
[ -n "$FILE_OVERRIDE" ] && UPSTREAM_MD="$FILE_OVERRIDE"

# --- report mode -----------------------------------------------------------
report() {
  # NOTE: two SEPARATE remotes (upstream, obra) → --multiple. Bare `git fetch
  # upstream obra` would read `obra` as a ref ON upstream and fail; the spec's
  # "fetch upstream obra" intent is "fetch both remotes", which this satisfies.
  if ! git -C "$REPO_ROOT" fetch --multiple upstream obra --quiet 2>/dev/null; then
    echo "WARN: 'git fetch --multiple upstream obra' failed (offline?) — drift below is against cached refs." >&2
    echo "  Correct form once online: git -C \"$REPO_ROOT\" fetch --multiple upstream obra" >&2
    echo "  Averted: nothing halted; the counts may simply be stale." >&2
  fi

  local sha
  sha="$(parse_last_synced "$UPSTREAM_MD")" || exit $?
  local short="${sha:0:7}"

  local n
  n="$(git -C "$REPO_ROOT" rev-list --no-merges --count "${sha}..upstream/main" 2>/dev/null)"
  [ -n "$n" ] || n=0

  echo "=== Superpower Mod — upstream drift report ==="
  echo "Since last sync (${short}), upstream/main has ${n} new commit(s) (--no-merges)."
  echo ""
  echo "  git log --oneline --no-merges ${short}..upstream/main | head -50"
  git -C "$REPO_ROOT" log --oneline --no-merges "${sha}..upstream/main" | head -50
  echo ""
  echo "  git diff --stat ${short}..upstream/main | tail -15"
  git -C "$REPO_ROOT" diff --stat "${sha}..upstream/main" | tail -15
  echo ""

  local m
  m="$(git -C "$REPO_ROOT" rev-list --count "upstream/main..obra/main" 2>/dev/null)"
  [ -n "$m" ] || m=0
  echo "obra/main is ${m} commits ahead of upstream/main (visibility only)"
  echo ""

  # Canonical next-steps, printed VERBATIM (the $(...) is instruction, not evaluated).
  cat <<'EOF'
To sync: review the list above (take / adapt / decline per change; cross-check declines vs MODS.md), git merge upstream/main or cherry-pick, resolve conflicts as review prompts, then tools/sync-upstream.sh --record $(git rev-parse upstream/main) and tools/ship.sh.
EOF
}

# --- record mode -----------------------------------------------------------
record() {
  local newsha="$1"
  if ! [[ "$newsha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: --record needs a 40-hex commit sha, got '${newsha}'." >&2
    echo "  Canonical form: tools/sync-upstream.sh --record \$(git rev-parse upstream/main)" >&2
    echo "  Averted: stamping UPSTREAM.md with a bogus ref that would corrupt the next drift range." >&2
    exit 2
  fi

  local oldsha
  oldsha="$(parse_last_synced "$UPSTREAM_MD")" || exit $?

  local version today
  version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_JSON")"
  today="$(date +%F)"

  python3 - "$UPSTREAM_MD" "$newsha" "$version" "$today" "$oldsha" <<'PY'
import sys
path, newsha, version, today, oldsha = sys.argv[1:6]
marker = "**Fork point / last synced:**"
with open(path) as f:
    out = f.readlines()

# 1) rewrite the fork-point line
for i, line in enumerate(out):
    if line.startswith(marker):
        out[i] = f"{marker} {newsha} ({version}, {today})\n"
        break

# 2) append a sync-log row after the last contiguous table row of "## Sync log"
newrow = f"| {today} | {oldsha[:7]} → {newsha[:7]} | curated sync |\n"
in_log = False
last_row = None
for i, line in enumerate(out):
    if line.startswith("## Sync log"):
        in_log = True
        continue
    if in_log:
        if line.startswith("|"):
            last_row = i
        elif line.startswith("## "):
            break
if last_row is not None:
    out.insert(last_row + 1, newrow)
else:
    out.append(newrow)

with open(path, "w") as f:
    f.writelines(out)
PY

  echo "=== recorded sync ==="
  echo "  UPSTREAM.md (${UPSTREAM_MD#"$REPO_ROOT"/}) stamped: ${oldsha:0:7} -> ${newsha:0:7} (${version}, ${today})"
  echo "  sync-log row appended: | ${today} | ${oldsha:0:7} -> ${newsha:0:7} | curated sync |"
  echo "  NOT committed — review the diff, then commit with your sync rationale:"
  echo "    git -C \"$REPO_ROOT\" add UPSTREAM.md && git -C \"$REPO_ROOT\" commit -m 'sync: pcvelz <rationale>'"
}

# --- dispatch --------------------------------------------------------------
case "$MODE" in
  report) report ;;
  record) record "$RECORD_SHA" ;;
esac
