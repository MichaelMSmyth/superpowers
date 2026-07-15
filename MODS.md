# Mod Ledger

Every edit to an inherited (upstream-owned) file gets a row — spec §3.
New files in additive paths (new skill dirs, tools/, docs/doctrine/) need no row.

| Date | File | Why |
|------|------|-----|
| 2026-07-14 | UPSTREAM.md, MODS.md | governance scaffolding (new files, listed for completeness) |
| 2026-07-14 | .claude-plugin/plugin.json, .claude-plugin/marketplace.json | version bumps via tools/ship.sh (standing entry) |
| 2026-07-14 | hooks/hooks.json | B1 claims-evidence SubagentStop wiring (spec §4 B1) |
| 2026-07-14 | hooks/hooks.json | B1.1 re-seam: added PostToolUse(Agent\|Task) registration — SubagentStop dead in VSCode harness, see finding doc |
| 2026-07-14 | skills/writing-plans/SKILL.md | property-shaped contract marker + property-test rule (survey candidate 1, narrowed) |
| 2026-07-14 | skills/writing-skills/SKILL.md | E1 doctrine fold-in — longspec rubric bindings + link to docs/doctrine/skill-principles.md (spec §4 E1) |
| 2026-07-15 | hooks/session-start | F6 routing-value allowlist — embed only a canonical, allowlisted model-routing mapping (key `^[A-Za-z0-9_-]+$`, value `^[A-Za-z0-9._:-]+$`/`inherit`/`omit`); drop prose to kill per-session injection (Phase 5 r1) |
| 2026-07-15 | hooks/hooks.json | F0 cache-integrity-check — additional SessionStart entry registering the fork-original cache-integrity advisory hook (Phase 5 r1) |
