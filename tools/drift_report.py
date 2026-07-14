#!/usr/bin/env python3
"""tools/drift_report.py — the sync seam's eyes for the superpowers-extended-cc fork.

A REPORTER, not a gate. Given a base ref (default: the fork point recorded in
UPSTREAM.md), it answers three questions the curated-sync ritual (UPSTREAM.md §2)
needs before a merge:

  1. Three-way drift — which files moved upstream only, ours only, or BOTH
     (both = reconcile by hand).
  2. Ledger cross-check — every edit WE made to an inherited (upstream-owned)
     file must have a MODS.md row, or the next sync would misattribute it.
  3. Always-on token cost — the estimated per-session token weight of the
     content that loads on every conversation (skill frontmatter, the
     using-superpowers bootstrap body, hooks.json).

Exit 0 always (a report never fails a caller), EXCEPT `--check` with >=1
unledgered edit -> exit 1, so it can guard the sync ritual in CI/pre-commit.

GATE CONTRACT on error paths (mirrors ship.sh / lib/upstream.sh): when a
computation is not safely inferable, do nothing, print the canonical correct
form, and state what was averted.

Python3 stdlib only.
"""

import argparse
import math
import os
import re
import subprocess
import sys

# --- last-synced parse (re-implements lib/upstream.sh parse_last_synced) -----

_MARKER = "**Fork point / last synced:**"
_SHA_RE = re.compile(r"[0-9a-f]{40}")


def parse_last_synced(path):
    """Echo the 40-hex sha from the '**Fork point / last synced:**' line of <path>.

    Isolate the marker line by fixed string FIRST, then extract the sha, so a
    stray 40-hex elsewhere in the file cannot masquerade as the sync point.
    Raises ValueError (with the canonical form + what was averted) when no such
    sha is present — a drift range against a garbage base ref is meaningless.
    """
    line = ""
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                if _MARKER in raw:
                    line = raw
                    break
    except OSError:
        line = ""
    m = _SHA_RE.search(line)
    if not m:
        raise ValueError(
            "parse_last_synced: no 40-hex sha on a '%s' line in %s\n"
            "  Canonical form: '%s <40-hex-sha> (<version>, <YYYY-MM-DD>)'\n"
            "  Averted: computing a drift range against an empty/garbage base ref."
            % (_MARKER, path, _MARKER)
        )
    return m.group(0)


# --- git plumbing ------------------------------------------------------------

def _git(repo, *args):
    """Run `git -C <repo> <args>`; return (returncode, stdout, stderr) as text."""
    p = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True, text=True,
    )
    return p.returncode, p.stdout, p.stderr


def _changed(repo, a, b):
    """Set of paths changed in `git diff --name-only a..b` (empty on git error)."""
    rc, out, _ = _git(repo, "diff", "--name-only", "%s..%s" % (a, b))
    if rc != 0:
        return set()
    return {ln.strip() for ln in out.splitlines() if ln.strip()}


def _existed_at(repo, base, path):
    """True iff <path> existed in the tree at <base> (`git cat-file -e base:path`)."""
    rc, _, _ = _git(repo, "cat-file", "-e", "%s:%s" % (base, path))
    return rc == 0


# --- classification ----------------------------------------------------------

class DriftReport:
    """Three-way drift between base..upstream/main and base..HEAD."""

    def __init__(self, upstream_only, ours_only, both):
        self.upstream_only = upstream_only
        self.ours_only = ours_only
        self.both = both


def classify(repo, base):
    """Compute the three drift sets relative to <base>.

    U = files changed base..upstream/main ; O = files changed base..HEAD.
      upstream_only = U - O   (take/adapt/decline; won't touch our edits)
      ours_only     = O - U   (our additive / independent work)
      both          = U & O   (collision — reconcile by hand)
    """
    U = _changed(repo, base, "upstream/main")
    O = _changed(repo, base, "HEAD")
    return DriftReport(
        upstream_only=U - O,
        ours_only=O - U,
        both=U & O,
    )


# --- ledger cross-check ------------------------------------------------------

_UNLEDGERED = (
    "UNLEDGERED EDIT: %s — add a MODS.md row (why + date). "
    "Averted: silent divergence from upstream that the next sync would misattribute."
)


def _ledger_file_cells(repo):
    """The File-column (2nd cell) text of every MODS.md table row (working tree).

    Read from the WORKING TREE, not from git — a just-appended row should silence
    a warning immediately, before it is committed.
    """
    cells = []
    path = os.path.join(repo, "MODS.md")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return cells
    for line in text.splitlines():
        if "|" not in line:
            continue
        # `| Date | File | Why |` -> ['', ' Date ', ' File ', ' Why ', '']
        parts = line.split("|")
        if len(parts) >= 3:
            cells.append(parts[2])
    return cells


def ledger_check(repo, base):
    """Warnings for inherited-file edits (base..HEAD) lacking a MODS.md row.

    An edit is subject to the ledger only if the file EXISTED at <base> (i.e. we
    inherited it from upstream). Brand-new files in additive paths are exempt
    (MODS.md §: new files need no row). A file is ledgered iff its path is a
    substring of some row's File cell (rows may list several comma-separated
    files).
    """
    warnings = []
    cells = _ledger_file_cells(repo)
    for path in sorted(_changed(repo, base, "HEAD")):
        if not _existed_at(repo, base, path):
            continue  # new file — exempt
        if not any(path in cell for cell in cells):
            warnings.append(_UNLEDGERED % path)
    return warnings


# --- token cost estimator ----------------------------------------------------

def est_tokens(text):
    """Estimate tokens as ceil(chars / 4) — the standard ~4 chars/token rule."""
    return math.ceil(len(text) / 4)


def _frontmatter(text):
    """Return the YAML block between the first two `---` lines (excl. delimiters)."""
    m = re.search(r"^---\n(.*?)\n---", text, re.DOTALL)
    return m.group(1) if m else ""


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def token_cost(repo):
    """The three always-on token-cost parts, as (label, chars, tokens) tuples + total.

    (a) sum of every skills/*/SKILL.md YAML frontmatter block,
    (b) full body of skills/using-superpowers/SKILL.md,
    (c) hooks/hooks.json.
    """
    skills_dir = os.path.join(repo, "skills")
    frontmatter_text = ""
    if os.path.isdir(skills_dir):
        for name in sorted(os.listdir(skills_dir)):
            skill_md = os.path.join(skills_dir, name, "SKILL.md")
            if os.path.isfile(skill_md):
                frontmatter_text += _frontmatter(_read(skill_md))

    bootstrap = _read(os.path.join(repo, "skills", "using-superpowers", "SKILL.md"))
    hooks = _read(os.path.join(repo, "hooks", "hooks.json"))

    parts = [
        ("skills/*/SKILL.md frontmatter (all)", frontmatter_text),
        ("skills/using-superpowers/SKILL.md (full body)", bootstrap),
        ("hooks/hooks.json", hooks),
    ]
    rows = [(label, len(t), est_tokens(t)) for label, t in parts]
    total_chars = sum(len(t) for _, t in parts)
    return rows, total_chars, est_tokens("".join(t for _, t in parts))


# --- rendering ---------------------------------------------------------------

def _section(title, paths):
    lines = ["%s (%d)" % (title, len(paths))]
    lines.extend(sorted(paths))
    return "\n".join(lines)


def _render(repo, base):
    """Build the full report text and return (text, n_unledgered)."""
    out = []
    out.append("drift base: %s" % base)
    out.append("")

    rep = classify(repo, base)
    out.append(_section("UPSTREAM ONLY", rep.upstream_only))
    out.append("")
    out.append(_section("OURS ONLY", rep.ours_only))
    out.append("")
    out.append(_section("BOTH CHANGED — reconcile by hand", rep.both))
    out.append("")

    warnings = ledger_check(repo, base)
    out.append("LEDGER CROSS-CHECK (%d)" % len(warnings))
    if warnings:
        out.extend(warnings)
    else:
        out.append("all inherited edits are ledgered in MODS.md")
    out.append("")

    rows, total_chars, total_tokens = token_cost(repo)
    out.append("ALWAYS-ON TOKEN COST (estimator: chars/4, ±20%)")
    for label, chars, tokens in rows:
        out.append("  %-46s %7d chars  ~%6d tok" % (label, chars, tokens))
    out.append("  %-46s %7d chars  ~%6d tok" % ("TOTAL", total_chars, total_tokens))

    return "\n".join(out), len(warnings)


# --- CLI ---------------------------------------------------------------------

def _default_repo():
    # tools/drift_report.py -> tools/ -> repo root
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Three-way upstream/ours drift report + ledger cross-check + token cost."
    )
    ap.add_argument("--base", default=None,
                    help="base sha (default: parse UPSTREAM.md fork-point line)")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any inherited edit is unledgered (else exit 0)")
    ap.add_argument("--repo", default=None,
                    help="fork repo path (default: the repo containing this script)")
    args = ap.parse_args(argv)

    repo = args.repo or _default_repo()

    base = args.base
    if base is None:
        try:
            base = parse_last_synced(os.path.join(repo, "UPSTREAM.md"))
        except ValueError as e:
            # Not safely inferable — refuse to fabricate a report against a
            # garbage base. Canonical form + what was averted already in the msg.
            print(str(e), file=sys.stderr)
            return 3

    text, n_unledgered = _render(repo, base)
    print(text)

    if args.check and n_unledgered > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
