# Upstream Tracking

**Upstream:** pcvelz/superpowers (contributor, not authority — spec §3).
**Watch remote:** obra/superpowers (original; pcvelz lags it by weeks-to-months).
**Fork point / last synced:** 20abe1f90723391958e0b156293be91820178a5b (6.0.5-dev, 2026-07-14)
**Edit-test loop:** commit → bump version in .claude-plugin/plugin.json (`<upstream>-mod.N`) → marketplace update → plugin update → restart session. Verified 2026-07-14 (same-version pickup does NOT work).

## Sync ritual (curated, never auto — on our schedule)
1. `git fetch upstream obra`
2. Drift report (Phase 1 tool; until then: `git log --oneline --no-merges <last-synced>..upstream/main` + `git diff --stat <last-synced>..upstream/main`)
3. Review each change: take / adapt / decline. Cross-check declined vs MODS.md.
4. Merge or cherry-pick. Resolve conflicts as review prompts, not failures.
5. Trigger-eval touched skills (Phase 1 tool).
6. Update **Last synced** above; commit with rationale; push.

## Sync log
| Date | From → To | Notes |
|------|-----------|-------|
| 2026-07-14 | (fork point) 20abe1f90723391958e0b156293be91820178a5b | forked at v6.0.5-dev; no sync yet |

## Rollback (verified: pending Task 6)
`claude plugin uninstall superpowers-extended-cc && claude plugin marketplace remove superpowers-extended-cc-marketplace && claude plugin marketplace add pcvelz/superpowers && claude plugin install superpowers-extended-cc@superpowers-extended-cc-marketplace`
