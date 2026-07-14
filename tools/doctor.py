#!/usr/bin/env python3
"""tools/doctor.py — a fleet linter for the superpowers-extended-cc fork.

A REPORTER, not a gate. It walks the plugin's authored surface — every
skills/*/SKILL.md plus hooks/hooks.json — and emits one finding line per
defect, each carrying its own canonical fix (the GATE CONTRACT shared with
ship.sh / drift_report.py: when a defect is found, name it and hand back the
exact repair).

Checks:
  D1 ERROR  frontmatter missing/unparseable, or missing name/description
  D2 ERROR  frontmatter name != containing directory name
  D3 WARN   a relative markdown link target resolves nowhere (skill dir + root)
  D4 WARN   SKILL.md exceeds MAX_LINES lines
  D5 WARN   two skills whose descriptions share identical first 8 words
  D6 ERROR  hooks.json is invalid JSON, or a referenced hook file is
            missing / not executable

Output: one line per finding, then a SUMMARY line. Exit 0 by default; with
--strict, exit 1 when there is >=1 ERROR. Public API for tests: scan(root)
returns a list of Finding(id, severity, path, message) namedtuples.

The hooks.json parser accepts BOTH the fork's real schema
(`{"hooks": {"<Event>": [{"matcher": ..., "hooks": [{"type", "command"}]}]}}`)
and the flat test-fixture shape (`{"hooks": [{"type", "command"}]}`).

Python3 stdlib only.
"""

import argparse
import json
import os
import re
import shlex
import sys
from collections import namedtuple

Finding = namedtuple("Finding", ["id", "severity", "path", "message"])

MAX_LINES = 500
FIRST_N_WORDS = 8
# The harness expands ${CLAUDE_PLUGIN_ROOT} to the installed plugin root, which
# is the repo root; resolve it the same way so hook paths can be checked offline.
PLUGIN_ROOT_VARS = ("${CLAUDE_PLUGIN_ROOT}", "$CLAUDE_PLUGIN_ROOT")
_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
_FM_KV_RE = re.compile(r"^([A-Za-z0-9_-]+):\s*(.*)$")


def _read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _rel(root, path):
    try:
        return os.path.relpath(path, root)
    except ValueError:
        return path


def _parse_frontmatter(text):
    """Return a dict of the first `---`-delimited block, or None if absent.

    No YAML dependency: the block is scanned line by line and every simple
    `key: value` pair is captured (surrounding quotes stripped). A value's own
    colons are preserved (only the first colon splits key from value).
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return None
    fm = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        m = _FM_KV_RE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("\"", "'"):
            val = val[1:-1]
        fm[key] = val
    return fm


def _gather_skills(root):
    """Return sorted list of (dirname, skill_dir, skill_md_path) for each
    skills/<dir>/SKILL.md that exists."""
    out = []
    skills_dir = os.path.join(root, "skills")
    if not os.path.isdir(skills_dir):
        return out
    for entry in sorted(os.listdir(skills_dir)):
        sdir = os.path.join(skills_dir, entry)
        if not os.path.isdir(sdir):
            continue
        md = os.path.join(sdir, "SKILL.md")
        if os.path.isfile(md):
            out.append((entry, sdir, md))
    return out


def _link_targets(text):
    """Yield unique markdown link targets in first-seen order."""
    seen = set()
    for m in _LINK_RE.finditer(text):
        target = m.group(1).strip()
        if target and target not in seen:
            seen.add(target)
            yield target


def _first_words(description, n=FIRST_N_WORDS):
    return tuple(re.findall(r"\S+", description.lower())[:n])


def _iter_hook_commands(data):
    """Yield command strings from either the real (event-keyed dict) schema or
    the flat-list fixture schema."""
    hooks = data.get("hooks") if isinstance(data, dict) else None
    if isinstance(hooks, list):
        groups = [hooks]
    elif isinstance(hooks, dict):
        groups = [g for g in hooks.values() if isinstance(g, list)]
    else:
        return
    for group in groups:
        for entry in group:
            if not isinstance(entry, dict):
                continue
            inner = entry.get("hooks")
            if isinstance(inner, list):
                for h in inner:
                    if isinstance(h, dict) and isinstance(h.get("command"), str):
                        yield h["command"]
            elif isinstance(entry.get("command"), str):
                yield entry["command"]


def _resolve_hook_file(command, root):
    """Extract the referenced script path from a hook command and resolve it
    against `root`. Returns an absolute path, or None when the command has no
    checkable repo file (bare executable name, empty, or unparseable)."""
    if not isinstance(command, str) or not command.strip():
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    if not tokens:
        return None
    tok = tokens[0]
    for var in PLUGIN_ROOT_VARS:
        tok = tok.replace(var, root)
    tok = os.path.expanduser(tok)
    if "/" not in tok and os.sep not in tok:
        return None  # bare command name (e.g. "bash"): not a repo hook file
    if not os.path.isabs(tok):
        tok = os.path.join(root, tok)
    return os.path.normpath(tok)


def scan(root):
    """Lint the fleet rooted at `root`. Returns a list of Finding namedtuples."""
    findings = []
    skills = _gather_skills(root)

    described = []  # (dirname, relmd, first_words) for D5

    for entry, sdir, md in skills:
        relmd = _rel(root, md)
        text = _read(md)
        fm = _parse_frontmatter(text)

        # D1 — frontmatter presence + required keys
        if fm is None:
            findings.append(Finding(
                "D1", "ERROR", relmd,
                "frontmatter missing or unparseable; fix: begin the file with a "
                "'---' fenced block containing 'name:' and 'description:'"))
        else:
            missing = [k for k in ("name", "description") if not fm.get(k)]
            if missing:
                findings.append(Finding(
                    "D1", "ERROR", relmd,
                    "frontmatter missing required key(s): %s; fix: add '%s: <value>' "
                    "to the '---' block" % (", ".join(missing), missing[0])))
            name = fm.get("name")
            # D2 — name must match containing directory
            if name and name != entry:
                findings.append(Finding(
                    "D2", "ERROR", relmd,
                    "frontmatter name '%s' != directory '%s'; fix: set 'name: %s' "
                    "or rename the directory to '%s'" % (name, entry, entry, name)))
            if fm.get("description"):
                described.append((entry, relmd, _first_words(fm["description"])))

        # D3 — relative markdown links must resolve against skill dir or root
        for target in _link_targets(text):
            if "://" in target:
                continue
            path_part = target.split("#", 1)[0].strip()
            path_part = re.split(r"\s+[\"']", path_part)[0]  # drop optional link title
            if not path_part or path_part.startswith(("mailto:", "tel:")):
                continue
            cand_skill = os.path.normpath(os.path.join(sdir, path_part))
            cand_root = os.path.normpath(os.path.join(root, path_part))
            if os.path.exists(cand_skill) or os.path.exists(cand_root):
                continue
            findings.append(Finding(
                "D3", "WARN", relmd,
                "relative link target '%s' not found (checked skill dir and repo "
                "root); fix: correct the path or add the missing file" % target))

        # D4 — length budget
        nlines = len(text.splitlines())
        if nlines > MAX_LINES:
            findings.append(Finding(
                "D4", "WARN", relmd,
                "SKILL.md is %d lines (limit %d); fix: move supporting detail into "
                "linked reference files to bring it under %d"
                % (nlines, MAX_LINES, MAX_LINES)))

    # D5 — descriptions sharing identical first 8 words
    groups = {}
    for entry, relmd, words in described:
        groups.setdefault(words, []).append((entry, relmd))
    for words, members in sorted(groups.items()):
        if len(members) < 2:
            continue
        names = ", ".join(m[0] for m in members)
        phrase = " ".join(words)
        # Report on each colliding skill so no member is silently omitted.
        for entry, relmd in members:
            others = ", ".join(m[0] for m in members if m[0] != entry)
            findings.append(Finding(
                "D5", "WARN", relmd,
                "description's first %d words ('%s') collide with: %s; fix: reword "
                "the opening of one description so retrieval can disambiguate "
                "(colliding set: %s)" % (FIRST_N_WORDS, phrase, others, names)))

    # D6 — hooks.json validity + referenced hook files
    hooks_json = os.path.join(root, "hooks", "hooks.json")
    if os.path.isfile(hooks_json):
        relhj = _rel(root, hooks_json)
        try:
            data = json.loads(_read(hooks_json))
        except ValueError as exc:
            findings.append(Finding(
                "D6", "ERROR", relhj,
                "invalid JSON (%s); fix: repair hooks.json so it parses" % exc))
            data = None
        if data is not None:
            for command in _iter_hook_commands(data):
                hook_file = _resolve_hook_file(command, root)
                if hook_file is None:
                    continue
                relhf = _rel(root, hook_file)
                if not os.path.exists(hook_file):
                    findings.append(Finding(
                        "D6", "ERROR", relhj,
                        "referenced hook file '%s' (command %r) is missing; fix: "
                        "create it or correct the command path" % (relhf, command)))
                elif not os.access(hook_file, os.X_OK):
                    findings.append(Finding(
                        "D6", "ERROR", relhj,
                        "referenced hook file '%s' (command %r) is not executable; "
                        "fix: run 'chmod +x %s'" % (relhf, command, relhf)))

    return findings


def _format(f):
    return "%s %s %s: %s" % (f.id, f.severity, f.path, f.message)


def _default_root():
    # tools/doctor.py -> repo root is the parent of tools/.
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Fleet linter for skills/*/SKILL.md + hooks/hooks.json.")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when there is at least one ERROR finding")
    parser.add_argument("--root", default=None,
                        help="repo root to scan (default: the repo containing this script)")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root) if args.root else _default_root()
    findings = scan(root)
    for f in findings:
        print(_format(f))

    n_err = sum(1 for f in findings if f.severity == "ERROR")
    n_warn = sum(1 for f in findings if f.severity == "WARN")
    n_skills = len(_gather_skills(root))
    print("SUMMARY: %d errors, %d warnings, %d skills scanned"
          % (n_err, n_warn, n_skills))

    if args.strict and n_err > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
