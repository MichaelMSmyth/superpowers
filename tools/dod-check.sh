#!/usr/bin/env bash
# tools/dod-check.sh — B2 organ: the definition-of-done runner for this fork.
#
# Reads dod.config (repo root by default) and executes its ordered, machine-
# runnable checks — one command per line, in order, from the repo root. It
# REFUSES prose criteria: before running anything it validates that every
# line's first token is an actual runnable command (on PATH or an existing
# file), so a vague "code is clean and good" cannot be talked past — it is
# rejected with the gate contract instead of silently skipped.
#
# HONEST EXIT SEMANTICS — this tool only tells the truth; it never decides fate:
#   0  all checks green   (or the kill switch is engaged)
#   1  at least one check red (every check still runs; failures are reported)
#   2  config invalid — missing/unreadable file, or a non-runnable (prose) line
#
# Enforcement posture is the CALLER's business, per the enforcement ladder:
# whether a red DoD blocks a commit (hard gate) or merely warns (advisory) is
# decided by whoever invokes this — dod-check.sh just reports the state of play.
#
# Kill switch: SUPERPOWERS_DOD_GUARD=0 → print one skip line and exit 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- kill switch (first, before any work) ----------------------------------
if [ "${SUPERPOWERS_DOD_GUARD:-1}" = "0" ]; then
  echo "dod-check: SUPERPOWERS_DOD_GUARD=0 — skipping definition-of-done checks."
  exit 0
fi

# --- arg parse -------------------------------------------------------------
CONFIG="$REPO_ROOT/dod.config"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG="${2:-}"; shift 2 ;;
    --config=*)
      CONFIG="${1#--config=}"; shift ;;
    *)
      echo "ERROR: unknown argument '$1'." >&2
      echo "  Correct form: tools/dod-check.sh [--config <path>]" >&2
      echo "  Averted: running an unrecognised flag as if it were a no-op." >&2
      exit 2 ;;
  esac
done

# --- config present & readable ---------------------------------------------
if [ ! -r "$CONFIG" ]; then
  echo "ERROR: dod.config not found or unreadable: $CONFIG" >&2
  echo "  Correct form: point --config at a readable dod.config (one runnable command per line)." >&2
  echo "  Averted: reporting a definition of done as met while never reading its checks." >&2
  exit 2
fi

# --- collect non-comment, non-blank lines ----------------------------------
CHECKS=()
while IFS= read -r line || [ -n "$line" ]; do
  # skip blank lines and full-line comments (leading whitespace tolerated)
  trimmed="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
  [ -z "$trimmed" ] && continue                # blank
  [ "${trimmed:0:1}" = "#" ] && continue       # comment
  CHECKS+=("$trimmed")
done < "$CONFIG"

# --- PASS 1: validate ALL lines are runnable BEFORE executing ANY ----------
OFFENDERS=()
for line in "${CHECKS[@]}"; do
  read -r tok _ <<<"$line"
  if command -v "$tok" >/dev/null 2>&1; then continue; fi
  if [ -e "$REPO_ROOT/$tok" ]; then continue; fi
  if [ -e "$tok" ]; then continue; fi
  OFFENDERS+=("$line")
done

if [ "${#OFFENDERS[@]}" -gt 0 ]; then
  echo "ERROR: dod.config contains lines that are not runnable commands — refusing to run anything." >&2
  for line in "${OFFENDERS[@]}"; do
    echo "  offending line: $line" >&2
  done
  echo "  Canonical form: every dod.config line must be a runnable command (first token on PATH or an existing file)." >&2
  echo "  Averted: a vague criterion that can be talked past instead of run." >&2
  exit 2
fi

# --- PASS 2: execute each check from the repo root -------------------------
N="${#CHECKS[@]}"
GREEN=0
RED=0
for line in "${CHECKS[@]}"; do
  outfile="$(mktemp)"
  ( cd "$REPO_ROOT" && timeout 600 bash -c "$line" ) >"$outfile" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    GREEN=$((GREEN+1))
    echo "PASS: $line"
  else
    RED=$((RED+1))
    echo "FAIL: $line (rc=$rc)"
    tail -n 5 "$outfile" | sed 's/^/    /'
  fi
  rm -f "$outfile"
done

# --- summary ---------------------------------------------------------------
if [ "$RED" -eq 0 ]; then
  echo "DOD: $GREEN/$N checks green"
  exit 0
else
  echo "DOD: $GREEN/$N checks green, $RED failed"
  exit 1
fi
