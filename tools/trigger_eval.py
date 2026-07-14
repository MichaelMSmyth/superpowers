#!/usr/bin/env python3
"""tools/trigger_eval.py — a BLIND N-run skill-trigger eval harness for the
superpowers-extended-cc fork.

WHAT IT MEASURES. Does the *currently installed* plugin auto-fire a target skill
on prompts that should trigger it (positive), and hold its fire on prompts that
should not (negative)? Each prompt is run N times in a FRESH headless `claude -p`
session; the fire-rate over N drives a per-prompt verdict, and the per-prompt
verdicts roll up to a skill verdict.

DOCTRINE (E11, "blind-eval"):
  * Evals run in FRESH headless sessions — no shared state, no priming.
  * The prompt must NEVER name the skill. A prompt that says "use the
    brainstorming skill" tests string-matching, not triggering. `validate_fixture`
    is a hard gate: it raises `BlindnessError` before any API call is made.
  * A check that can't fail isn't a check — negatives are first-class; a skill
    that fires on everything is as broken as one that never fires.
  * Flapping (GREY) is a FINDING to record, not noise — GREY prompts are appended
    to tools/quarantine.md rather than retried until they go green.

HEADLESS OUTPUT FORMAT (empirical, verified by a one-call probe 2026-07-14 with
CLI 2.1.183). We invoke:

    claude -p '<prompt>' --max-turns 2 --output-format stream-json --verbose

from a NEUTRAL working directory (the fork repo dir), plain `-p` with NO extra
system-prompt flags (blindness: nothing that could prime the skill). `stream-json`
emits newline-delimited JSON — one object per line, typed `system` (init / hook_*
/ thinking_tokens), `assistant`, `user`, and a final `result`. Each assistant/user
object carries a `message.content` list of blocks (`thinking` / `text` /
`tool_use` / `tool_result`). A SKILL FIRE is exactly a `tool_use` block whose
`name` == "Skill" and whose `input` is `{"skill": "<qualified-or-bare-name>",
"args": "..."}`. In the probe the positive prompt produced:

    tool_use name='Skill' input={'skill': 'superpowers-extended-cc:brainstorming',
                                 'args': '...'}

We detect a "fire" as: ANY Skill tool_use anywhere in the run whose serialized
input contains the target token — accepting BOTH the qualified
`superpowers-extended-cc:brainstorming` and the bare `brainstorming`. (A run that
fires the skill hits the --max-turns cap and exits rc=1 with result subtype
`error_max_turns`; that is the NORMAL outcome for a positive, not an error — we
only annotate rc on runs that did NOT fire.)

  * The single-result `--output-format json` was rejected for detection: it
    returns only the final assistant text (`.result`), so intermediate tool_use
    blocks — the actual trigger signal — are invisible. stream-json is required.
  * TEXT FALLBACK (weaker, documented): if no JSON line parses (format changed),
    we scan the raw text for a Skill-tool mention adjacent to the skill token.
    This can be fooled by the model merely *mentioning* the skill in prose
    without invoking it; a GREY/odd result under the fallback is itself a finding.

Python3 stdlib only. Public API for tests: prompt_verdict, skill_verdict,
validate_fixture (raising BlindnessError).
"""

import argparse
import datetime
import json
import os
import subprocess
import sys

# --- verdict thresholds ------------------------------------------------------
FIRE_HI = 0.8   # positive PASS / negative FAIL at or above
FIRE_LO = 0.2   # positive FAIL / negative PASS at or below
MAX_LIVE_PROMPTS = 8  # cost cap: N real API calls PER prompt, so bound the set
RUN_TIMEOUT_S = 180   # a single headless run: timed-out => counts as no-fire

QUARANTINE_HEADER = (
    "# Trigger-Eval Quarantine\n\n"
    "Flapping (GREY) prompts recorded by tools/trigger_eval.py. A row here is a\n"
    "FINDING — the skill fires inconsistently on this prompt; investigate, don't\n"
    "retry-fish for a pass.\n\n"
    "| Date | Skill | Prompt | Rate |\n"
    "|------|-------|--------|------|\n"
)

BLINDNESS_MESSAGE = (
    "blindness gate: prompts must not name the skill (case-insensitive). "
    "Averted: an eval that tests string-matching instead of triggering."
)


class BlindnessError(Exception):
    """A fixture prompt names the target skill — the eval would test string
    matching, not blind triggering. Raised by validate_fixture."""


# --- pure scoring (unit-tested) ---------------------------------------------

def prompt_verdict(kind, fires, n):
    """Verdict for one prompt from its fire-count over n runs.

    positive: PASS if rate >= 0.8, FAIL if rate <= 0.2, else GREY.
    negative: PASS if rate <= 0.2, FAIL if rate >= 0.8, else GREY.
    """
    if n <= 0:
        raise ValueError("n must be positive")
    rate = fires / n
    if kind == "positive":
        if rate >= FIRE_HI:
            return "PASS"
        if rate <= FIRE_LO:
            return "FAIL"
        return "GREY"
    if kind == "negative":
        if rate <= FIRE_LO:
            return "PASS"
        if rate >= FIRE_HI:
            return "FAIL"
        return "GREY"
    raise ValueError("kind must be 'positive' or 'negative', got %r" % (kind,))


def skill_verdict(verdicts):
    """Roll up per-prompt verdicts. Any FAIL => FAIL; else any GREY =>
    QUARANTINE; else PASS. (FAIL dominates; GREY quarantines an otherwise-clean
    skill.)"""
    if any(v == "FAIL" for v in verdicts):
        return "FAIL"
    if any(v == "GREY" for v in verdicts):
        return "QUARANTINE"
    return "PASS"


# --- blindness gate (unit-tested) -------------------------------------------

def validate_fixture(fx):
    """Raise BlindnessError if any prompt contains the skill name (case-
    insensitive substring). Also validates the fixture shape.

    The gate is the whole point: a prompt that names the skill would let a
    broken trigger pass by string-matching. Better to refuse the fixture than
    to run a check that cannot fail.
    """
    if not isinstance(fx, dict):
        raise ValueError("fixture must be a JSON object")
    skill = fx.get("skill")
    if not isinstance(skill, str) or not skill.strip():
        raise ValueError("fixture must have a non-empty 'skill' string")
    needle = skill.strip().lower()
    for kind in ("positive", "negative"):
        prompts = fx.get(kind, [])
        if not isinstance(prompts, list):
            raise ValueError("fixture '%s' must be a list of prompts" % kind)
        for i, prompt in enumerate(prompts):
            if not isinstance(prompt, str):
                raise ValueError("fixture %s[%d] must be a string" % (kind, i))
            if needle in prompt.lower():
                raise BlindnessError(
                    "%s\n  Offending prompt (%s[%d]): %r names the skill %r."
                    % (BLINDNESS_MESSAGE, kind, i, prompt, skill))


# --- headless detection ------------------------------------------------------

def _skill_targets(skill):
    """The accepted skill tokens: bare name and the qualified plugin form."""
    bare = skill.strip().lower()
    return {bare, "superpowers-extended-cc:" + bare}


def _iter_tool_uses(obj):
    """Recursively yield every dict with type == 'tool_use' inside a parsed
    stream-json object (content lives at message.content[]; be liberal)."""
    if isinstance(obj, dict):
        if obj.get("type") == "tool_use":
            yield obj
        for v in obj.values():
            yield from _iter_tool_uses(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _iter_tool_uses(v)


def _tool_use_hits(tu, targets):
    """True if this tool_use is a Skill invocation naming one of `targets`."""
    name = (tu.get("name") or "").lower()
    if "skill" not in name:
        return False
    inp = tu.get("input")
    blob = json.dumps(inp, ensure_ascii=False).lower() if inp is not None else ""
    return any(t in blob for t in targets)


def detect_fire(raw_output, skill):
    """Did the target skill fire in this run's raw stdout?

    Primary path: parse the NDJSON stream, find a Skill tool_use naming the
    target (bare or qualified). Fallback path (documented weakness): if NOTHING
    parses as JSON, scan text for a 'Skill' mention co-occurring with the token.
    Returns (fired: bool, mode: 'json' | 'text').
    """
    targets = _skill_targets(skill)
    parsed_any = False
    for line in raw_output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        parsed_any = True
        for tu in _iter_tool_uses(obj):
            if _tool_use_hits(tu, targets):
                return True, "json"
    if parsed_any:
        return False, "json"
    # Fallback: no JSON at all. Weak textual heuristic.
    low = raw_output.lower()
    if "skill" in low and any(t in low for t in targets):
        return True, "text"
    return False, "text"


def run_once(prompt, skill, cwd, timeout=RUN_TIMEOUT_S):
    """Run ONE fresh headless session. Returns (fired, mode, note).

    Blindness: plain `-p <prompt>`, NO system-prompt flags. A timeout counts as
    no-fire (noted) ONLY after the partial stream is checked for a fire — a
    session killed at the wall may already have fired. Benign 'SessionEnd
    hook ... cancelled' stderr noise is
    ignored. stream-json+--verbose is required for tool-use visibility.
    """
    cmd = ["claude", "-p", prompt,
           "--max-turns", "2",
           "--output-format", "stream-json",
           "--verbose"]
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL)  # no stdin: skip the CLI's 3s stdin wait
    except subprocess.TimeoutExpired as exc:
        # A timed-out session may already have fired: the partial stream
        # captured up to the kill is evidence, not garbage. Discarding it
        # turned a real +9s fire into a QUARANTINE on 2026-07-14 — see
        # docs/findings/2026-07-14-eval-timeout-artifact.md (project repo).
        partial = exc.stdout
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        if partial:
            fired, mode = detect_fire(partial, skill)
            if fired:
                return True, mode, "fired before timeout at %ds (partial stream)" % timeout
        return False, "timeout", "timed out after %ds, no fire in partial stream" % timeout
    except FileNotFoundError:
        return False, "error", "claude CLI not found on PATH"
    fired, mode = detect_fire(proc.stdout, skill)
    note = ""
    if proc.returncode != 0 and not fired:
        note = "rc=%d" % proc.returncode
    return fired, mode, note


def run_prompt(prompt, skill, cwd, n, timeout=RUN_TIMEOUT_S):
    """Run one prompt n times sequentially. Returns (fires, modes, notes)."""
    fires = 0
    modes = []
    notes = []
    for _ in range(n):
        fired, mode, note = run_once(prompt, skill, cwd, timeout=timeout)
        if fired:
            fires += 1
        modes.append(mode)
        if note:
            notes.append(note)
    return fires, modes, notes


# --- quarantine --------------------------------------------------------------

def _quarantine_path(root):
    return os.path.join(root, "tools", "quarantine.md")


def append_quarantine(root, skill, rows):
    """Append GREY rows to tools/quarantine.md (creating it with header if
    absent). `rows` is a list of (prompt_label, rate) tuples. This tool is the
    ONLY writer of this file."""
    if not rows:
        return
    path = _quarantine_path(root)
    today = datetime.date.today().isoformat()
    exists = os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
        if not exists:
            fh.write(QUARANTINE_HEADER)
        for label, rate in rows:
            fh.write("| %s | %s | %s | %.2f |\n" % (today, skill, label, rate))


# --- CLI ---------------------------------------------------------------------

def _default_root():
    # tools/trigger_eval.py -> repo root is the parent of tools/.
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_fixture(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _dry_summary(skill, fx, n):
    pos = fx.get("positive", [])
    neg = fx.get("negative", [])
    total = len(pos) + len(neg)
    lines = [
        "DRY RUN (no API calls) — trigger_eval for skill %r" % skill,
        "  positive prompts: %d" % len(pos),
        "  negative prompts: %d" % len(neg),
        "  total prompts:    %d" % total,
        "  N (runs/prompt):  %d" % n,
        "  live calls a --live run WOULD make: %d x %d = %d headless sessions"
        % (n, total, n * total),
        "  each: fresh `claude -p '<prompt>' --max-turns 2 "
        "--output-format stream-json --verbose` from the fork repo dir",
        "  detection: a Skill tool_use naming %r (bare or qualified)" % skill,
    ]
    if total > MAX_LIVE_PROMPTS:
        lines.append(
            "  NOTE: %d prompts exceeds the --live cap of %d; a live run would be refused."
            % (total, MAX_LIVE_PROMPTS))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Blind N-run skill-trigger eval harness (fork-local).")
    parser.add_argument("--skill", required=True, help="target skill name (bare)")
    parser.add_argument("--fixtures", required=True, help="fixture JSON path")
    parser.add_argument("--n", type=int, default=5, help="runs per prompt (default 5)")
    parser.add_argument("--live", action="store_true",
                        help="actually run headless claude sessions (real API calls)")
    parser.add_argument("--root", default=None,
                        help="repo root (default: the repo containing this script)")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root) if args.root else _default_root()

    try:
        fx = _load_fixture(args.fixtures)
    except (OSError, ValueError) as exc:
        print("ERROR: cannot read fixture %s: %s" % (args.fixtures, exc), file=sys.stderr)
        return 2

    skill = args.skill
    # A fixture may carry its own 'skill'; the CLI --skill is authoritative but
    # must agree, else the blindness gate would police the wrong name.
    fx_skill = fx.get("skill")
    if fx_skill and fx_skill != skill:
        print("ERROR: --skill %r disagrees with fixture skill %r; make them match."
              % (skill, fx_skill), file=sys.stderr)
        return 2
    fx.setdefault("skill", skill)

    # BLINDNESS GATE — before anything else, before any API call.
    try:
        validate_fixture(fx)
    except BlindnessError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2
    except ValueError as exc:
        print("ERROR: malformed fixture: %s" % exc, file=sys.stderr)
        return 2

    pos = fx.get("positive", [])
    neg = fx.get("negative", [])
    total = len(pos) + len(neg)

    if not args.live:
        print(_dry_summary(skill, fx, args.n))
        return 0

    # --- LIVE ---------------------------------------------------------------
    if total > MAX_LIVE_PROMPTS:
        print("ERROR: --live refuses %d prompts (cap %d). A live run makes N x prompts "
              "real API calls (here %d x %d = %d); trim the fixture or raise the cap "
              "deliberately." % (total, MAX_LIVE_PROMPTS, args.n, total, args.n * total),
              file=sys.stderr)
        return 2

    cwd = root  # neutral working dir: the fork repo, no project priming
    print("LIVE trigger_eval — skill %r, N=%d, %d prompts, %d sessions"
          % (skill, args.n, total, args.n * total))
    print("  cwd (neutral): %s" % cwd)

    verdicts = []
    grey_rows = []
    all_modes = set()
    for kind, prompts in (("positive", pos), ("negative", neg)):
        for idx, prompt in enumerate(prompts):
            fires, modes, notes = run_prompt(prompt, skill, cwd, args.n)
            all_modes.update(modes)
            rate = fires / args.n
            verdict = prompt_verdict(kind, fires, args.n)
            verdicts.append(verdict)
            label = "%s[%d]" % (kind, idx)
            note_s = (" notes=%s" % ";".join(notes)) if notes else ""
            print("  %-11s %2d/%d fire (%.2f) -> %-5s | %s%s"
                  % (label, fires, args.n, rate, verdict, prompt[:56], note_s))
            if verdict == "GREY":
                grey_rows.append((label, rate))

    overall = skill_verdict(verdicts)
    print("SKILL VERDICT: %s  (verdicts: %s)" % (overall, ", ".join(verdicts)))
    if "text" in all_modes:
        print("  WARNING: text-fallback detection was used on >=1 run "
              "(stream-json did not parse) — treat these results as weak.")

    if overall == "QUARANTINE" and grey_rows:
        append_quarantine(root, skill, grey_rows)
        print("  quarantined %d GREY prompt(s) -> %s"
              % (len(grey_rows), _quarantine_path(root)))

    # Exit: PASS 0, QUARANTINE 0, FAIL 1.
    return 1 if overall == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
