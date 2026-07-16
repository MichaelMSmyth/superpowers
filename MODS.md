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
| 2026-07-15 | hooks/session-start | F6 routing-value allowlist — embed only a canonical, allowlisted model-routing mapping (keys restricted to known tiers mechanical/standard/frontier, value `[A-Za-z0-9._:-]+`/`inherit`/`omit`); drop prose to kill per-session injection (Phase 5 r1) |
| 2026-07-15 | skills/brainstorming/SKILL.md | intake round (b): problem-excavation front-load (goal-divergence check after context load, XY escape, evidence gate, MECE breadth) — promoted into Checklist item 2 + digraph node per C2 (off-checklist prose gets skipped); question mechanics (defaults, fork-naming, escape, stopping rule); Load-bearing-choices assay table in specs (spec §2.11+§2.13; finding 2026-07-15-design-question-research) |
| 2026-07-15 | skills/systematic-debugging/SKILL.md | intake round (e): pre-retry gate — before any re-run/restart/relaxed-parameter: enumerate failed-run artifacts, state the retry's hypothesis, name what it would destroy; recorded-transient carve-out; +2 rationalization-table rows ("run it again with more time", "probably flaky"); worked example = 2026-07-14 eval-timeout artifact (spec §2.14 questions-at-the-seams) |
| 2026-07-16 | skills/using-superpowers/SKILL.md | bootstrap slim 117→34 lines (~1.4k→~0.4k tok/session): 1%-exhortation regime → embedding-router contract (evidence: finding 2026-07-16-skill-surfacing-vs-memory-recall — router eval-dominant, prompt-pressure measured ineffective); multi-harness sections removed (spec §7 CC-only — future sync conflicts here BY DESIGN); frontmatter byte-identical (A4 trigger evals stay valid) |
