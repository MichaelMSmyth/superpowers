"""Tests for tools/trigger_eval.py — python3 -m unittest discover -s tools/tests -p 'test_trigger*.py'"""
import unittest, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import trigger_eval as te

class TestScoring(unittest.TestCase):
    def test_positive_pass(self):
        self.assertEqual(te.prompt_verdict("positive", 5, 5), "PASS")   # 1.0
    def test_positive_fail(self):
        self.assertEqual(te.prompt_verdict("positive", 1, 5), "FAIL")   # 0.2
    def test_positive_grey(self):
        self.assertEqual(te.prompt_verdict("positive", 3, 5), "GREY")   # 0.6
    def test_negative_pass(self):
        self.assertEqual(te.prompt_verdict("negative", 0, 5), "PASS")
    def test_negative_fail(self):
        self.assertEqual(te.prompt_verdict("negative", 4, 5), "FAIL")   # 0.8
    def test_negative_grey(self):
        self.assertEqual(te.prompt_verdict("negative", 2, 5), "GREY")   # 0.4
    def test_skill_verdict_quarantine_dominates_pass(self):
        self.assertEqual(te.skill_verdict(["PASS", "GREY", "PASS"]), "QUARANTINE")
    def test_skill_verdict_fail_dominates_all(self):
        self.assertEqual(te.skill_verdict(["PASS", "GREY", "FAIL"]), "FAIL")
    def test_skill_verdict_all_pass(self):
        self.assertEqual(te.skill_verdict(["PASS", "PASS"]), "PASS")

class TestBlindness(unittest.TestCase):
    def test_fixture_naming_skill_is_refused(self):
        fx = {"skill": "brainstorming",
              "positive": ["please use the brainstorming skill"], "negative": []}
        with self.assertRaises(te.BlindnessError):
            te.validate_fixture(fx)
    def test_clean_fixture_ok(self):
        fx = {"skill": "brainstorming", "positive": ["let's design a widget"], "negative": ["what is 2+2"]}
        te.validate_fixture(fx)  # no raise

if __name__ == "__main__":
    unittest.main()
