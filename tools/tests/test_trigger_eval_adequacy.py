#!/usr/bin/env python3
"""Adequacy tests for tools/trigger_eval.py — from the mutation flip-test
worklist. Pure functions + dry-run CLI only; ZERO live API calls."""

import contextlib
import io
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
import unittest.mock as mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "trigger_eval", os.path.join(TOOLS, "trigger_eval.py"))
te = importlib.util.module_from_spec(spec)
spec.loader.exec_module(te)


class TestValidateFixtureGuards(unittest.TestCase):
    def test_bad_skill_values_raise_valueerror(self):
        """Kills the skill-guard `or` -> `and` mutants: None.strip() would
        raise AttributeError instead of the contracted ValueError."""
        for bad in (None, 42, "", "   "):
            with self.assertRaises(ValueError):
                te.validate_fixture({"skill": bad, "positive": [], "negative": []})

    def test_negative_prompt_naming_skill_is_caught(self):
        """Kills the kind-tuple mutant: the NEGATIVE list is validated too."""
        fx = {"skill": "brainstorming", "positive": ["design a thing"],
              "negative": ["please use brainstorming here"]}
        with self.assertRaises(te.BlindnessError):
            te.validate_fixture(fx)

    def test_blindness_message_names_offender_and_contract(self):
        """Kills the message-text mutants: assert content, not just type."""
        fx = {"skill": "brainstorming",
              "positive": ["let us do some brainstorming now"], "negative": []}
        with self.assertRaises(te.BlindnessError) as cm:
            te.validate_fixture(fx)
        msg = str(cm.exception)
        self.assertIn("blindness gate", msg)
        self.assertIn("positive[0]", msg)
        self.assertIn("Averted", msg)


class TestSkillTargets(unittest.TestCase):
    def test_bare_and_qualified(self):
        self.assertEqual(te._skill_targets("  Brainstorming "),
                         {"brainstorming",
                          "superpowers-extended-cc:brainstorming"})


class TestDetectFire(unittest.TestCase):
    def _stream(self, tool_name, skill_value):
        return json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": tool_name,
             "input": {"skill": skill_value, "args": ""}}]}})

    def test_json_fire_detected(self):
        raw = self._stream("Skill", "superpowers-extended-cc:brainstorming")
        self.assertEqual(te.detect_fire(raw, "brainstorming"), (True, "json"))

    def test_json_other_tool_not_a_fire(self):
        raw = self._stream("Read", "brainstorming")
        self.assertEqual(te.detect_fire(raw, "brainstorming"), (False, "json"))

    def test_json_wrong_skill_not_a_fire(self):
        raw = self._stream("Skill", "writing-plans")
        self.assertEqual(te.detect_fire(raw, "brainstorming"), (False, "json"))

    def test_text_fallback_fire_and_mode(self):
        raw = "no json here; the Skill tool ran brainstorming"
        self.assertEqual(te.detect_fire(raw, "brainstorming"), (True, "text"))

    def test_empty_output_no_fire_text_mode(self):
        self.assertEqual(te.detect_fire("", "brainstorming"), (False, "text"))


class TestVerdictEdges(unittest.TestCase):
    def test_zero_n_raises(self):
        with self.assertRaises(ValueError):
            te.prompt_verdict("positive", 0, 0)

    def test_unknown_kind_raises(self):
        with self.assertRaises(ValueError):
            te.prompt_verdict("sideways", 1, 5)


class TestDrySummaryAndMain(unittest.TestCase):
    def _fixture_file(self, fx):
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as fh:
            json.dump(fx, fh)
        self.addCleanup(os.unlink, path)
        return path

    def _main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = te.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_dry_summary_counts_and_cap_note(self):
        fx = {"skill": "x", "positive": ["p"] * 6, "negative": ["n"] * 4}
        s = te._dry_summary("x", fx, 5)
        self.assertIn("positive prompts: 6", s)
        self.assertIn("negative prompts: 4", s)
        self.assertIn("5 x 10 = 50", s)
        self.assertIn("exceeds the --live cap", s)

    def test_main_dry_run_exits_zero(self):
        path = self._fixture_file(
            {"skill": "x", "positive": ["design me a widget"], "negative": []})
        rc, out, _ = self._main(["--skill", "x", "--fixtures", path])
        self.assertEqual(rc, 0)
        self.assertIn("DRY RUN", out)

    def test_main_skill_mismatch_exits_two(self):
        path = self._fixture_file({"skill": "y", "positive": [], "negative": []})
        rc, _, err = self._main(["--skill", "x", "--fixtures", path])
        self.assertEqual(rc, 2)
        self.assertIn("disagrees", err)

    def test_main_blindness_violation_exits_two(self):
        path = self._fixture_file(
            {"skill": "x", "positive": ["please run x now"], "negative": []})
        rc, _, err = self._main(["--skill", "x", "--fixtures", path])
        self.assertEqual(rc, 2)
        self.assertIn("blindness gate", err)


class TestTimeoutPartialStream(unittest.TestCase):
    """run_once must check the partial stream on timeout — a fire that already
    happened is a fire (finding: 2026-07-14-eval-timeout-artifact)."""

    @staticmethod
    def _fire_line(skill):
        return json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Skill",
             "input": {"skill": "superpowers-extended-cc:" + skill}}]}})

    def _run_with_timeout(self, stdout):
        exc = subprocess.TimeoutExpired(cmd=["claude"], timeout=1, output=stdout)
        with mock.patch.object(te.subprocess, "run", side_effect=exc):
            return te.run_once("prompt", "intent", ".", timeout=1)

    def test_fire_in_partial_stream_counts_as_fire(self):
        fired, mode, note = self._run_with_timeout(self._fire_line("intent"))
        self.assertTrue(fired)
        self.assertEqual(mode, "json")
        # Exact note, not membership: the mutant that XX-wraps the whole string
        # ("XXfired before timeout...XX") keeps "before timeout" as a substring,
        # so assertIn survives it. Pin the literal. (kills survivor 128)
        self.assertEqual(note, "fired before timeout at 1s (partial stream)")

    def test_bytes_partial_stream_decoded(self):
        fired, _, note = self._run_with_timeout(self._fire_line("intent").encode())
        self.assertTrue(fired)
        self.assertIn("before timeout", note)

    def test_invalid_utf8_partial_decoded_via_replace(self):
        # Invalid UTF-8 in the partial stream must decode via errors="replace",
        # NOT raise: a fire on the clean first line still counts. The garbage is
        # on its own line so the fire JSON stays parseable. The mutant that
        # changes errors to "XXreplaceXX" raises LookupError on the bad bytes and
        # propagates out of run_once, so this test errors against it. (kills 124)
        raw = self._fire_line("intent").encode() + b"\n\xff\xfe garbage\n"
        fired, mode, _ = self._run_with_timeout(raw)
        self.assertTrue(fired)
        self.assertEqual(mode, "json")

    def test_no_fire_in_partial_stream_stays_timeout(self):
        fired, mode, note = self._run_with_timeout("some unrelated text\n")
        self.assertFalse(fired)
        self.assertEqual(mode, "timeout")
        # Exact note (see above): "no fire in partial stream" survives XX-wrap as
        # a substring; pin the literal. (kills survivor 132)
        self.assertEqual(note, "timed out after 1s, no fire in partial stream")

    def test_none_partial_stream_stays_timeout(self):
        fired, mode, _ = self._run_with_timeout(None)
        self.assertFalse(fired)
        self.assertEqual(mode, "timeout")


class TestRunOnceNormalReturn(unittest.TestCase):
    """run_once's NON-timeout path: cmd construction (blindness + stream-json
    doctrine), normal-return fire detection, and rc annotation. The flip test
    left this whole path untested — subprocess.run was only ever mocked to
    RAISE, never to RETURN a completed process."""

    @staticmethod
    def _fire_line(skill):
        return json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Skill",
             "input": {"skill": "superpowers-extended-cc:" + skill}}]}})

    def _run(self, returncode, stdout, timeout=42):
        proc = mock.Mock(returncode=returncode, stdout=stdout)
        with mock.patch.object(te.subprocess, "run", return_value=proc) as m:
            result = te.run_once("do a thing", "intent", "/work", timeout=timeout)
        return result, m

    def test_fire_returns_json_empty_note_and_exact_cmd(self):
        (fired, mode, note), m = self._run(1, self._fire_line("intent"))
        # A fire on a normal return: json mode, no rc note (rc annotated only
        # when NOT fired). Exact triple kills the note-init mutants (138/139)
        # and the detect_fire-unpack mutant (137). (kills 137, 138, 139)
        self.assertEqual((fired, mode, note), (True, "json", ""))
        # Blindness + format doctrine, pinned exactly: plain -p, max-turns 2,
        # stream-json, verbose; captured, text, DEVNULL stdin, our timeout.
        # (kills the cmd/argv + subprocess-kwarg survivors 111-120)
        args, kwargs = m.call_args
        self.assertEqual(args[0], ["claude", "-p", "do a thing",
                                   "--max-turns", "2",
                                   "--output-format", "stream-json", "--verbose"])
        self.assertEqual(kwargs["cwd"], "/work")
        self.assertIs(kwargs["capture_output"], True)
        self.assertIs(kwargs["text"], True)
        self.assertEqual(kwargs["timeout"], 42)
        self.assertIs(kwargs["stdin"], te.subprocess.DEVNULL)

    def test_no_fire_rc1_is_annotated_exactly(self):
        # rc=1, no fire -> note "rc=1" exactly. Discriminates != 0 from == 0 and
        # != 1, the `and`->`or`/`and fired` guard mutants, and the note-format
        # mutants. (kills 140, 141, 142, 144, 145, 146)
        (fired, _mode, note), _ = self._run(1, "plain text, no fire here")
        self.assertFalse(fired)
        self.assertEqual(note, "rc=1")

    def test_no_fire_rc0_gets_no_note(self):
        # rc=0, no fire -> empty note. The `and`->`or` mutant would annotate
        # here (0 != 0 is False, but `or not fired` is True). (kills 143; also 140)
        (fired, _mode, note), _ = self._run(0, "plain text, no fire here")
        self.assertFalse(fired)
        self.assertEqual(note, "")

    def test_cli_missing_returns_error_triple(self):
        # FileNotFoundError branch, pinned exactly. (kills 134, 135, 136)
        with mock.patch.object(te.subprocess, "run", side_effect=FileNotFoundError()):
            self.assertEqual(te.run_once("p", "intent", ".", timeout=5),
                             (False, "error", "claude CLI not found on PATH"))


if __name__ == "__main__":
    unittest.main()
