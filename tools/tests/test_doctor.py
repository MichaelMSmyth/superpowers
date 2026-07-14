"""Tests for tools/doctor.py — python3 -m unittest discover -s tools/tests -p 'test_doctor*.py'"""
import os, tempfile, unittest, sys, json, stat
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import doctor

def mk_skill(root, dirname, name=None, description="Use when testing things", body="body\n", extra=""):
    d = os.path.join(root, "skills", dirname); os.makedirs(d, exist_ok=True)
    name = dirname if name is None else name
    open(os.path.join(d, "SKILL.md"), "w").write(
        f"---\nname: {name}\ndescription: {description}\n---\n{body}{extra}")
    return d

class TestDoctor(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "hooks"), exist_ok=True)
        json.dump({"hooks": []}, open(os.path.join(self.root, "hooks", "hooks.json"), "w"))
    def findings(self):
        return doctor.scan(self.root)  # list of Finding(id, severity, path, message)
    def ids(self):
        return [f.id for f in self.findings()]
    def test_clean_fixture_no_errors(self):
        mk_skill(self.root, "alpha")
        self.assertFalse([f for f in self.findings() if f.severity == "ERROR"])
    def test_d1_missing_frontmatter(self):
        d = os.path.join(self.root, "skills", "bad"); os.makedirs(d)
        open(os.path.join(d, "SKILL.md"), "w").write("no frontmatter\n")
        self.assertIn("D1", self.ids())
    def test_d2_name_mismatch(self):
        mk_skill(self.root, "beta", name="gamma")
        self.assertIn("D2", self.ids())
    def test_d3_dead_link(self):
        mk_skill(self.root, "alpha", body="see [ref](does/not/exist.md)\n")
        self.assertIn("D3", self.ids())
    def test_d4_oversize(self):
        mk_skill(self.root, "alpha", body="x\n" * 501)
        self.assertIn("D4", self.ids())
    def test_d5_trigger_collision(self):
        mk_skill(self.root, "one", description="Use when the moon is full and tides rise high")
        mk_skill(self.root, "two", description="Use when the moon is full and tides rise low")
        self.assertIn("D5", self.ids())
    def test_d6_hook_missing_file(self):
        json.dump({"hooks": [{"type": "SessionStart", "command": "hooks/nope.sh"}]},
                  open(os.path.join(self.root, "hooks", "hooks.json"), "w"))
        self.assertIn("D6", self.ids())
    def test_d6_hook_not_executable(self):
        p = os.path.join(self.root, "hooks", "h.sh"); open(p, "w").write("#!/bin/sh\n")
        os.chmod(p, stat.S_IRUSR | stat.S_IWUSR)  # rw-, not executable
        json.dump({"hooks": [{"type": "SessionStart", "command": "hooks/h.sh"}]},
                  open(os.path.join(self.root, "hooks", "hooks.json"), "w"))
        self.assertIn("D6", self.ids())

if __name__ == "__main__":
    unittest.main()
