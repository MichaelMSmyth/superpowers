#!/usr/bin/env bash
# tools/plan-lint.sh — rung-3 presence check for property-shaped verdicts.
#
# Every "### Task" block in a plan MUST carry an explicit **Property-shaped:**
# verdict — an accepted null ("no — <reason>") beats an unread instruction. This
# lint mechanizes the ASKING (enforcement ladder rung 3): it surfaces missing
# verdicts with their canonical form so the author answers, but it never blocks
# a mutation. Soft by default (WARN + exit 0); --check turns misses into exit 1
# for a CI caller that WANTS to block.
#
# Posture mirrors tools/dod-check.sh: this tool only reports the state of play;
# whether a miss blocks anything is the caller's business, not the lint's.
#
# HONEST EXIT SEMANTICS:
#   0  every task block carries the verdict (or soft mode: misses only warned)
#   1  --check mode AND at least one task block is missing the verdict
#   2  usage error — no plan file given, or the file does not exist
#
# Fence-aware: "### Task" lines inside ``` code fences are IGNORED — plans pin
# test files whose heredocs contain literal "### Task" lines, and those are not
# real task headings. A verdict found inside a fence likewise does not count.
set -uo pipefail

# --- arg parse -------------------------------------------------------------
CHECK=0
PLAN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --) shift; PLAN="${1:-}"; [ "$#" -gt 0 ] && shift ;;
    -*)
      echo "ERROR: unknown flag '$1'." >&2
      echo "  Correct form: tools/plan-lint.sh [--check] <plan.md>" >&2
      echo "  Averted: running an unrecognised flag as if it were the plan path." >&2
      exit 2 ;;
    *) PLAN="$1"; shift ;;
  esac
done

# --- plan file present & readable ------------------------------------------
if [ -z "$PLAN" ]; then
  echo "ERROR: plan-lint.sh needs a plan file to lint." >&2
  echo "  Correct form: tools/plan-lint.sh [--check] <plan.md>" >&2
  echo "  Averted: reporting a plan as lint-clean while never reading one." >&2
  exit 2
fi
if [ ! -f "$PLAN" ]; then
  echo "ERROR: plan file not found or not a regular file: $PLAN" >&2
  echo "  Correct form: tools/plan-lint.sh [--check] <path-to-existing-plan.md>" >&2
  echo "  Averted: a typo'd path silently passing as an empty, taskless plan." >&2
  exit 2
fi

# --- scan: fence-aware block walk over "### Task" headings -----------------
# awk owns the verdict; it exits 0 (clean or soft) or 1 (--check with a miss).
awk -v check="$CHECK" '
  BEGIN { infence = 0; ntask = 0; nmiss = 0; have = 0; curhead = "" }
  function finalize() {
    if (curhead != "" && !have) { miss[nmiss] = curhead; nmiss++ }
  }
  # a code-fence delimiter toggles fence state and is never itself a heading
  /^[[:space:]]*```/ { infence = !infence; next }
  infence { next }
  /^### Task/ {
    finalize()
    ntask++
    curhead = $0
    sub(/^###[[:space:]]*/, "", curhead)
    have = 0
    next
  }
  { if (curhead != "" && index($0, "**Property-shaped:**") > 0) have = 1 }
  END {
    finalize()
    if (nmiss > 0) {
      for (i = 0; i < nmiss; i++)
        print "WARN: " miss[i] " — no **Property-shaped:** verdict in this task block."
      print "  Canonical form: **Property-shaped:** yes — <the property> | no — <why example tests suffice>"
      print "  Averted: an input-selection-biased suite nobody chose deliberately."
      print "PLAN LINT: " nmiss " of " ntask " task(s) missing the **Property-shaped:** verdict (soft — not blocking)."
      if (check) exit 1
      exit 0
    }
    print "PLAN LINT OK (" ntask " tasks)"
    exit 0
  }
' "$PLAN"
exit $?
