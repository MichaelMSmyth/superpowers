#!/usr/bin/env bash
# tools/tier-scan.sh — C1 rung-3 soft gate: completion-time tier re-scan.
#
# Re-checks a task's DECLARED tier (T0/T1/T2) against the ACTUAL diff at task
# end. A tier sizes ceremony (spread width, review weight, ratification); if the
# finished diff outgrew the declared tier's budget, the tier was mis-declared at
# intake — this tool says so in the gate-contract voice and points at the missed
# signal. It is a SOFT gate: it WARNS, it never blocks (exit 0 even over budget),
# unless --check is passed for a CI/worker caller that wants a non-zero signal.
#
# UNTRACKED-FILES COUNTING CHOICE (deliberate). A completion re-scan must see
# work that is written but not yet staged, so `git diff HEAD --numstat` — which
# is blind to untracked files — is not enough on its own in the default mode. So
# default mode ADDS every untracked, non-ignored file (`git ls-files --others
# --exclude-standard`): each counts as 1 file, and its full line count is charged
# as added lines. Without this, a T0 task that creates three brand-new unstaged
# files would scan as a clean 0-file diff and the gate would miss exactly the
# over-scope it exists to catch. In --range mode we trust the named commit range
# verbatim (`git diff <range> --numstat`) and do NOT add untracked files — a
# range is an explicit, already-committed slice.
#
# BUDGETS (ASSUMED — calibrated from Phase 0–2 task diffs, 2026-07-14; starting
# values, not laws). T0 <=2 files AND <=40 changed lines; T1 <=6 files AND <=300
# lines; T2 unlimited. Changed lines = insertions + deletions summed. Exceeding
# EITHER limit is over budget. Flip condition: two mis-sized warnings in one week
# => recalibrate the thresholds.
#
# HONEST EXIT SEMANTICS:
#   0  under budget, OR over budget in soft mode (WARN emitted — never blocks),
#      OR kill switch engaged, OR tier T2 (unlimited)
#   1  --check mode AND the diff is over the declared tier's budget
#   2  usage error — missing/invalid --tier, unknown flag, or not a git repo
#
# Kill switch: SUPERPOWERS_TIER_GUARD=0 => one skip line to stdout, exit 0,
# before any other work.
set -uo pipefail

# --- kill switch (first, before any work) ----------------------------------
if [ "${SUPERPOWERS_TIER_GUARD:-1}" = "0" ]; then
  echo "tier-scan: SUPERPOWERS_TIER_GUARD=0 — skipping tier re-scan."
  exit 0
fi

USAGE="tools/tier-scan.sh --tier T0|T1|T2 [--range <git-range>] [--check]"

# --- arg parse -------------------------------------------------------------
TIER=""
RANGE=""
HAVE_RANGE=0
CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --tier requires a value (T0, T1, or T2)." >&2
        echo "  Correct form: $USAGE" >&2
        echo "  Averted: hanging on a flag with no value instead of failing loudly." >&2
        exit 2
      fi
      TIER="$2"; shift 2 ;;
    --tier=*) TIER="${1#--tier=}"; shift ;;
    --range)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --range requires a git range (e.g. HEAD~1..HEAD)." >&2
        echo "  Correct form: $USAGE" >&2
        echo "  Averted: hanging on a flag with no value instead of failing loudly." >&2
        exit 2
      fi
      RANGE="$2"; HAVE_RANGE=1; shift 2 ;;
    --range=*) RANGE="${1#--range=}"; HAVE_RANGE=1; shift ;;
    --check) CHECK=1; shift ;;
    *)
      echo "ERROR: unknown argument '$1'." >&2
      echo "  Correct form: $USAGE" >&2
      echo "  Averted: running an unrecognised flag as if it were a no-op." >&2
      exit 2 ;;
  esac
done

# --- validate tier ---------------------------------------------------------
if [ -z "$TIER" ]; then
  echo "ERROR: tier-scan.sh needs a declared tier to re-scan against." >&2
  echo "  Correct form: $USAGE" >&2
  echo "  Averted: re-scanning a diff with no budget to compare it to." >&2
  exit 2
fi
case "$TIER" in
  T0) MAXF=2;  MAXL=40;  NEXT=T1 ;;
  T1) MAXF=6;  MAXL=300; NEXT=T2 ;;
  T2) MAXF=-1; MAXL=-1;  NEXT=T2 ;;
  *)
    echo "ERROR: invalid tier '$TIER' — the tiers are T0, T1, T2." >&2
    echo "  Correct form: $USAGE" >&2
    echo "  Averted: sizing ceremony against a tier that does not exist." >&2
    exit 2 ;;
esac

# --- must be inside a git work tree ----------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository — tier-scan reads the diff with git." >&2
  echo "  Correct form: run tools/tier-scan.sh from within a git work tree." >&2
  echo "  Averted: reporting a tier as correctly sized while never reading a diff." >&2
  exit 2
fi

# --- count changed files and lines -----------------------------------------
FILES=0
LINES=0
add_numstat() { # consumes `git ... --numstat` on stdin; adds to FILES/LINES
  local add del path
  while read -r add del path; do
    [ -z "$path" ] && continue
    [ "$add" = "-" ] && add=0   # binary file: no line count
    [ "$del" = "-" ] && del=0
    FILES=$((FILES + 1))
    LINES=$((LINES + add + del))
  done
}

if [ "$HAVE_RANGE" -eq 1 ]; then
  add_numstat < <(git diff "$RANGE" --numstat)
else
  add_numstat < <(git diff HEAD --numstat)
  # untracked, non-ignored files: 1 file each, full line count as added lines.
  while IFS= read -r uf; do
    [ -z "$uf" ] && continue
    FILES=$((FILES + 1))
    n=$(awk 'END{print NR}' "$uf" 2>/dev/null || echo 0)
    n=${n:-0}
    LINES=$((LINES + n))
  done < <(git ls-files --others --exclude-standard)
fi

# --- compare to budget -----------------------------------------------------
OVER=0
if [ "$MAXF" -ge 0 ] && [ "$FILES" -gt "$MAXF" ]; then OVER=1; fi
if [ "$MAXL" -ge 0 ] && [ "$LINES" -gt "$MAXL" ]; then OVER=1; fi

if [ "$OVER" -eq 0 ]; then
  exit 0   # under budget (or T2 unlimited): a soft gate stays silent when clean
fi

# --- over budget: WARN in the gate-contract voice --------------------------
case "$TIER" in
  T0) AVERTED="a one-way door walked through at T0 ceremony — an unreviewed change shipping without the spread its true size demands." ;;
  T1) AVERTED="a T1 task quietly grown to T2 size — an architecture-scale diff landing without bracketing, ratification, or adversarial review." ;;
  *)  AVERTED="a task shipping under less ceremony than its diff earned." ;;
esac
{
  echo "TIER-SCAN: declared $TIER, but the diff is $FILES file(s) / $LINES changed line(s) — over the $TIER budget (<=$MAXF files AND <=$MAXL changed lines)."
  echo "  Correct form: escalate one tier — escalation is one-directional; re-scan --tier $NEXT and record which signal was missed at intake (the lesson, not a punishment)."
  echo "  Averted: $AVERTED"
} >&2

[ "$CHECK" -eq 1 ] && exit 1
exit 0
