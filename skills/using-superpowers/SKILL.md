---
name: using-superpowers
description: Use when starting any conversation - establishes how to find and use skills, requiring Skill tool invocation before ANY response including clarifying questions
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
</SUBAGENT-STOP>

## Instruction priority

Ranked highest to lowest; the user's instructions always win:

1. **User's explicit instructions** (CLAUDE.md, AGENTS.md, direct requests) — highest.
2. **Superpowers skills** — over default behavior.
3. **Default system prompt** — lowest.

So a CLAUDE.md "don't use TDD" overrides a skill's "always use TDD."

## Using skills

Skills appear with descriptions in your system prompt; the `Skill` tool loads a skill's current version and wiring into context.

An embedding router surfaces relevant skills when they matter — your prompt, mid-work, after compaction — silent otherwise. A surfaced suggestion cleared its threshold and is high-prior, so invoke it unless clearly inapplicable. Beginning NEW work with none surfaced, glance once at the skills list — a process skill (brainstorming, systematic-debugging, writing-plans) before a domain one, since process decides HOW.

## Red flags

These thoughts are rationalizations — invoke the skill instead:

| Thought | Reality |
|---------|---------|
| "I remember this skill" | Skills evolve; only the invoked version runs. |
| "Too simple for a skill" | Simple is where unexamined assumptions bite. |
| "I'll Read the file to check" | Invocation loads the current version and its wiring; Read loads neither. |
