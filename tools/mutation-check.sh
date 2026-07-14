#!/usr/bin/env bash
# tools/mutation-check.sh — B3 layer-2 organ: the phase-close mutation AUDIT.
#
# WHY TWO LAYERS (see docs/findings/2026-07-14-mutation-fliptest.md, in the
# PROJECT repo one level up). The flip-test mutated our own pinned suites and
# measured 71.7% mutant survival — but split the value in two:
#   layer 1  tools/coverage-floor.sh  — the survivor MASS (~80%) was whole
#            untested functions; a cheap, model-free coverage floor catches those.
#   layer 2  THIS TOOL                — the mutation-specific minority is weak
#            assertions inside COVERED code (the star find: `both = U & O` mutated
#            to `U | O` survives because a test asserts membership but never
#            disjointness). Nothing but mutation testing sees that class. So this
#            is a periodic assertion-QUALITY audit (enforcement ladder rung 5),
#            not a per-task gate.
#
# FLIP-TEST BASELINE (2026-07-14) — future runs read as deltas against these
# per-module survivor rates:
#     trigger_eval  86.8%      doctor  56.1%      drift_report  68.2%
#     (total 493/688 = 71.7%)
#
# BOX FACTS THIS TOOL ENCODES (each a hard-won operational lesson from the finding):
#  1. Mutating subprocess-spawning code DEADLOCKS mutmut: a mutant flipping
#     capture_output=True->False makes a child `git` inherit and block forever on
#     mutmut's stdout pipe (two observed 20-min hangs). FIX, mandatory per module:
#     the runner mutmut invokes redirects ALL output to /dev/null and is wrapped in
#     `timeout -s KILL`. See make_runner() below.
#  2. Interrupted mutmut leaves sources MUTATED on disk (kill -9 mid-mutant). So we
#     NEVER touch the live repo: we `cp -r` it to a mktemp scratch dir and mutate
#     only there, with a trap that rm -rf's the scratch on any exit.
#  3. Version pins, enforced with instructive refusals below:
#       - mutmut<3 : 3.x is pytest-locked (no custom runner string); our unittest
#         suites in tools/tests/ need 2.x's `runner=`. Installed into a cached venv.
#       - python3.12 : mutmut 2.5.1 crashes on Python 3.14 (`cannot pickle
#         'itertools.count'`). A crashed audit reads as a clean one — refuse loudly.
#
# HONEST EXIT SEMANTICS — this is an audit REPORTER; posture is the caller's:
#   0  report produced (survivors are DATA, not failure) — the default, always,
#      UNLESS --fail-over N is given and some module's survivor rate exceeds N.
#   1  --fail-over N given and at least one module's survivor rate > N.
#   2  refusal: python3.12 missing, or the mutmut<3 venv could not be built.
# Whether a high survivor rate blocks anything is decided by whoever invokes this.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Cached mutmut venv lives in the REAL repo's tools/ (gitignored .mutenv), reused
# across runs — it is never mutated; only the scratch copy is.
VENV="$SCRIPT_DIR/.mutenv"

# --- defaults / arg parse --------------------------------------------------
REPO="$REPO_ROOT"
MODULES="drift_report doctor trigger_eval"
FAILOVER=""

print_help() {
  cat <<EOF
mutation-check.sh — B3 layer-2 phase-close mutation audit (assertion quality).

USAGE:
  tools/mutation-check.sh [--repo <path>] [--modules "<space-sep names>"] [--fail-over <pct>]

SAFETY INVARIANT (non-negotiable):
  This tool NEVER mutates the live repo. It copies the target repo to a mktemp
  SCRATCH directory and runs mutmut only against that scratch copy, so an
  interrupted run (which leaves sources mutated on disk) can never corrupt real
  files. The scratch dir is rm -rf'd on any exit.

FLAGS:
  --repo <path>        Repo to audit (default: this script's own repo).
  --modules "<names>"  Space-separated module basenames under tools/ to mutate
                       (default: "drift_report doctor trigger_eval").
  --fail-over <pct>    If given, exit 1 when any module's survivor rate > pct.
                       Omitted (default): exit 0 always — this is a reporter.
  --help               Show this help and exit 0.

REQUIRES: python3.12 on PATH; installs mutmut<3 into a cached venv (tools/.mutenv).
See the header comment and docs/findings/2026-07-14-mutation-fliptest.md.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help; exit 0 ;;
    --repo)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --repo requires a path argument." >&2
        echo "  Canonical form: tools/mutation-check.sh --repo <path>" >&2
        echo "  Averted: hanging on a flag with no value instead of failing loudly." >&2
        exit 2
      fi
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --modules)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --modules requires a value." >&2
        echo "  Canonical form: tools/mutation-check.sh --modules \"drift_report doctor\"" >&2
        echo "  Averted: hanging on a flag with no value instead of failing loudly." >&2
        exit 2
      fi
      MODULES="$2"; shift 2 ;;
    --modules=*) MODULES="${1#--modules=}"; shift ;;
    --fail-over)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --fail-over requires a percentage argument." >&2
        echo "  Canonical form: tools/mutation-check.sh --fail-over 90" >&2
        echo "  Averted: hanging on a flag with no value instead of failing loudly." >&2
        exit 2
      fi
      FAILOVER="$2"; shift 2 ;;
    --fail-over=*) FAILOVER="${1#--fail-over=}"; shift ;;
    *)
      echo "ERROR: unknown argument '$1'." >&2
      echo "  Canonical form: tools/mutation-check.sh [--repo <path>] [--modules \"<names>\"] [--fail-over <pct>]" >&2
      echo "  Averted: running an unrecognised flag as if it were a no-op." >&2
      exit 2 ;;
  esac
done

# --- REFUSAL 1: python3.12 pin (before any python work) --------------------
if ! command -v python3.12 >/dev/null 2>&1; then
  echo "ERROR: python3.12 is required but was not found on PATH." >&2
  echo "  Canonical form: install it (e.g. 'sudo apt install python3.12') and ensure 'python3.12' resolves on PATH." >&2
  echo "  Averted: mutmut 2.5.1 crashes on Python 3.14 (cannot pickle 'itertools.count') — a crashed audit reads as a clean one." >&2
  exit 2
fi

# --- REFUSAL 2: mutmut<3 venv pin ------------------------------------------
if [ ! -x "$VENV/bin/mutmut" ]; then
  echo "mutation-check: bootstrapping cached mutmut<3 venv at $VENV ..." >&2
  if ! python3.12 -m venv "$VENV"; then
    echo "ERROR: could not create the python3.12 venv at $VENV." >&2
    echo "  Canonical form: ensure python3.12 has the 'venv' module ('sudo apt install python3.12-venv') and $VENV is writable." >&2
    echo "  Averted: silently proceeding without a mutation runner, then reporting an empty audit as a clean one." >&2
    exit 2
  fi
  if ! "$VENV/bin/pip" -q install 'mutmut<3'; then
    echo "ERROR: could not install 'mutmut<3' into $VENV." >&2
    echo "  Canonical form: pip install 'mutmut<3' (3.x is pytest-locked and cannot use our unittest 'runner=' string)." >&2
    echo "  Averted: falling back to a mutmut that ignores our custom runner and mutates against the wrong tests." >&2
    exit 2
  fi
fi
PY="$VENV/bin/python"          # the pinned interpreter the runner will use
MUTMUT="$VENV/bin/mutmut"

# --- BOX FACT 2: scratch copy — never mutate the live repo -----------------
if [ ! -d "$REPO" ]; then
  echo "ERROR: --repo path does not exist or is not a directory: $REPO" >&2
  exit 2
fi
REPO="$(cd "$REPO" && pwd)"    # normalise to absolute
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
SCRATCH_REPO="$SCRATCH/repo"
cp -r "$REPO" "$SCRATCH_REPO"

# --- BOX FACT 1: the subprocess-safe wrapper runner (MANDATORY) ------------
# Emits a per-module runner script whose ONLY job is to run that module's
# unittest file with all output silenced and a hard KILL backstop, so a mutant
# that flips a subprocess to inherit mutmut's stdout pipe cannot deadlock the run.
make_runner() {
  local mod="$1" path="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
# AUTO-GENERATED by tools/mutation-check.sh — subprocess-safe mutmut runner.
# MANDATORY per docs/findings/2026-07-14-mutation-fliptest.md (Operational lesson 1):
# a mutant flipping capture_output=True->False makes a child git inherit and block
# FOREVER on mutmut's stdout pipe (two observed 20-min hangs). Redirect ALL output
# to /dev/null and wrap in 'timeout -s KILL' so a deadlocked child is reaped, not
# waited on.
timeout -s KILL 60 "$PY" -m unittest discover -s tools/tests -p "test_${mod}*.py" >/dev/null 2>&1
EOF
  chmod +x "$path"
}

# count IDs of one mutmut status (survived/killed/timeout/suspicious/...) — the
# ids print space-separated; word-splitting counts them (wc avoided: RTK-unreliable).
count_status() {
  local ids; ids="$("$MUTMUT" result-ids "$1" 2>/dev/null)" || ids=""
  # shellcheck disable=SC2086
  set -- $ids
  printf '%s' "$#"
}

cd "$SCRATCH_REPO" || { echo "ERROR: scratch copy missing at $SCRATCH_REPO" >&2; exit 2; }

echo "== Mutation audit (B3 layer 2 — assertion quality) =="
echo "repo:    $REPO"
echo "scratch: $SCRATCH_REPO (ephemeral; rm -rf on exit)"
echo "mutmut:  $("$MUTMUT" version 2>/dev/null | head -1)   python: python3.12"
echo "baseline (2026-07-14): trigger_eval 86.8%  doctor 56.1%  drift_report 68.2%"
echo

# accumulate rows and survivor lines, print the table after the loop
ROWS=()
SURV_LINES=()
FAILED_MODS=()

for mod in $MODULES; do
  src="tools/${mod}.py"
  if [ ! -f "$src" ]; then
    ROWS+=("$(printf '%-14s %8s %8s %9s %9s' "$mod" "n/a" "n/a" "n/a" "MISSING")")
    SURV_LINES+=("  [${mod}] source not found in scratch repo ($src) — skipped")
    continue
  fi

  runner="$SCRATCH/run_tests_${mod}.sh"
  make_runner "$mod" "$runner"

  # setup.cfg [mutmut]: paths_to_mutate + our subprocess-safe runner + tests_dir
  cat > "$SCRATCH_REPO/setup.cfg" <<EOF
[mutmut]
paths_to_mutate=${src}
runner=${runner}
tests_dir=tools/tests/
EOF

  # fresh cache per module (box: stale cache would hide/miscount kills)
  rm -f "$SCRATCH_REPO/.mutmut-cache"

  # run; survivors make exit nonzero (bit-OR: 2=survived, 4=timeout) — tolerate it.
  log="$SCRATCH/mutmut_${mod}.log"
  "$MUTMUT" run --simple-output --no-progress >"$log" 2>&1 || true

  killed="$(count_status killed)"
  survived="$(count_status survived)"
  timeout_n="$(count_status timeout)"
  suspicious="$(count_status suspicious)"
  mutants=$((killed + survived + timeout_n + suspicious))

  rate="$(awk -v s="$survived" -v m="$mutants" \
    'BEGIN{ if (m>0) printf "%.1f%%", (s/m)*100; else printf "0.0%%" }')"

  ROWS+=("$(printf '%-14s %8s %8s %9s %9s' "$mod" "$mutants" "$killed" "$survived" "$rate")")

  ids="$("$MUTMUT" result-ids survived 2>/dev/null)" || ids=""
  if [ -n "$ids" ]; then
    SURV_LINES+=("  [${mod}] survivor mutant IDs: $ids")
  else
    SURV_LINES+=("  [${mod}] no survivors")
  fi

  # --fail-over posture (compare floats via awk)
  if [ -n "$FAILOVER" ]; then
    over="$(awk -v s="$survived" -v m="$mutants" -v f="$FAILOVER" \
      'BEGIN{ r=(m>0)?(s/m)*100:0; print (r>f)?1:0 }')"
    [ "$over" = "1" ] && FAILED_MODS+=("$mod")
  fi
done

# --- report: table (survived is field NF-1; rate is NF) --------------------
printf '%-14s %8s %8s %9s %9s\n' "module" "mutants" "killed" "survived" "rate"
for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
echo
echo "Survivors (a suite-strengthening worklist — weak assertions in covered code):"
for line in "${SURV_LINES[@]}"; do printf '%s\n' "$line"; done

# --- exit posture ----------------------------------------------------------
if [ -n "$FAILOVER" ] && [ "${#FAILED_MODS[@]}" -gt 0 ]; then
  echo >&2
  echo "MUTATION FAIL-OVER: survivor rate exceeded ${FAILOVER}% in: ${FAILED_MODS[*]}" >&2
  echo "  Canonical form: strengthen those modules' assertions until the rate drops at or below ${FAILOVER}%." >&2
  echo "  Averted: shipping a phase with assertion rot that the coverage floor cannot see." >&2
  exit 1
fi
exit 0
