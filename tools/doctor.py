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
  D7 WARN   (opt-in via --specs) a Load-bearing choices table row tagged
            imported/assumed has an empty/placeholder buys/costs/inversion/
            evidence cell, or an evidence cell carrying no link/path
            (spec §2.11 assumption assay; off unless --specs is passed)

Output: one line per finding, then a SUMMARY line. Exit 0 by default; with
--strict, exit 1 when there is >=1 ERROR (D7 is WARN, so the assay never fails
the run — a soft gate). Public API for tests: scan(root) runs the always-on
fleet lint (D1-D6); scan_specs(dirs) runs the opt-in spec assay (D7); both
return a list of Finding(id, severity, path, message) namedtuples.

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


# --- Spec assumption-assay lint (D7) — opt-in via --specs ------------------
# Default spec dirs are resolved against CWD, deliberately independent of
# --root: the governed design specs may live in a parent repo, not beside this
# script. Missing dirs are skipped silently.
DEFAULT_SPEC_DIRS = (os.path.join("docs", "specs"),
                     os.path.join("docs", "superpowers", "specs"))
_TABLE_SEP_CELL_RE = re.compile(r"^:?-+:?$")
_MD_LINK_RE = re.compile(r"\[[^\]]*\]\([^)]+\)")
# Cell values that count as unfilled — the assay demands real justification,
# not a dash or a "TBD" standing in for one.
_PLACEHOLDER_CELLS = frozenset({"-", "–", "—", "tbd", "?"})
# Provenance substrings whose rows the assay scrutinises (derived is exempt).
_ASSAY_PROVENANCE = ("imported", "assumed")


def _rel_cwd(path):
    """Path relative to CWD when possible (spec dirs are CWD-relative), else
    the absolute path."""
    try:
        return os.path.relpath(path, os.getcwd())
    except ValueError:
        return path


def _split_table_row(line):
    """Split one markdown table line into stripped cell strings, dropping the
    optional leading/trailing border pipes."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _is_separator_row(cells):
    """True when every cell is a GFM header separator (`---`, `:--`, `:-:`)."""
    return bool(cells) and all(_TABLE_SEP_CELL_RE.match(c) for c in cells)


def _iter_md_tables(text):
    """Yield (header_cells, [(lineno, row_cells), ...]) for each GFM table — a
    header row immediately followed by a separator row — in `text`. Lines that
    merely contain a stray pipe are not mistaken for tables (a separator must
    follow the header)."""
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if ("|" in line and line.strip() and i + 1 < n and "|" in lines[i + 1]
                and _is_separator_row(_split_table_row(lines[i + 1]))):
            header = _split_table_row(line)
            rows = []
            j = i + 2
            while j < n and "|" in lines[j] and lines[j].strip():
                rows.append((j + 1, _split_table_row(lines[j])))
                j += 1
            yield header, rows
            i = j
            continue
        i += 1


def _col_index(header_cells, keyword):
    """Index of the first header cell containing `keyword` (case-insensitive),
    or None when no column matches."""
    for idx, h in enumerate(header_cells):
        if keyword in h.lower():
            return idx
    return None


def _cell(row_cells, idx):
    """The stripped cell at `idx`, or "" when the column is absent/short."""
    return row_cells[idx].strip() if idx is not None and idx < len(row_cells) else ""


def _is_unfilled(cell):
    """True when a cell is empty or holds placeholder junk — no real content."""
    c = cell.strip()
    return not c or c.lower() in _PLACEHOLDER_CELLS


def _lacks_evidence_link(cell):
    """True when a non-empty evidence cell carries no reference: no markdown
    link, no URL, and no path-like token (a `/`)."""
    c = cell.strip()
    if _MD_LINK_RE.search(c) or "://" in c:
        return False
    return "/" not in c


def _lint_spec_file(path):
    """Assay one spec file's Load-bearing choices table (D7). See scan_specs
    for the WHY. Returns Finding namedtuples (id 'D7', severity WARN); an
    unreadable file yields none (soft gates never block)."""
    findings = []
    try:
        text = _read(path)
    except OSError:
        return findings
    rel = _rel_cwd(path)
    for header, rows in _iter_md_tables(text):
        choice_i = _col_index(header, "choice")
        prov_i = _col_index(header, "provenance")
        if choice_i is None or prov_i is None:
            continue  # not a Load-bearing choices table — skip silently
        buys_i = _col_index(header, "buys")
        costs_i = _col_index(header, "cost")
        inv_i = _col_index(header, "inversion")
        ev_i = _col_index(header, "evidence")
        for lineno, row in rows:
            if not any(tag in _cell(row, prov_i).lower() for tag in _ASSAY_PROVENANCE):
                continue  # derived (or untagged) rows are exempt
            failed = []
            if _is_unfilled(_cell(row, buys_i)):
                failed.append("buys")
            if _is_unfilled(_cell(row, costs_i)):
                failed.append("costs")
            if _is_unfilled(_cell(row, inv_i)):
                failed.append("inversion")
            ev = _cell(row, ev_i)
            if _is_unfilled(ev):
                failed.append("evidence")
            elif _lacks_evidence_link(ev):
                failed.append("evidence(no link/path)")
            if not failed:
                continue
            choice = _cell(row, choice_i) or "(unnamed choice)"
            tag = _cell(row, prov_i)
            findings.append(Finding(
                "D7", "WARN", rel,
                "load-bearing choice '%s' (line %d) is tagged '%s' but cell(s) [%s] "
                "are empty/placeholder or lack an evidence link; fix: fill each with a "
                "concrete justification (evidence must cite a [text](link), a URL, or a "
                "repo path) or retag the row 'derived' if it rests on the project's own "
                "constraints" % (choice, lineno, tag, ", ".join(failed))))
    return findings


def scan_specs(dirs):
    """Assumption assay (spec §2.11) — the mechanical half, rung 3 of the
    enforcement ladder. An imported/assumed load-bearing choice with an empty
    buys/costs/inversion/evidence cell (or an evidence cell with no link) is
    UNRATIFIED intent smuggled into a design: a claim of grounding with no
    turnstile behind it. Prose exhortations to self-check measurably fail — so
    this lints the convention mechanically instead of trusting the author to.

    WARN-only and opt-in (--specs): the convention is new and older specs
    legitimately predate it, so a file carrying no Load-bearing choices table is
    skipped silently rather than nagged. Derived rows are exempt — their
    grounding is the project's own constraints. Returns a flat list of Finding
    namedtuples (all id 'D7', severity WARN); never raises on a missing dir or
    unreadable file (soft gates never block)."""
    md_files = []
    for d in dirs:
        ad = os.path.abspath(d)
        if not os.path.isdir(ad):
            continue  # non-existent spec dir: silent skip
        for dirpath, dirnames, filenames in os.walk(ad):
            dirnames.sort()
            for fn in filenames:
                if fn.endswith(".md"):
                    md_files.append(os.path.join(dirpath, fn))
    findings = []
    for path in sorted(md_files):
        findings.extend(_lint_spec_file(path))
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
    parser.add_argument(
        "--specs", nargs="*", default=None, metavar="DIR",
        help="also lint Load-bearing choices tables (§2.11 assumption assay) in "
             "spec markdown under each DIR; with no DIR, defaults to ./docs/specs "
             "and ./docs/superpowers/specs (CWD-relative; missing dirs skipped). "
             "Soft: emits WARN findings only, never fails the run.")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root) if args.root else _default_root()
    findings = scan(root)
    if args.specs is not None:
        spec_dirs = args.specs if args.specs else list(DEFAULT_SPEC_DIRS)
        findings = findings + scan_specs(spec_dirs)
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
