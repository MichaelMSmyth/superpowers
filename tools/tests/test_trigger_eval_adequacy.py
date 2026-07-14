#!/usr/bin/env python3
"""Adequacy tests for tools/trigger_eval.py — from the mutation flip-test
worklist. Pure functions + dry-run CLI only; ZERO live API calls."""

import contextlib
import io
import importlib.util
import json
import os
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
