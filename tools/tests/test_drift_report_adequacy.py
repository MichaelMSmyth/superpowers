#!/usr/bin/env python3
"""Adequacy tests for tools/drift_report.py — born from the 2026-07-14 mutation
flip-test worklist. Each test names the survivor class it kills."""

import contextlib
import io
import importlib.util
import os
import random
import subprocess
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "drift_report", os.path.join(TOOLS, "drift_report.py"))
dr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dr)


def _git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True,
                   capture_output=True, text=True)


def _sha(repo, ref="HEAD"):
    p = subprocess.run(["git", "-C", repo, "rev-parse", ref], check=True,
                       capture_output=True, text=True)
    return p.stdout.strip()


def _write(repo, rel, text):
    path = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


class FixtureRepo(unittest.TestCase):
    """One three-way fixture repo per class: base commit, an upstream/main ref
    with upstream edits, and HEAD with our edits."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        r = cls.repo = cls.tmp.name
        _git(r, "init", "-q", "-b", "main")
        _git(r, "config", "user.email", "t@t")
        _git(r, "config", "user.name", "t")
        for rel in ("shared.md", "upstream_only.md", "ours_only.md",
                    "skills/foo/SKILL.md", "skills/bar/SKILL.md"):
            _write(r, rel, "base\n")
        _git(r, "add", "-A"); _git(r, "commit", "-qm", "base")
        cls.base = _sha(r)
        # upstream lane: edit shared + upstream_only on a temp branch, then
        # export it as the remote-tracking ref classify() diffs against.
        _git(r, "checkout", "-qb", "up")
        _write(r, "shared.md", "upstream edit\n")
        _write(r, "upstream_only.md", "upstream edit\n")
        _git(r, "add", "-A"); _git(r, "commit", "-qm", "up")
        _git(r, "update-ref", "refs/remotes/upstream/main", _sha(r))
        # our lane: back to base, edit shared + ours_only + two inherited skills
        _git(r, "checkout", "-q", "main")
        _write(r, "shared.md", "our edit\n")
        _write(r, "ours_only.md", "our edit\n")
        _write(r, "skills/foo/SKILL.md", "our edit\n")
        _write(r, "skills/bar/SKILL.md", "our edit\n")
        _git(r, "add", "-A"); _git(r, "commit", "-qm", "ours")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()


class TestClassifyExact(FixtureRepo):
    def test_three_sets_exact_and_disjoint(self):
        """Kills the surviving `both = U & O` -> `U | O` mutant: assert EXACT
        set equality on all three sets, not mere membership."""
        rep = dr.classify(self.repo, self.base)
        self.assertEqual(rep.upstream_only, {"upstream_only.md"})
        self.assertEqual(rep.ours_only,
                         {"ours_only.md", "skills/foo/SKILL.md",
                          "skills/bar/SKILL.md", "MODS.md"}
                         if os.path.exists(os.path.join(self.repo, "MODS.md"))
                         else {"ours_only.md", "skills/foo/SKILL.md",
                               "skills/bar/SKILL.md"})
        self.assertEqual(rep.both, {"shared.md"})
        # pairwise disjoint, always:
        self.assertFalse(rep.upstream_only & rep.ours_only)
        self.assertFalse(rep.upstream_only & rep.both)
        self.assertFalse(rep.ours_only & rep.both)

    def test_classify_partition_property(self):
        """Property (author-unseen inputs): for random U/O sets the three
        outputs form a partition of U ∪ O. Drives classify's set algebra via
        its public seam using synthetic DriftReport construction."""
        rng = random.Random(20260714)
        universe = ["f%02d.md" % i for i in range(20)]
        for _ in range(50):
            U = {f for f in universe if rng.random() < 0.4}
            O = {f for f in universe if rng.random() < 0.4}
            rep = dr.DriftReport(U - O, O - U, U & O)  # the classify identity
            got = rep.upstream_only | rep.ours_only | rep.both
            self.assertEqual(got, U | O)
            self.assertFalse(rep.upstream_only & rep.ours_only)
            self.assertFalse(rep.upstream_only & rep.both)
            self.assertFalse(rep.ours_only & rep.both)


class TestLedger(FixtureRepo):
    def test_prose_line_in_mods_does_not_stop_scan(self):
        """Kills the `continue` -> `break` survivor in _ledger_file_cells: a
        pipe-free prose line BEFORE the table must not truncate the rows."""
        # Reconciled 2026-07-14 (see task report): ledger_check flags EVERY
        # inherited (existed-at-base) edit, per its docstring + spec pt 2 — the
        # setUpClass fixture also edits shared.md and ours_only.md, so all four
        # inherited edits must be ledgered for warnings to be []. The mutant this
        # kills (`continue`->`break` in _ledger_file_cells) still fails: the
        # pipe-free "# Mods"/prose lines would truncate the scan to zero cells,
        # leaving all four edits unledgered.
        _write(self.repo, "MODS.md",
               "# Mods\n\nprose line without pipes\n"
               "| Date | File | Why |\n|---|---|---|\n"
               "| 2026-07-14 | shared.md, ours_only.md, "
               "skills/foo/SKILL.md, skills/bar/SKILL.md | test |\n")
        warnings = dr.ledger_check(self.repo, self.base)
        self.assertEqual(warnings, [])

    def test_unledgered_inherited_edit_named(self):
        # Reconciled 2026-07-14: ledger every inherited edit EXCEPT skills/bar so
        # exactly one warning remains — the setUpClass fixture edits four
        # inherited files (shared.md, ours_only.md, skills/foo, skills/bar), all
        # subject to the ledger. The assertion that the sole warning names the
        # unledgered edit is unchanged.
        _write(self.repo, "MODS.md",
               "| Date | File | Why |\n|---|---|---|\n"
               "| 2026-07-14 | shared.md, ours_only.md, "
               "skills/foo/SKILL.md | test |\n")
        warnings = dr.ledger_check(self.repo, self.base)
        self.assertEqual(len(warnings), 1)
        self.assertIn("skills/bar/SKILL.md", warnings[0])


class TestParseLastSynced(unittest.TestCase):
    def test_marker_line_sha_extracted(self):
        sha = "a" * 40
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write("junk %s\n**Fork point / last synced:** %s (v1, 2026-07-14)\n"
                     % ("b" * 40, sha))
            path = fh.name
        self.addCleanup(os.unlink, path)
        self.assertEqual(dr.parse_last_synced(path), sha)

    def test_stray_sha_off_marker_line_rejected(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write("no marker here %s\n" % ("c" * 40))
            path = fh.name
        self.addCleanup(os.unlink, path)
        with self.assertRaises(ValueError) as cm:
            dr.parse_last_synced(path)
        self.assertIn("Canonical form", str(cm.exception))
        self.assertIn("Averted", str(cm.exception))


class TestTokenCost(unittest.TestCase):
    def test_est_tokens_ceil(self):
        self.assertEqual(dr.est_tokens(""), 0)
        self.assertEqual(dr.est_tokens("abcd"), 1)
        self.assertEqual(dr.est_tokens("abcde"), 2)

    def test_token_cost_parts_and_total(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        r = tmp.name
        _write(r, "skills/a/SKILL.md", "---\nname: a\n---\nbody ignored\n")
        _write(r, "skills/using-superpowers/SKILL.md", "X" * 40)
        _write(r, "hooks/hooks.json", "Y" * 20)
        rows, total_chars, total_tokens = dr.token_cost(r)
        labels = [row[0] for row in rows]
        self.assertEqual(len(rows), 3)
        self.assertIn("hooks/hooks.json", labels)
        # frontmatter of a/SKILL.md is exactly "name: a" (7 chars)
        self.assertEqual(rows[0][1], 7)
        self.assertEqual(rows[1][1], 40)
        self.assertEqual(rows[2][1], 20)
        self.assertEqual(total_chars, 67)
        self.assertEqual(total_tokens, dr.est_tokens("Z" * 67))


class TestMainCli(FixtureRepo):
    def _main(self, argv):
        buf_out, buf_err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            rc = dr.main(argv)
        return rc, buf_out.getvalue(), buf_err.getvalue()

    def test_main_reports_and_exits_zero(self):
        _write(self.repo, "MODS.md",
               "| Date | File | Why |\n|---|---|---|\n"
               "| 2026-07-14 | skills/foo/SKILL.md, skills/bar/SKILL.md | test |\n")
        rc, out, _ = self._main(["--repo", self.repo, "--base", self.base])
        self.assertEqual(rc, 0)
        self.assertIn("ALWAYS-ON TOKEN COST", out)
        self.assertIn("BOTH CHANGED", out)

    def test_check_exits_one_on_unledgered(self):
        _write(self.repo, "MODS.md", "| Date | File | Why |\n|---|---|---|\n")
        rc, out, _ = self._main(["--repo", self.repo, "--base", self.base, "--check"])
        self.assertEqual(rc, 1)
        self.assertIn("UNLEDGERED", out)

    def test_garbage_base_source_exits_three(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        rc, _, err = self._main(["--repo", tmp.name])  # no UPSTREAM.md marker
        self.assertEqual(rc, 3)
        self.assertIn("Canonical form", err)


if __name__ == "__main__":
    unittest.main()
