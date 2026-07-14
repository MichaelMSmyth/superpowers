# Upstream Tracking

**Upstream:** pcvelz/superpowers (contributor, not authority — spec §3).
**Watch remote:** obra/superpowers (original; pcvelz lags it by weeks-to-months).
**Fork point / last synced:** 20abe1f90723391958e0b156293be91820178a5b (6.0.5-dev, 2026-07-14)
**Edit-test loop:** commit → bump version in .claude-plugin/plugin.json (`<upstream>-mod.N`) → marketplace update → plugin update → restart session. Verified 2026-07-14 (same-version pickup does NOT work). Use the fully-qualified name `superpowers-extended-cc@superpowers-extended-cc-marketplace` for install/update (unqualified name fails).
0. Run tools/dod-check.sh — the definition of done must be green before any ship.
Or simply: `tools/ship.sh` (does bump + updates + prune + verify).

## Sync ritual (curated, never auto — on our schedule)
1. `git fetch upstream obra`
2. Drift report: `python3 tools/drift_report.py` (three-way + ledger cross-check + token cost)
3. Review each change: take / adapt / decline. Cross-check declined vs MODS.md.
4. Merge or cherry-pick. Resolve conflicts as review prompts, not failures.
5. Trigger-eval touched skills: `python3 tools/trigger_eval.py --skill <name> --fixtures <fixture.json> --n 5 --live`
6. Update **Last synced** above; commit with rationale; push.

## Sync log
| Date | From → To | Notes |
|------|-----------|-------|
| 2026-07-14 | (fork point) 20abe1f90723391958e0b156293be91820178a5b | forked at v6.0.5-dev; no sync yet |

## Rollback (verified 2026-07-14, both directions)
`claude plugin uninstall superpowers-extended-cc && claude plugin marketplace remove superpowers-extended-cc-marketplace && claude plugin marketplace add pcvelz/superpowers && claude plugin install superpowers-extended-cc@superpowers-extended-cc-marketplace`
