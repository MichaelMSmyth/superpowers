#!/usr/bin/env bash
# tools/coverage-floor.sh — B3 layer-1 organ: the coverage floor.
#
# The 2026-07-14 mutation flip-test (docs/findings/2026-07-14-mutation-fliptest.md,
# in the PROJECT repo one level up) measured that ~80% of the mutation survivors
# were whole-function-untested. A coverage floor catches that mass cheaply and
# model-free; the mutation audit (Task 4 / tools/mutation-check.sh) is the
# complementary layer that scores assertion QUALITY on the covered lines.
#
# It bootstraps a cached venv (tools/.covenv, gitignored) holding `coverage`,
# runs the tools/tests suite under measurement, prints the per-module report,
# then enforces a RATCHETED floor on the TOTAL. Per the enforcement ladder this
# is a rung-3/4 organ: it reports the state of play and returns an honest exit
# code; whether a red floor blocks a commit is the caller's business.
set -uo pipefail

# ratchet: floor(measured) on 2026-07-14 after adequacy suites — raise when
# coverage rises, never lower the floor.
FLOOR=88

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV="$SCRIPT_DIR/.covenv"
# Keep coverage's data file inside the gitignored venv so no stray .coverage
# lands in the repo root (both `run` and `report` honour COVERAGE_FILE).
export COVERAGE_FILE="$VENV/.coverage"

# --- bootstrap the coverage venv if absent ---------------------------------
if [ ! -x "$VENV/bin/coverage" ]; then
  python3 -m venv "$VENV" || {
    echo "coverage-floor: could not create venv at $VENV" >&2
    exit 2
  }
  "$VENV/bin/pip" -q install coverage || {
    echo "coverage-floor: could not install coverage into $VENV" >&2
    exit 2
  }
fi

cd "$REPO_ROOT" || exit 2

# --- measure (run from the repo root, source=tools) ------------------------
"$VENV/bin/coverage" run --source=tools -m unittest discover -s tools/tests -p 'test_*.py' >/dev/null 2>&1
"$VENV/bin/coverage" report

# --- enforce the ratcheted floor -------------------------------------------
if "$VENV/bin/coverage" report --fail-under="$FLOOR" >/dev/null 2>&1; then
  echo "COVERAGE FLOOR OK (>= ${FLOOR}%)"
  exit 0
else
  echo "COVERAGE FLOOR RED: TOTAL coverage fell below the ${FLOOR}% ratchet." >&2
  echo "  Canonical form: keep TOTAL coverage at or above the ratchet; add tests, never lower the floor." >&2
  echo "  Averted: silently eroding suite adequacy until whole functions go untested and mutants slip through." >&2
  exit 1
fi
