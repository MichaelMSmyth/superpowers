#!/usr/bin/env python3
"""hooks/claims_evidence.py — advisory SubagentStop claim-physics guard (B1).

WHAT: when a subagent finishes, read its final assistant message and flag any
line that makes a completion claim ("all tests pass", "bug is fixed", ...) with
no evidence marker (a fenced block, a test summary, an 'exit 0', ...) within 10
lines. If — and only if — such a line exists, emit an `additionalContext`
advisory so the main loop sees the gate contract before it trusts the claim.

WHY ADVISORY: this hook NEVER blocks and NEVER fails the stop. Blocking a
subagent stop on a heuristic would be a false-positive tax on every honest run;
the enforcement-ladder ruling (rung 2/3) is to inject a right-moment reminder,
not a gate. It also FAILS OPEN: any internal error — malformed stdin, a missing
or unreadable transcript, a parse failure — exits 0 in silence. The guard can
only ever ADD a note; it can never obstruct.

KILL SWITCH: set env `SUPERPOWERS_CLAIMS_GUARD=0` for an immediate silent exit 0,
checked before anything else (before stdin is even read).

STDIN SHAPE (observed via live SubagentStop probe, 2026-07-14): the payload is a
JSON object whose top-level keys are:
    agent_id, agent_transcript_path, agent_type, background_tasks, cwd, effort,
    hook_event_name, last_assistant_message, permission_mode, session_crons,
    session_id, stop_hook_active, transcript_path
Two transcript fields exist and they differ: `transcript_path` points at the
MAIN session's transcript, while `agent_transcript_path` points at THIS
subagent's transcript (.../subagents/agent-<id>.jsonl) — the one we want, since
its last assistant message is the subagent's final reply. We therefore prefer
`agent_transcript_path` and fall back to `transcript_path`. (The probe also
surfaced `last_assistant_message`, the final text pre-extracted — a convenient
shortcut we deliberately do not depend on, keeping the transcript-parse core
testable against synthetic fixtures.)

Python3 stdlib only.
"""

import json
import os
import re
import sys

# A completion claim: an assertion that work is done / correct / verified.
CLAIM_RE = re.compile(
    r"\b(all tests pass|tests? pass(es|ed)?|works (correctly|now|as expected)"
    r"|is (now )?fixed|fixed the bug|bug is fixed|fully implemented"
    r"|implementation is complete|completed successfully|verified"
    r"|confirmed working)\b", re.I)

# An evidence marker: captured command output that could substantiate a claim.
EVIDENCE_RE = re.compile(
    r"(```|\bexit (code )?0\b|\brc=0\b|\bOK\b|\bRan \d+ tests?\b"
    r"|\b\d+ (passed|passing)\b|\bPASS(ED)?\b|^\$ |^    \S)", re.I | re.M)

WINDOW = 10


def final_assistant_text(lines):
    """Concatenated text blocks of the LAST assistant message in a transcript.

    `lines` is an iterable of transcript-JSONL lines. Each is parsed as JSON
    (unparseable lines skipped); the last object with type == "assistant" wins,
    and its message.content[] text blocks are joined with newlines. Returns ""
    when there is no assistant message.
    """
    last = None
    for line in lines:
        s = line.strip() if isinstance(line, str) else line
        if not s:
            continue
        try:
            obj = json.loads(s)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and obj.get("type") == "assistant":
            last = obj
    if not isinstance(last, dict):
        return ""
    message = last.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return content
    texts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text")
                if isinstance(t, str):
                    texts.append(t)
    return "\n".join(texts)


def _line_has_evidence(line):
    """True if `line` carries an evidence marker. The claim phrases are stripped
    first: a claim word must never count as its own evidence (e.g. the "pass" in
    "all tests pass" matches EVIDENCE_RE's \\bPASS\\b — verified against the live
    regexes — so without this strip a bare claim would launder itself clean)."""
    return EVIDENCE_RE.search(CLAIM_RE.sub(" ", line)) is not None


def unevidenced_claims(text):
    """Return [(line_no, line)] for each claim-line with no evidence within ±10.

    A line matching CLAIM_RE is flagged unless some line in the inclusive
    [i-10, i+10] window carries an evidence marker (per-line, claim phrases
    stripped). line_no is 1-based for human-readable advisories.
    """
    lines = text.splitlines()
    n = len(lines)
    hits = []
    for i, line in enumerate(lines):
        if not CLAIM_RE.search(line):
            continue
        lo = max(0, i - WINDOW)
        hi = min(n, i + WINDOW + 1)
        if not any(_line_has_evidence(lines[j]) for j in range(lo, hi)):
            hits.append((i + 1, line))
    return hits


def _advisory(hits):
    """The gate-contract advisory: names the claim line(s), the canonical form,
    and the averted failure. Carries the literals CLAIMS-EVIDENCE / within 10
    lines / Averted that the contract test pins."""
    flagged = "; ".join("L%d: %s" % (no, line.strip()[:120]) for no, line in hits)
    return (
        "CLAIMS-EVIDENCE (advisory, non-blocking): the subagent's final message "
        "makes completion claim(s) with no captured evidence within 10 lines.\n"
        "Flagged line(s): %s\n"
        "Canonical form: pair each completion claim with captured evidence — "
        "command + output — within 10 lines of the claim (a fenced ``` block, a "
        "test summary like 'Ran N tests / OK', an 'exit 0'/'rc=0', or 'N passed')."
        "\nAverted: an unverified claim laundered into the record as if proven."
        % flagged)


def main():
    # Kill switch first — before stdin is read, before any work.
    if os.environ.get("SUPERPOWERS_CLAIMS_GUARD") == "0":
        return 0
    try:
        data = json.loads(sys.stdin.read())
        if not isinstance(data, dict):
            return 0
        # Prefer the SUBAGENT's own transcript; transcript_path is the main
        # session's (probe 2026-07-14). Fall back for the fixture shape.
        path = data.get("agent_transcript_path") or data.get("transcript_path")
        if not isinstance(path, str) or not path:
            return 0
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        hits = unevidenced_claims(final_assistant_text(lines))
        if not hits:
            return 0
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SubagentStop",
            "additionalContext": _advisory(hits)}}))
        return 0
    except Exception:
        # Fail open: an advisory guard must never obstruct a stop.
        return 0


if __name__ == "__main__":
    sys.exit(main())
