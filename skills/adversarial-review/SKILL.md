---
name: adversarial-review
description: Use when a spec, plan, or diff needs red-teaming before ratification or merge - fresh reviewer per named lens tries to refute it, severity verdicts, disagreement surfaced never auto-resolved
---

# Adversarial Review — Refuting an Artifact Before It Is Trusted

## Overview

A review that polishes is grooming. This skill REFUTES: its reviewers exist to
find the reasons an artifact is wrong before anyone trusts it, and a reviewer's
deliverable is refutations — each carrying its evidence and a severity — never a
patch. The default posture is that a reason exists and the job is to surface it;
a clean pass is earned only when the lenses come back dry.

Refute-don't-fix has a named reason: the fixer's incentives corrupt the finder's
eye. The moment a reviewer starts repairing what they found, they stop hunting
for what else is broken — the relief of the fix closes the search early, and the
second, deeper flaw ships behind the first one's patch. So the reviewer routes
the finding; the coordinator, or your human partner, owns the repair.

## When to Use

Use this when an artifact — a spec, a plan, a diff, an audit target — is about to
be TRUSTED: ratified, merged, or built upon. The cheapest failure is the one
found before that moment; every failure found after it is paid for again in the
work already stacked on top. This is the adversarial half of a T2 one-way door.

When another skill owns the moment instead:

- Work seeking **improvement or verification** before merge goes to
  `requesting-code-review` — that skill dispatches a reviewer to help the work
  reach its bar and reports strengths alongside issues. THIS skill is its
  adversary, not its synonym: it does not ask "is this good enough to ship?" but
  "what is the reason this is wrong?" — and it presumes there is one until every
  lens returns empty. Send polishing there; send refutation here.

## The lens roster

Each review dispatches ONE FRESH subagent PER LENS, and no reviewer shares
context with any sibling — a lens sees only the artifact and its own charter. A
reviewer that inherited another's findings would inherit its blind spots and be
anchored by its verdicts; the isolation is what keeps six independent eyes
independent. The six lenses are pinned, and their charters are cut so no two
overlap — every finding belongs to exactly one lens.

| Lens | Refutes by asking — its charter alone |
|---|---|
| **premise** | Are the load-bearing assumptions true NOW? Runs the assumption assay (below). |
| **spec-coverage** | Does every requirement map to a mechanism — and every mechanism back to a requirement? Names the gaps AND the orphans (mechanisms serving no requirement). |
| **correctness** | Do the pinned commands and code actually run as written, and are the contracts internally consistent across sections — names, paths, exit codes, numbers? |
| **type-design** | Are illegal states unrepresentable — parse-don't-validate, boundaries validate once, interiors trust the types? A review lens only, never a design-time approval step. |
| **silent-failure** | Is every error path handled, every swallowed exception accounted for, every fail-open vs fail-closed choice stated and justified — with kill switches present where the house rules demand them? |
| **process-safety** | Does the change conform to the enforcement ladder — hard gates never targeting your human partner's own sessions, soft gates never blocking, Stop-gates carrying the three brakes (bounded counter, sentinel escape, loop-safe block-reasons), ledger rows and version bumps where required? |

**The premise lens's assay.** The premise lens refutes a load-bearing choice by
the assumption assay — four measurements per choice:

- **buy** — what does this choice get us?
- **cost** — what does it cost or restrict?
- **inversion** — can the presumed asset instead harm us?
- **reality** — what does current reality say, measured now, not remembered?

**Lens selection.** The coordinator picks the lens set from the artifact's kind:

- plans and specs → **premise, spec-coverage, correctness, process-safety** at minimum.
- diffs and code → **correctness, type-design, silent-failure** at minimum.
- audits → **all six**.

"At minimum" means add lenses the artifact invites, never drop one the kind
requires. When the kind itself is ambiguous — a plan that is really a diff, a
spec that ships code — name the ambiguity and ask your human partner for the lens
set rather than guessing; an under-fit set is the "it found nothing, ship it"
failure lying in wait.

## Protocol

Seven rules govern a review from dispatch to disposition:

1. **The coordinator names the target and the lens set** before any reviewer is
   dispatched — the target artifact stated explicitly, the set chosen by the
   selection rule for its kind.

2. **One fresh subagent per lens**, each receiving ONLY the artifact and its lens
   brief — no sibling findings, no coordinator opinions, nothing carried over
   from the session that produced the artifact.

3. **A reviewer returns each finding as four fields**: refutation · evidence ·
   severity (CRITICAL / MAJOR / MINOR) · confidence. A finding without evidence
   is a suspicion, not yet a finding.

4. **The coordinator verifies each CRITICAL and MAJOR against reality** — file
   reads, command runs — before accepting it. A finding is a claim, and claims
   are evidence-gated; an unverified CRITICAL is a hypothesis, not a verdict.

5. **Round cap for a targeted red-team: TWO rounds maximum.** If round two still
   produces verified CRITICALs, the verdict is RETHINK — the artifact's approach
   is wrong, and the response is to stop patching it, not to open a third round.

6. **Audits run in exhaustive mode instead** — a different mode from rule 5's
   targeted cap: loop the full lens set until dry, stopping only after K=2
   consecutive all-lens rounds produce zero new findings.

7. **Disagreement between lenses is surfaced verbatim in the trace**, never
   averaged and never auto-resolved. Two lenses reaching opposite verdicts is
   signal; your human partner or the coordinator arbitrates with stated reasons,
   and the arbitration reason joins the trace beside the disagreement it settled.

## Output

Findings land in a trace doc at `docs/traces/<date>-<target>-redteam.md`. It
records the target, the lens roster used, the per-lens findings with their
post-verification verdicts, the surfaced disagreements, and a disposition for
every finding — **fixed**, carrying the commit SHA that fixed it, or
**declined**, carrying the stated reason it was declined. The trace is the
authoritative register; any summary is a projection of it and is never edited in
its place.

**When you cannot proceed.** If you cannot tell where the trace should live or
which lens set the artifact earns, name what is missing and ask your human
partner — a red-team that guesses its own scope has already failed the artifact
it was meant to defend.

## Red Flags

Rationalizations that surface under pressure during a review. Each is a reason to
stop, not a reason to proceed.

| Rationalization | Reality |
|---|---|
| "The reviewer suggested a fix, so I'll just apply it." | Refute-don't-fix — route the finding to whoever owns the repair, not the patch. A reviewer who fixes stops hunting; take their patch and you have also ended their search. |
| "Two lenses disagree — I'll go with the senior-sounding one." | Surface it. Tone is not evidence; arbitrate with stated reasons recorded in the trace, never average the verdicts or defer to whichever lens sounded surer. |
| "Round three will surely converge." | It won't — RETHINK exists precisely because a second round of verified CRITICALs says the approach is wrong, not under-patched. Stop and rethink the artifact. |
| "It found nothing, so ship it." | A review that can't fail isn't a review. Before trusting a clean pass, check that the lens set actually fit the artifact — a clean pass from the wrong lenses is silence, not safety. |
