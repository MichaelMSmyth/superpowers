"""Tests for tools/drift_report.py — python3 -m unittest discover -s tools/tests -p 'test_drift*.py'"""
import os, subprocess, tempfile, unittest, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import drift_report as dr

def sh(cwd, *cmd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True)

class FixtureRepo:
    """base commit -> 'upstream/main' ref + diverged HEAD, mimicking the fork topology."""
    def __init__(self):
        self.dir = tempfile.mkdtemp()
        d = self.dir
        sh(d, "git", "init", "-q", "-b", "main")
        sh(d, "git", "config", "user.email", "t@t"); sh(d, "git", "config", "user.name", "t")
        os.makedirs(os.path.join(d, "skills/alpha"))
        for p, c in [("skills/alpha/SKILL.md", "---\nname: alpha\ndescription: Use when testing\n---\nbody\n"),
                     ("shared.md", "line1\n"), ("MODS.md", "| Date | File | Why |\n|---|---|---|\n")]:
            open(os.path.join(d, p), "w").write(c)
        sh(d, "git", "add", "-A"); sh(d, "git", "commit", "-qm", "base")
        self.base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=d, capture_output=True, text=True).stdout.strip()
        # upstream evolves shared.md + adds a new file
        sh(d, "git", "checkout", "-qb", "up")
        open(os.path.join(d, "shared.md"), "a").write("upstream line\n")
        open(os.path.join(d, "upstream_new.md"), "w").write("new\n")
        sh(d, "git", "add", "-A"); sh(d, "git", "commit", "-qm", "upstream work")
        sh(d, "git", "update-ref", "refs/remotes/upstream/main", "HEAD")
        # ours diverges: edits shared.md (unledgered!) + adds ours_new.md
        sh(d, "git", "checkout", "-q", "main")
        open(os.path.join(d, "shared.md"), "a").write("our line\n")
        open(os.path.join(d, "ours_new.md"), "w").write("ours\n")
        sh(d, "git", "add", "-A"); sh(d, "git", "commit", "-qm", "our work")

class TestClassification(unittest.TestCase):
    def setUp(self): self.r = FixtureRepo()
    def test_three_way_sets(self):
        rep = dr.classify(self.r.dir, self.r.base)
        self.assertIn("upstream_new.md", rep.upstream_only)
        self.assertIn("ours_new.md", rep.ours_only)
        self.assertIn("shared.md", rep.both)
    def test_unledgered_inherited_edit_flagged(self):
        warns = dr.ledger_check(self.r.dir, self.r.base)
        self.assertTrue(any("shared.md" in w for w in warns))
    def test_new_files_exempt_from_ledger(self):
        warns = dr.ledger_check(self.r.dir, self.r.base)
        self.assertFalse(any("ours_new.md" in w for w in warns))
    def test_ledger_row_silences(self):
        with open(os.path.join(self.r.dir, "MODS.md"), "a") as f:
            f.write("| 2026-07-14 | shared.md | test edit |\n")
        sh(self.r.dir, "git", "add", "-A"); sh(self.r.dir, "git", "commit", "-qm", "ledger")
        warns = dr.ledger_check(self.r.dir, self.r.base)
        self.assertFalse(any("shared.md" in w for w in warns))

class TestTokens(unittest.TestCase):
    def test_estimator(self):
        self.assertEqual(dr.est_tokens("a" * 8), 2)
        self.assertEqual(dr.est_tokens(""), 0)
        self.assertEqual(dr.est_tokens("abc"), 1)  # ceil

if __name__ == "__main__":
    unittest.main()
