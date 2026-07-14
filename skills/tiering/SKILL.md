---
name: tiering
description: Use when choosing how much process a task deserves before starting it - classify T0/T1/T2 to set spread width, review weight, and ceremony, with a floor that never scales down
---

# Tiering — Sizing Ceremony to the Task

## Overview

Ceremony is a thermostat, not a thermometer. Every task carries a right amount of
process — spread width, review weight, ratification — and both directions are
expensive to get wrong: too much ceremony on a typo burns your human partner's
attention on a decision already made; too little on a one-way door ships an
irreversible change no one reviewed. Tiering sets the dial once, up front, against
a single question: **how expensive is this to undo?**

That question is the whole classifier. Reversibility, not size or confidence, is
what decides the tier — a large but trivially-revertable rename is lighter than a
one-line change to a published interface. You size the process to the cost of being
wrong, and the cost of being wrong is the cost of undoing.

## When to Use

Use this at the threshold of any task, before spending effort on it — the moment
you know what you are about to do but have not yet chosen how much process to wrap
around it. A task that is already mid-flight and has outgrown its tier is an
escalation event (see One-directional escalation), not a fresh classification.

## The tiers

The tiers partition tasks by undo-cost; every task lands in exactly one. The
verification is a single question — *if I had to undo this tomorrow, what would it
cost?* — and the answer places the tier.

| Tier | What it is (undo-cost) | Process it earns |
|---|---|---|
| **T0** | Reversible micro-work — a typo, a rename, a config tweak. Undo is free: one revert, no one downstream noticed. | Act. No consult, no spread. |
| **T1** | A normal, bounded task — a scoped feature, a bugfix with tests. Undo is bounded: revert and re-run the tests. | Light spread (2 candidate articulations) + standard review. |
| **T2** | A one-way door — architecture, a data migration, a public interface, anything hard to reverse. Undo is a project of its own. | Full spread + bracketing + explicit ratification + adversarial review, all before execution. |

The boundary that matters is T1 → T2: it is the line between "revertable" and
"one-way door." When a task straddles it, it is T2. The cost of over-ceremony at T2
is a little of your human partner's time; the cost of under-ceremony is an
irreversible change that skipped review. Those are not symmetric, so the tie breaks
upward.

## The invariant floor (never scales down)

Tier scales **ceremony**, never **integrity**. Regardless of tier, these hold at
full strength — a T0 typo obeys them exactly as a T2 migration does:

- Claims stay evidence-gated — a result is asserted only with the command output
  that proves it, at every tier.
- Kill switches stay live and env-checked-first; a soft gate warns and never
  blocks; a refusal keeps the gate-contract voice (offense, canonical form,
  `Averted:` line).
- Your human partner is never handed a template, form, or fill-in-the-blank — you
  spread candidates they discriminate, at T0 and T2 alike.
- Every edit to the fork clone earns its MODS ledger row and a version bump.

These are the floor. Tiering decides how much process sits *above* the floor; it
never lowers the floor itself.

## One-directional escalation

A task escalates UP a tier the instant it reveals its true size, mid-flight — the
reveal is the mechanism working, not a failure to be smoothed over. It moves DOWN a
tier only with your human partner's explicit say-so; you never quietly demote a task
to shed the ceremony it already earned.

Escalate the moment any of these appears:

| Signal mid-task | Escalates because |
|---|---|
| 3+ files touched where 1 was expected | the blast radius is larger than the tier assumed |
| any schema, data-shape, or interface change surfaces | a contract others depend on is now in play |
| any irreversible action becomes necessary (migration, delete, publish) | a one-way door opened — this is T2 by definition |

**Stuck protocol.** When a task escalates and you cannot tell where it should now
land, name the signal that changed and ask your human partner for the tier — you do
not guess the new ceiling any more than you guess the old one.

## Completion-time re-scan

At task end, re-check the tier you declared against the diff you actually produced:
run `tools/tier-scan.sh --tier <declared>` from the repo. It is a soft gate — it
warns, it never blocks. An over-budget WARN means the tier was **mis-declared at
intake**: the diff outgrew the ceremony you gave it. Record the signal you missed —
the one-line lesson of what at intake should have read as a higher tier — and carry
it forward. This is diagnosis, not punishment; the miss is data about your intake
sense, and the lesson is the whole yield.

The budgets in the re-scan match the CLI exactly (they are one contract, stated
twice): **T0 ≤ 2 files AND ≤ 40 changed lines; T1 ≤ 6 files AND ≤ 300 lines; T2
unlimited.** Changed lines are insertions plus deletions. These thresholds are
*assumed* values, calibrated from Phase 0–2 task diffs (2026-07-14), not laws — the
flip condition is explicit: two mis-sized warnings in one week means recalibrate the
thresholds, not override the gate.

## Red Flags

Rationalizations that surface under pressure while choosing or holding a tier. Each
is a reason to stop and re-tier, not a reason to proceed.

| Rationalization | Reality |
|---|---|
| "It grew, but re-classifying now feels like ceremony." | Escalation IS the mechanism working. The task revealing its true size is exactly the signal tiering exists to catch — re-tier now; the ceremony you are avoiding is the ceremony the task earned. |
| "T0 because I'm confident." | Confidence is not reversibility. The tier is set by undo-cost, not by how sure you feel — a confident change to a public interface is still a one-way door. |
| "It's basically the same as that other small change, so same tier." | Size is not the classifier either. Re-ask the one question — what would undoing this cost? — and let the answer, not the resemblance, place the tier. |
| "I'll declare T2 later if it turns out big." | The tier is chosen before effort, so the process can shape the work. Deciding after the diff exists is not tiering — it is the completion re-scan catching a miss you could have avoided. |
| "It touches a schema, but only a little." | Any interface or schema change is T2 by the escalation table. "A little" irreversible is still irreversible — the door swings one way regardless of how far you push it. |
