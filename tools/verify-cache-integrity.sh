#!/usr/bin/env bash
# tools/verify-cache-integrity.sh — cache-integrity SWEEP, run from the CLONE (rung 5).
#
# WHY THIS EXISTS / THE DESIGN LAW (F0 redesign per C2 red-team, 2026-07-15):
#   An integrity check that runs INSIDE the plugin cache cannot attest that cache — a
#   cache-writer deletes the checker in the same write, and comparing to clone HEAD
#   cries wolf on every honest dev cycle (the cache legitimately lags HEAD between a
#   ship and the next restart). The round-1 SessionStart-in-the-cache design was PULLED
#   for exactly this. So this checker fixes all three defects:
#     (1) runs from the CLONE, a LESS-EXPOSED vantage than the cache. HONEST SCOPE (no
#         overclaim): running here raises the bar against a CACHE-SCOPED writer, against
#         ACCIDENTAL divergence (the stale-cache reality of the edit-test loop), against
#         SUPPLY-CHAIN-INTO-CACHE poison, and against DORMANT/NAIVE poison caught before
#         it executes. It is NOT a defense against a live SAME-UID attacker: an adversary
#         running as this user, in a session, has our privileges and can equally edit this
#         clone script or the crontab. So this is DETECTION FROM A LESS-EXPOSED VANTAGE,
#         NOT PREVENTION — and the clone is not a "trusted location the writer can't touch".
#     (2) compares each cache dir to the clone AT THE COMMIT THAT SHIPPED that version
#         (not HEAD) — which kills the stale-cache false-positive class entirely; and
#     (3) makes a couldn't-verify state VISIBLE, never silent — no false comfort.
#
#   WHAT "VERIFIED" MEANS — and does not: VERIFIED asserts the cache is BYTE-UNCHANGED
#   since the commit that shipped it — NOT that it is "safe". A commit poisoned at or
#   before ship verifies clean here; guarding THAT is the sync-review path (F1/F4), not
#   this sweep.
#
# SURFACES COVERED: the FULL governed tree. Every path in the shipped commit is compared,
#   and every regular file AND SYMLINK in the cache dir is accounted for (modified /
#   type-changed / missing / extra). Governed symlinks (git mode 120000, e.g.
#   AGENTS.md -> CLAUDE.md, whose blob content IS the target string) are compared by
#   readlink-vs-blob, not by hash — sha256sum follows links, so type is checked before any
#   hash. The ONLY entries excluded are genuine build artifacts by EXACT extension
#   (*.pyc / *.pyo) AND only when they are regular files — never by directory subtree, and
#   never a symlink, so an injected NON-bytecode file under __pycache__/ (e.g. a payload
#   .sh) or a link masquerading as evil.pyc IS still flagged. (Round-1 filtered to
#   SKILL.md|*.sh and excluded the whole __pycache__/ subtree — both were findings: the
#   first left reference bodies, .js, commands/, agents/ and manifests unattested; the
#   second reported a __pycache__ payload as VERIFIED. The `find -type f` walk skipping
#   symlinks was a third: it cried false DIVERGED "(missing)" on the correct AGENTS.md
#   link, 2026-07-15.)
#
# RUNG 5, AND NOT REAL-TIME: this is a periodic cron sweep. A session tampered with
#   between two sweeps runs BEFORE the next sweep catches it — that residual is
#   ACCEPTED. The guarantee here is periodic detection from a trusted vantage, not
#   prevention. (Real-time would re-introduce the "how does the cache know the clone
#   path" fragility this redesign exists to avoid.)
#
# CRON-SAFE / FAIL-OPEN AS A PROCESS: every fallible command is guarded; an internal
#   error degrades to a visible COULD-NOT-VERIFY rather than crashing the sweep. The
#   nonzero exit (1) on DIVERGED / COULD-NOT-VERIFY is ONLY a signal for a cron wrapper
#   to act on — the sweep itself blocks nothing and writes no git history.
#
# USAGE:   verify-cache-integrity.sh [--print-cron]
# KILL SWITCH:  SUPERPOWERS_INTEGRITY_GUARD=0  → prints one skip line, exit 0.
# TEST SEAMS:   CLONE_ROOT   (default: this script's own repo root, SCRIPT_DIR/..)
#               CACHE_PARENT (default: the real install cache parent)
#   both overridable so the test suite never touches the real clone or cache.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# It IS in the clone: default the clone to this script's repo root (like other tools/).
CLONE_ROOT="${CLONE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CACHE_PARENT="${CACHE_PARENT:-$HOME/.claude/plugins/cache/superpowers-extended-cc-marketplace/superpowers-extended-cc}"

STATE_DIR="$HOME/.cache/superpower-mod"
LOG_FILE="$STATE_DIR/integrity.log"
# Ensure the log target is writable ONCE, up front: every `2>>"$LOG_FILE"` below opens
# it, and a redirect to a path whose parent dir is missing FAILS the whole command (it
# would silently drop the git call to an empty result). If we can't create it, fall back
# to /dev/null so the redirects always succeed and the sweep still runs.
mkdir -p "$STATE_DIR" 2>/dev/null || true
{ [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ]; } || LOG_FILE=/dev/null

log() { # append one guarded line to the log; never fails the run
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -Iseconds 2>/dev/null)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# notify-send is guarded: ONLY validated values reach it (the version is charset-checked
# before this is ever called; counts are integers; reasons are fixed strings). Degrade
# silently if notify-send is absent.
notify() { # notify <body>
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "Superpower Mod — cache integrity" "$1" 2>>"$LOG_FILE" || true
}

sha_file() { sha256sum -- "$1" 2>>"$LOG_FILE" | awk '{print $1}'; }
sha_git()  { git -C "$CLONE_ROOT" show "$1:$2" 2>>"$LOG_FILE" | sha256sum | awk '{print $1}'; }

# Symlink-target readers (governed symlinks — e.g. AGENTS.md -> CLAUDE.md — are real tree
# entries, git mode 120000, whose BLOB CONTENT is the literal target string). The shipped
# target is the blob itself; the cache holds a real symlink whose target is read with
# readlink. Comparing these two STRINGS is the correct check: hashing would follow the link
# (sha256sum dereferences) and compare the pointed-at file's bytes instead of the pointer.
# `git show` appends exactly one trailing newline and $(...) strips trailing newlines, so
# an unterminated blob and readlink's unterminated output compare equal symmetrically.
link_git()  { git -C "$CLONE_ROOT" show "$1:$2" 2>>"$LOG_FILE"; }
link_file() { readlink -- "$1" 2>>"$LOG_FILE"; }

print_cron() {
  cat <<EOF
# Superpower Mod cache-integrity sweep — rung 5, weekly (Mon 09:30). Reports only;
# never blocks. NOT real-time: tampering between sweeps runs before the next sweep.
# Install by hand (this flag only PRINTS the line, it does not touch your crontab):
#
# DELIVERY (Fix 4): the line below appends BOTH stdout and stderr to the tool's log
# sink, so every verdict is durably recorded even with no MTA and no desktop. On a
# headless / no-DISPLAY box notify-send is a silent no-op, so THIS LOG is the sink that
# matters — read it. To ALSO receive mail, set MAILTO=you@host at the top of the crontab.
30 9 * * 1 "$SELF" >> "$LOG_FILE" 2>&1
EOF
}

# Verify ONE cache dir. Prints exactly one state line; notifies on the two non-verified
# states. Returns 0 iff VERIFIED, 1 otherwise.
verify_dir() { # verify_dir <cache_dir>
  local dir="$1"
  local version; version="$(basename "$dir")"

  # Guard every value that will be interpolated into notify-send.
  if ! [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]]; then
    printf 'COULD-NOT-VERIFY <redacted>: cache dir name has unsafe characters\n'
    log "CNV unsafe-version dir=$dir"
    notify "COULD-NOT-VERIFY: a cache dir name has unsafe characters"
    return 1
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    printf 'COULD-NOT-VERIFY %s: cache dir unreadable\n' "$version"
    log "CNV unreadable version=$version dir=$dir"
    notify "COULD-NOT-VERIFY $version: cache dir unreadable"
    return 1
  fi

  # version -> shipped commit, resolved EXACTLY (Fix 2). The old `git log --all --grep
  # "ship ${version}\$"` was unsafe four ways: it treated the version as a REGEX (a literal
  # '.' matched any char), anchored to end-of-LINE (a body line could match), searched
  # remote-tracking refs (--all), and silently took the newest of several matches (-1).
  # Instead: enumerate LOCAL-branch commits only, match the subject by SHELL STRING
  # EQUALITY against the literal "chore: ship <version>", and refuse to guess when the
  # answer is not unique. 0 matches -> no ship commit; >=2 distinct SHAs -> ambiguous.
  local want="chore: ship ${version}"
  local -A shas=()
  local h subj
  while IFS=$'\t' read -r h subj; do
    [ -n "$h" ] || continue
    [ "$subj" = "$want" ] && shas["$h"]=1
  done < <(git -C "$CLONE_ROOT" log --branches --format='%H%x09%s' 2>>"$LOG_FILE")

  if [ "${#shas[@]}" -eq 0 ]; then
    printf 'COULD-NOT-VERIFY %s: no ship commit\n' "$version"
    log "CNV no-ship-commit version=$version"
    notify "COULD-NOT-VERIFY $version: no ship commit found"
    return 1
  fi
  if [ "${#shas[@]}" -gt 1 ]; then
    printf 'COULD-NOT-VERIFY %s: ambiguous ship commit (%s matching commits)\n' "$version" "${#shas[@]}"
    log "CNV ambiguous-ship version=$version matches=${#shas[@]}"
    notify "COULD-NOT-VERIFY $version: ambiguous ship commit (${#shas[@]} matches)"
    return 1
  fi
  local sha=""
  for h in "${!shas[@]}"; do sha="$h"; done

  # FULL governed-tree comparison (Fix 1). The SHIPPED side is EVERY path in the commit
  # (no filtering to SKILL.md|*.sh); the CACHE side is EVERY file AND SYMLINK under the
  # version dir. We carry the git MODE per path (not a bare presence flag) so the compare
  # can dispatch on entry type: regular files hash-compare, mode-120000 symlinks compare by
  # readlink-vs-blob (F0 symlink fix, 2026-07-15). Full `ls-tree -r` emits
  # `<mode> <type> <objsha>\t<path>`; split on the TAB so paths with spaces stay intact,
  # then take the mode as the first field of the metadata. Modes are non-empty, so the
  # existing `[ -n "${ship[$p]:-}" ]` presence tests keep working unchanged.
  local -A ship=() cache=()
  local p rel meta
  while IFS=$'\t' read -r meta p; do
    [ -n "$p" ] || continue
    ship["$p"]="${meta%% *}"
  done < <(git -C "$CLONE_ROOT" ls-tree -r "$sha" 2>>"$LOG_FILE")

  if [ "${#ship[@]}" -eq 0 ]; then
    printf 'COULD-NOT-VERIFY %s: shipped commit has no files to attest\n' "$version"
    log "CNV empty-shipped-set version=$version sha=$sha"
    notify "COULD-NOT-VERIFY $version: shipped tree has nothing to attest"
    return 1
  fi

  # Enumerate regular files AND symlinks. `-type f` alone SKIPS symlinks — that was the
  # live false-positive: the governed AGENTS.md -> CLAUDE.md link was never listed, so it
  # read as "(missing)" against a byte-correct mod.16 cache (2026-07-15). Listing links
  # here also closes the injected-symlink blind spot: a link planted in the cache now has a
  # cache entry to be caught as "(extra)" instead of being invisible.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    cache["$rel"]=1
  done < <(find "$dir" \( -type f -o -type l \) -printf '%P\n' 2>>"$LOG_FILE")

  # Compare the UNION. A shipped path that is byte/target-changed, unreadable, type-changed,
  # or missing from the cache is a divergence; a cache entry with no shipped counterpart
  # (injected) is a divergence UNLESS it is git-ignored Python bytecode by EXACT extension
  # (*.pyc/*.pyo). NB: the exclusion is by extension, NEVER by directory subtree — a
  # *.sh/*.py/anything non-bytecode under __pycache__/ has no shipped counterpart and IS
  # flagged as extra. (check-ignore is deliberately NOT used: this repo's global git
  # excludes ignore the whole __pycache__/ tree, so check-ignore would wrongly clear a
  # __pycache__ payload.)
  #
  # in_s now holds the shipped git MODE (or "" if not shipped), so the both-present branch
  # dispatches on type: mode 120000 is a governed symlink compared by target string, any
  # other mode is a regular file compared by content hash.
  local -a diverged=()
  local -A seen=()
  for p in "${!ship[@]}" "${!cache[@]}"; do
    [ -n "${seen[$p]:-}" ] && continue
    seen["$p"]=1
    local in_s="${ship[$p]:-}" in_c="${cache[$p]:-}"
    if [ -n "$in_s" ] && [ -n "$in_c" ]; then
      if [ "$in_s" = "120000" ]; then
        # Shipped as a symlink: the cache entry MUST be a symlink too. If it is a real file
        # here, the type itself changed (a link swapped for its dereferenced contents, or a
        # planted file) — flag before any target read.
        if [ ! -L "$dir/$p" ]; then
          diverged+=("$p (type-changed)")
        else
          local a b
          a="$(link_git "$sha" "$p")"    # shipped target = blob content
          b="$(link_file "$dir/$p")"     # cache target   = readlink
          if [ -z "$a" ] || [ -z "$b" ]; then
            diverged+=("$p (unreadable)")
          elif [ "$a" != "$b" ]; then
            diverged+=("$p (modified)")
          fi
        fi
      else
        # Shipped as a regular file. Check type BEFORE hashing: sha256sum FOLLOWS symlinks,
        # so a link planted in place of the file and pointed at content with the right bytes
        # would hash-match and slip through. A cache symlink where a file was shipped is a
        # type change, full stop.
        if [ -L "$dir/$p" ]; then
          diverged+=("$p (type-changed)")
        else
          local a b
          a="$(sha_git "$sha" "$p")"
          b="$(sha_file "$dir/$p")"
          if [ -z "$a" ] || [ -z "$b" ]; then
            diverged+=("$p (unreadable)")
          elif [ "$a" != "$b" ]; then
            diverged+=("$p (modified)")
          fi
        fi
      fi
    elif [ -n "$in_s" ]; then
      diverged+=("$p (missing)")
    else
      # Injected cache entry (no shipped counterpart). The *.pyc/*.pyo bytecode skip applies
      # ONLY to REGULAR files: a SYMLINK named evil.pyc is not a build artifact, it is a
      # pointer masquerading as one, exactly what the exclusion must never clear — so any
      # injected symlink is ALWAYS flagged extra regardless of its name.
      if [ -L "$dir/$p" ]; then
        diverged+=("$p (extra)")
      else
        case "$p" in
          *.pyc|*.pyo) : ;;   # git-ignored bytecode, never in the shipped tree — skip
          *) diverged+=("$p (extra)") ;;
        esac
      fi
    fi
  done

  if [ "${#diverged[@]}" -eq 0 ]; then
    printf 'VERIFIED %s @ %s\n' "$version" "$sha"
    log "VERIFIED version=$version sha=$sha files=${#ship[@]}"
    return 0
  fi

  local joined; joined="$(printf '%s, ' "${diverged[@]}")"; joined="${joined%, }"
  printf 'DIVERGED %s: %s\n' "$version" "$joined"
  log "DIVERGED version=$version sha=$sha count=${#diverged[@]} files=${joined}"
  # Body carries only validated pieces: charset-checked version + an integer count.
  notify "DIVERGED $version: ${#diverged[@]} file(s) differ from the shipped commit — run tools/verify-cache-integrity.sh"
  return 1
}

main() {
  case "${1:-}" in
    --print-cron) print_cron; return 0 ;;
    -h|--help)
      printf 'Usage: %s [--print-cron]\n' "$(basename "$SELF")"
      printf '  Sweeps installed *-mod.* cache dirs against the commit that shipped each\n'
      printf '  version. Prints VERIFIED / DIVERGED / COULD-NOT-VERIFY per dir.\n'
      printf '  Kill switch: SUPERPOWERS_INTEGRITY_GUARD=0.\n'
      return 0 ;;
    "") ;;
    *)
      printf 'ERROR: unknown argument %s\n' "$1" >&2
      printf '  Correct form: %s [--print-cron]\n' "$(basename "$SELF")" >&2
      printf '  Averted: running an unrecognised flag as if it were the sweep.\n' >&2
      return 2 ;;
  esac

  # Kill switch FIRST — before any cache access.
  if [ "${SUPERPOWERS_INTEGRITY_GUARD:-1}" = "0" ]; then
    printf 'SKIP: SUPERPOWERS_INTEGRITY_GUARD=0 — cache-integrity sweep disabled.\n'
    return 0
  fi

  # Preflight: absent tooling is a VISIBLE couldn't-verify, not a silent pass.
  local missing=""
  command -v git       >/dev/null 2>&1 || missing="git"
  command -v sha256sum >/dev/null 2>&1 || missing="${missing:+$missing,}sha256sum"
  command -v find      >/dev/null 2>&1 || missing="${missing:+$missing,}find"
  if [ -n "$missing" ]; then
    printf 'COULD-NOT-VERIFY: required tool(s) absent: %s\n' "$missing"
    log "CNV missing-tools=$missing"
    notify "COULD-NOT-VERIFY: missing tool(s): $missing"
    return 1
  fi
  if ! git -C "$CLONE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'COULD-NOT-VERIFY: clone root is not a git repo: %s\n' "$CLONE_ROOT"
    log "CNV clone-not-git root=$CLONE_ROOT"
    notify "COULD-NOT-VERIFY: clone root is not a git repo"
    return 1
  fi
  if [ ! -d "$CACHE_PARENT" ]; then
    printf 'COULD-NOT-VERIFY: cache parent not found: %s\n' "$CACHE_PARENT"
    log "CNV no-cache-parent=$CACHE_PARENT"
    notify "COULD-NOT-VERIFY: cache parent not found"
    return 1
  fi

  # Governed cache dirs only (*-mod.*); the stock 5.2.8 / 6.0.5-dev upstream dirs are
  # not ours to attest and are skipped by the glob.
  local -a dirs=()
  local d
  for d in "$CACHE_PARENT"/*-mod.*/; do
    [ -d "$d" ] || continue
    dirs+=("${d%/}")
  done
  if [ "${#dirs[@]}" -eq 0 ]; then
    printf 'COULD-NOT-VERIFY: no governed (*-mod.*) cache dirs under %s\n' "$CACHE_PARENT"
    log "CNV no-mod-dirs parent=$CACHE_PARENT"
    notify "COULD-NOT-VERIFY: no governed cache dirs found"
    return 1
  fi

  local rc=0
  for d in "${dirs[@]}"; do
    verify_dir "$d" || rc=1
  done
  return "$rc"
}

main "$@"
exit $?
