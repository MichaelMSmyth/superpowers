#!/usr/bin/env python3
"""Adequacy tests for tools/doctor.py — from the mutation flip-test worklist."""

import importlib.util
import json
import os
import stat
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "doctor", os.path.join(TOOLS, "doctor.py"))
doc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doc)


def _write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def _skill(root, name, description, body=""):
    _write(root, "skills/%s/SKILL.md" % name,
           "---\nname: %s\ndescription: %s\n---\n%s" % (name, description, body))


class TestSeverities(unittest.TestCase):
    def test_d1_missing_frontmatter_is_error(self):
        """Kills the D1 severity-string mutant: assert severity, not just id."""
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        _write(tmp.name, "skills/broken/SKILL.md", "no frontmatter here\n")
        findings = doc.scan(tmp.name)
        d1 = [f for f in findings if f.id == "D1"]
        self.assertEqual(len(d1), 1)
        self.assertEqual(d1[0].severity, "ERROR")

    def test_clean_root_zero_findings(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        _skill(tmp.name, "alpha", "does one thing well for testing purposes only")
        self.assertEqual(doc.scan(tmp.name), [])


class TestD5CollisionNaming(unittest.TestCase):
    def test_collision_message_names_the_sibling(self):
        """Kills the `!=` -> `==` mutant in the others-list: each colliding
        skill's message must name the OTHER skill, not itself."""
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        shared = "use when starting any new conversation about databases quickly"
        _skill(tmp.name, "aaa", shared + " (a)")
        _skill(tmp.name, "bbb", shared + " (b)")
        d5 = [f for f in doc.scan(tmp.name) if f.id == "D5"]
        self.assertEqual(len(d5), 2)
        by_path = {f.path: f.message for f in d5}
        aaa_msg = by_path["skills/aaa/SKILL.md"]
        bbb_msg = by_path["skills/bbb/SKILL.md"]
        self.assertIn("collide with: bbb", aaa_msg)
        self.assertIn("collide with: aaa", bbb_msg)


class TestD3LinkSkips(unittest.TestCase):
    def test_mailto_tel_and_anchor_links_not_flagged(self):
        """Kills the skip-guard `or` -> `and` mutant: mailto:/tel:/#anchor
        targets must produce zero D3 findings."""
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        _skill(tmp.name, "alpha", "unique description for the link-skip test case",
               body="[m](mailto:a@b.c) [t](tel:+123) [a](#section)\n")
        d3 = [f for f in doc.scan(tmp.name) if f.id == "D3"]
        self.assertEqual(d3, [])

    def test_dead_relative_link_still_flagged(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        _skill(tmp.name, "alpha", "unique description for the dead-link test case",
               body="[dead](does/not/exist.md)\n")
        d3 = [f for f in doc.scan(tmp.name) if f.id == "D3"]
        self.assertEqual(len(d3), 1)


class TestResolveHookFile(unittest.TestCase):
    def test_non_string_and_empty_commands_return_none_without_raising(self):
        """Kills the guard `or` -> `and` mutant: None.strip() would raise."""
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        for bad in (None, 42, "", "   "):
            self.assertIsNone(doc._resolve_hook_file(bad, tmp.name))

    def test_bare_command_name_returns_none(self):
        self.assertIsNone(doc._resolve_hook_file("bash", "/repo"))

    def test_plugin_root_var_resolved(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        got = doc._resolve_hook_file('"${CLAUDE_PLUGIN_ROOT}/hooks/x"', tmp.name)
        self.assertEqual(got, os.path.normpath(os.path.join(tmp.name, "hooks/x")))


class TestD6Hooks(unittest.TestCase):
    def _root_with_hook(self, make_file, executable):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        hooks = {"hooks": [{"type": "command",
                            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/h.sh"}]}
        _write(tmp.name, "hooks/hooks.json", json.dumps(hooks))
        if make_file:
            p = _write(tmp.name, "hooks/h.sh", "#!/bin/sh\n")
            if executable:
                os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        return tmp.name

    def test_missing_hook_file_is_d6_error(self):
        findings = doc.scan(self._root_with_hook(make_file=False, executable=False))
        d6 = [f for f in findings if f.id == "D6"]
        self.assertEqual(len(d6), 1)
        self.assertEqual(d6[0].severity, "ERROR")
        self.assertIn("missing", d6[0].message)

    def test_not_executable_hook_file_is_d6_error(self):
        """Kills the not-executable-branch id/message mutants."""
        findings = doc.scan(self._root_with_hook(make_file=True, executable=False))
        d6 = [f for f in findings if f.id == "D6"]
        self.assertEqual(len(d6), 1)
        self.assertIn("not executable", d6[0].message)
        self.assertIn("chmod +x", d6[0].message)

    def test_executable_hook_file_clean(self):
        findings = doc.scan(self._root_with_hook(make_file=True, executable=True))
        self.assertEqual([f for f in findings if f.id == "D6"], [])


if __name__ == "__main__":
    unittest.main()
