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

    # (6) --specs pointed at a nonexistent dir -> no crash, silent skip
    def test_nonexistent_dir_no_crash(self):
        self.assertEqual(doctor.scan_specs(["/no/such/dir/really/xyz"]), [])
        rc, out = _run_main(["--specs", "/no/such/dir/really/xyz",
                             "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertNotIn("D7", out)

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


class TestSpecAssayIntegration(unittest.TestCase):
    def test_main_specs_flag_emits_warn_never_fails(self):
        table = HEADER + "| Adopt X | imported | reuse | lock-in | swap to Y | TBD |\n"
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        d, _ = _write_spec(tmp.name, "spec.md", table)
        # --strict must still exit 0: D7 is WARN, and strict fails only on ERROR.
        rc, out = _run_main(["--specs", d, "--strict", "--root", REPO])
        self.assertEqual(rc, 0)
        self.assertIn("D7 WARN", out)


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
