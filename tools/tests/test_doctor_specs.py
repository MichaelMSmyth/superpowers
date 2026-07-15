#!/usr/bin/env python3
"""Tests for the opt-in spec assumption-assay lint (D7) in tools/doctor.py.

Run: python3 -m unittest discover -s tools/tests -p 'test_doctor*.py'

The assay (spec §2.11) flags imported/assumed rows of a Load-bearing choices
table whose buys/costs/inversion/evidence cells are empty, placeholder junk, or
(for evidence) carry no link/path. It is WARN-only and off unless --specs is
passed, so these tests also pin the regression guarantee: doctor without --specs
behaves exactly as before.
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import doctor  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

HEADER = ("| Choice | Provenance | Buys | Costs | Inversion | Evidence link |\n"
          "|--------|-----------|------|-------|-----------|---------------|\n")


def _write_spec(root, name, body):
    d = os.path.join(root, "docs", "specs")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return d, path


def _spec_dir(body, name="spec.md"):
    """Make a tempdir holding docs/specs/<name> with `body`; return (specs_dir,
    cleanup-registered tempdir object)."""
    tmp = tempfile.TemporaryDirectory()
    d, _ = _write_spec(tmp.name, name, body)
    return d, tmp


def _run_main(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = doctor.main(argv)
    return rc, buf.getvalue()


class TestSpecAssay(unittest.TestCase):
    def _d7(self, table_body, name="spec.md"):
        d, tmp = _spec_dir(table_body, name)
        self.addCleanup(tmp.cleanup)
        return [f for f in doctor.scan_specs([d]) if f.id == "D7"]

    # (1) assumed row, empty inversion cell -> flagged, names the cell
    def test_assumed_empty_inversion_flagged_and_named(self):
        table = HEADER + ("| Use Redis | assumed | fast cache | infra cost |   "
                          "| [bench](docs/bench.md) |\n")
        d7 = self._d7(table)
        self.assertEqual(len(d7), 1)
        self.assertIn("inversion", d7[0].message)
        self.assertIn("Use Redis", d7[0].message)
        self.assertEqual(d7[0].severity, "WARN")
        # only the empty cell is named — the filled ones are not
        self.assertNotIn("buys", d7[0].message)

    # (2) imported row, evidence cell 'TBD' -> flagged
    def test_imported_evidence_tbd_flagged(self):
        table = HEADER + "| Adopt X | imported | reuse | lock-in | swap to Y | TBD |\n"
        d7 = self._d7(table)
        self.assertEqual(len(d7), 1)
        self.assertIn("evidence", d7[0].message)

    # (3) complete imported row with a markdown link -> clean
    def test_complete_imported_row_clean(self):
        table = HEADER + ("| Adopt X | imported | reuse | lock-in | swap to Y "
                          "| [ref](https://example.com/x) |\n")
        self.assertEqual(self._d7(table), [])

    # (4) derived row with every cell empty -> NOT flagged (exempt)
    def test_derived_empty_cells_not_flagged(self):
        table = HEADER + "| Our own call | derived |   |   |   |   |\n"
        self.assertEqual(self._d7(table), [])

    # (5) spec file with no Load-bearing choices table -> silent skip
    def test_no_table_silent_skip(self):
        body = ("# A spec that predates the convention\n\nProse only, and an "
                "unrelated table:\n\n| Fruit | Colour |\n|-------|--------|\n"
                "| Apple | Red |\n")
        self.assertEqual(self._d7(body), [])

    # (6) --specs pointed at a nonexistent dir -> no crash, silent skip.
    # The D7 NOTE still prints (specs mode ran); only D7 *findings* are absent.
    def test_nonexistent_dir_no_crash(self):
        self.assertEqual(doctor.scan_specs(["/no/such/dir/really/xyz"]), [])
        rc, out = _run_main(["--specs", "/no/such/dir/really/xyz",
                             "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertNotIn("D7 WARN", out)
        self.assertIn("D7 NOTE", out)

    # Extra: evidence cell with plain prose (no link/path) -> flagged 'no link'
    def test_imported_evidence_no_link_flagged(self):
        table = HEADER + ("| Adopt X | imported | reuse | lock-in | swap to Y "
                          "| see the benchmark |\n")
        d7 = self._d7(table)
        self.assertEqual(len(d7), 1)
        self.assertIn("evidence", d7[0].message)

    # Extra: evidence cell that is a bare repo path (has '/') -> accepted
    def test_imported_evidence_repo_path_clean(self):
        table = HEADER + ("| Adopt X | imported | reuse | lock-in | swap to Y "
                          "| src/cache/redis.py |\n")
        self.assertEqual(self._d7(table), [])

    # Extra: assumed row is scrutinised even when the header omits inversion
    def test_missing_inversion_column_flags_assumed_row(self):
        header = ("| Choice | Provenance | Buys | Costs | Evidence link |\n"
                  "|--------|-----------|------|-------|---------------|\n")
        table = header + ("| Adopt X | assumed | reuse | lock-in "
                          "| [ref](docs/x.md) |\n")
        d7 = self._d7(table)
        self.assertEqual(len(d7), 1)
        self.assertIn("inversion", d7[0].message)

    # Fence tracking (the pair): the SAME table with a placeholder inversion cell
    # is exempt inside a ``` fence (it's a documentation example — the
    # brainstorming skill instructs authors to write this exact format) but
    # flagged unfenced. The pair isolates fence tracking from every other rule.
    def test_fence_tracking_example_exempt_but_real_linted(self):
        table = HEADER + ("| Use Redis | assumed | fast cache | infra cost |   "
                          "| [bench](docs/bench.md) |\n")
        fenced = "# Documented example\n\n```\n" + table + "```\n"
        self.assertEqual(self._d7(fenced, name="fenced.md"), [])
        d7 = self._d7(table, name="real.md")
        self.assertEqual(len(d7), 1)
        self.assertIn("inversion", d7[0].message)

    # A cell holding only U+2212 (minus sign) is a placeholder, not content.
    def test_unicode_minus_inversion_flagged(self):
        table = HEADER + ("| Use Redis | assumed | fast cache | infra cost "
                          "| − | [bench](docs/bench.md) |\n")
        d7 = self._d7(table)
        self.assertEqual(len(d7), 1)
        self.assertIn("inversion", d7[0].message)

    # --specs pointed at a FILE (not a dir): no findings, and a stderr note so
    # the 0-findings result is never misread as "clean".
    def test_specs_file_path_warns_stderr_and_no_findings(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        fpath = os.path.join(tmp.name, "notadir.md")
        with open(fpath, "w", encoding="utf-8") as fh:
            fh.write("# a file, not a directory\n")
        errbuf = io.StringIO()
        with contextlib.redirect_stderr(errbuf):
            findings = doctor.scan_specs([fpath])
        self.assertEqual(findings, [])
        err = errbuf.getvalue()
        self.assertIn("doctor: --specs", err)
        self.assertIn("is not a directory", err)
        self.assertIn("notadir.md", err)


class TestSpecAssayIntegration(unittest.TestCase):
    def test_main_specs_flag_emits_warn_never_fails(self):
        table = HEADER + "| Adopt X | imported | reuse | lock-in | swap to Y | TBD |\n"
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        d, _ = _write_spec(tmp.name, "spec.md", table)
        # --strict must still exit 0: D7 is WARN, and strict fails only on ERROR.
        rc, out = _run_main(["--specs", d, "--strict", "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertIn("D7 WARN", out)

    # Honest labeling: specs mode always prints the D7 NOTE (form-check caveat).
    def test_specs_mode_prints_d7_note(self):
        table = HEADER + ("| Adopt X | imported | reuse | lock-in | swap to Y "
                          "| [r](docs/x.md) |\n")
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        d, _ = _write_spec(tmp.name, "spec.md", table)
        rc, out = _run_main(["--specs", d, "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertIn("D7 NOTE", out)
        self.assertIn("FORM check", out)
        self.assertIn("does not verify substance", out)

    # ...and no-specs mode must NOT print it (nothing about D7 at all).
    def test_no_specs_mode_omits_d7_note(self):
        rc, out = _run_main(["--root", REPO])
        self.assertEqual(rc, 0)
        self.assertNotIn("D7 NOTE", out)
        self.assertNotIn("D7", out)


class TestBaselineUnchanged(unittest.TestCase):
    """Regression guard: without --specs the fork behaves exactly as before."""

    def test_scan_never_emits_d7(self):
        self.assertEqual([f for f in doctor.scan(REPO) if f.id == "D7"], [])

    def test_real_repo_zero_errors(self):
        errs = [f for f in doctor.scan(REPO) if f.severity == "ERROR"]
        self.assertEqual(errs, [], "baseline must stay 0 errors; got %r" % errs)

    def test_main_without_specs_exit_zero_no_d7(self):
        rc, out = _run_main(["--strict", "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertNotIn("D7", out)


if __name__ == "__main__":
    unittest.main()
