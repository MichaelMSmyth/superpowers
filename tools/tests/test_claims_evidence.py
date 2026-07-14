#!/usr/bin/env python3
"""Tests for hooks/claims_evidence.py (B1). Pure-core unit tests + subprocess
end-to-end tests against synthetic transcript fixtures. No live API calls."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOK = os.path.join(REPO, "hooks", "claims_evidence.py")

spec = importlib.util.spec_from_file_location("claims_evidence", HOOK)
ce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ce)


def _assistant_line(text):
    return json.dumps({"type": "assistant",
                       "message": {"content": [{"type": "text", "text": text}]}})


def _transcript(*texts):
    """JSONL: a user line, then one assistant line per text (last one is final)."""
    lines = [json.dumps({"type": "user", "message": {"content": [
        {"type": "text", "text": "do the thing"}]}})]
    lines += [_assistant_line(t) for t in texts]
    return "\n".join(lines) + "\n"


class TestFinalAssistantText(unittest.TestCase):
    def test_takes_last_assistant_message(self):
        raw = _transcript("first reply", "second reply")
        self.assertEqual(ce.final_assistant_text(raw.splitlines()), "second reply")

    def test_trailing_non_assistant_lines_ignored(self):
        raw = _transcript("the reply") + json.dumps({"type": "result", "ok": True}) + "\n"
        self.assertEqual(ce.final_assistant_text(raw.splitlines()), "the reply")

    def test_garbage_lines_skipped(self):
        raw = "not json at all\n" + _transcript("reply")
        self.assertEqual(ce.final_assistant_text(raw.splitlines()), "reply")

    def test_empty_transcript_gives_empty(self):
        self.assertEqual(ce.final_assistant_text([]), "")


class TestUnevidencedClaims(unittest.TestCase):
    def test_bare_claim_flagged(self):
        hits = ce.unevidenced_claims("I finished. All tests pass and the bug is fixed.")
        self.assertEqual(len(hits), 1)  # one claim LINE (two claim phrases on it)

    def test_claim_with_nearby_evidence_not_flagged(self):
        text = ("All tests pass.\n"
                "```\nRan 24 tests in 0.31s\nOK\n```\n")
        self.assertEqual(ce.unevidenced_claims(text), [])

    def test_evidence_more_than_10_lines_away_still_flagged(self):
        text = "All tests pass.\n" + ("filler\n" * 12) + "```\nOK\n```\n"
        self.assertEqual(len(ce.unevidenced_claims(text)), 1)

    def test_no_claims_no_flags(self):
        self.assertEqual(ce.unevidenced_claims("I refactored the parser."), [])

    def test_exit_code_zero_counts_as_evidence(self):
        text = "Verified: the fix works as expected.\nexit 0\n"
        self.assertEqual(ce.unevidenced_claims(text), [])


class TestHookEndToEnd(unittest.TestCase):
    def _run(self, stdin_text, env_extra=None):
        env = dict(os.environ)
        env.pop("SUPERPOWERS_CLAIMS_GUARD", None)
        if env_extra:
            env.update(env_extra)
        return subprocess.run([sys.executable, HOOK], input=stdin_text,
                              capture_output=True, text=True, env=env)

    def _with_transcript(self, transcript_text):
        fd, path = tempfile.mkstemp(suffix=".jsonl")
        with os.fdopen(fd, "w") as fh:
            fh.write(transcript_text)
        self.addCleanup(os.unlink, path)
        return json.dumps({"hook_event_name": "SubagentStop",
                           "transcript_path": path})

    def test_evidence_free_claim_emits_advisory(self):
        stdin = self._with_transcript(_transcript("Done. All tests pass."))
        p = self._run(stdin)
        self.assertEqual(p.returncode, 0)
        out = json.loads(p.stdout)
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "SubagentStop")
        self.assertIn("CLAIMS-EVIDENCE", ctx)
        self.assertIn("within 10 lines", ctx)      # canonical form
        self.assertIn("Averted", ctx)              # averted failure

    def test_evidenced_claim_is_silent(self):
        stdin = self._with_transcript(_transcript(
            "All tests pass.\n```\nRan 24 tests\nOK\n```"))
        p = self._run(stdin)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")

    def test_malformed_stdin_fails_open(self):
        p = self._run("this is not json {{{")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")

    def test_missing_transcript_fails_open(self):
        stdin = json.dumps({"hook_event_name": "SubagentStop",
                            "transcript_path": "/nonexistent/nope.jsonl"})
        p = self._run(stdin)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")

    def test_kill_switch_silences_everything(self):
        stdin = self._with_transcript(_transcript("Done. All tests pass."))
        p = self._run(stdin, env_extra={"SUPERPOWERS_CLAIMS_GUARD": "0"})
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
