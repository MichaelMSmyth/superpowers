---
name: intent
description: Use when your human partner gives fuzzy direction, a pointer, or a half-formed vision that needs articulation before any spec exists - spread candidate readings for cheap discrimination, never hand them a form
---

# Intent — Articulating Fuzzy Direction

## Overview

Your human partner thinks in high-dimensional pointers. They can feel the shape of
where a project should go long before they can name it in words — the direction is
real, the tokens are missing. Articulation is your job. You produce candidate
readings they discriminate in a glance (a warm read they lean toward, a cold read
they push away); they do not answer an interrogation you hand them.

The asymmetry is the whole skill. Emitting a precise specification is expensive for
them and cheap for you; judging whether an articulation matches their felt sense is
cheap for them and impossible for you. So you spend your cheap operation — generate
candidate articulations — to save their expensive one, and they spend their cheap
operation — recognize the reading that fits — on the one thing only they can do.

## When to Use

Use this when the direction is felt but not yet sayable: a pointer, a mood,
"something like X, but not quite," a quality they can gesture at but not define.
There is no articulable idea yet — producing one is the work this skill does.

When another skill owns the moment instead:

- A **clearly specified** task goes straight to planning. The intent is already
  pinned; re-articulating it spends attention on a question already answered.
- A **stated-but-unrefined** idea belongs to `brainstorming`. Brainstorming takes an
  idea they CAN state and refines it into a design; intent operates one step
  earlier, when there is no statable idea to refine. The boundary is a single test:
  if they can say what they want in a sentence, that sentence is the idea — hand off
  to brainstorming. If the sentence keeps coming out wrong, you are still in intake.
- Intent **drift found mid-execution** is an amendment event (see Harvest), handled
  by reopening the ratified vision and amending it — a fresh intake starts over from
  nothing, which throws away a vision that was already ratified.

## The spread protocol

Five moves, in order. This is the standard for a sound intake.

1. **Restate the pointer.** Give the direction back in one sentence — "You're
   pointing at X." This confirms you caught the vector before you spend effort
   spreading around it; a wrong restatement is cheap to fix now and expensive later.

2. **Spread candidates that differ along your least-sure axis.** Offer 2–4
   articulations that genuinely disagree where you are most uncertain — distinct
   readings, not four phrasings of one guess. Width follows the task tier: a light
   intake spreads 2 candidates; a full intake spreads 3–4 and brackets — bracket by
   overshooting the pointer in both directions, one candidate past it each way, so
   their real target sits between two references they can compare against.

3. **Read their discrimination as data.** "Warmer," "colder," "that word is wrong"
   are measurements of the target's location. You steer by them: warmer means step
   further that way, colder means that axis was wrong. Their reaction is signal about
   where the target is, and you move the articulation toward it — it is data, not a
   verdict to argue with.

4. **Iterate until they say it is right.** Re-spread, narrower each round, converging
   on the reading they recognize. The loop closes when they confirm the articulation
   lands — not when you run out of candidates or patience.

5. **Ratify explicitly.** Ratification is a spoken act: the word "ratify," or an
   unmistakable equivalent, from them. Absent that word, the intent stays a
   candidate — enthusiasm, "yeah, that's cool," and silence are readings-in-progress,
   not ratification. When the articulation looks right, ask for the word.

**Stuck protocol.** If their answer comes back vague, that vagueness is itself a new
pointer — spread again, narrower, along the axis their words just implied. If they
keep saying "colder" and you have exhausted your axes, say so and ask which dimension
is wrong. If you cannot tell where the ratified vision should be committed, ask them
where it lives — you do not guess a path.

## Judgment cards

Decisions that surface during intake — a fork in the direction, a trade-off they must
weigh — are surfaced as judgment cards. This is the only summary format for a
decision:

- **Decision** — the one question being decided, in a line.
- **Options** — 2–4, each with its cost named.
- **Recommendation + credence** — your pick and how sure you are (e.g. "B, ~0.7").
- **Flip-conditions** — the evidence that would change the recommendation.
- **Trace pointer** — where in the conversation this was worked out.

A card is a projection of the conversation trace, not a replacement for it. Work
resumes from the trace; the card is the index into it, never the source. When intake
continues, reopen the trace the pointer names.

## Harvest

Ratified intent is committed — it lives in version control, not only in the session.

- **Anchor.** Write the ratified vision to `docs/intent/vision.md`, or the project's
  declared equivalent. When no location is declared, ask them where it lives.
- **Amendments.** Every later change to the vision is its own commit, carrying a
  rationale line for why the intent moved. The vision keeps a history you can read.
- **Silent drift is the one crime** — executing against an intent that changed and
  was never written down. An amendment commit is cheap; a divergence no one can see
  is exactly the failure this section exists to prevent.

## Verdict routing

When a call must be made during intake, route it by who can actually judge it:

- **Taste** → your human partner. Their felt sense, aesthetic, and direction are
  theirs to settle.
- **Technical trade-off** → you, with a stated credence — name your pick and your
  confidence, so an override is cheap for them.
- **Neither is trustworthy** → build the eval and let reality vote. When taste cannot
  settle it and neither of you should be trusted to guess, say so aloud, and let the
  measurement decide.

## Red Flags

Rationalizations that show up under pressure during intake. Each is a reason to stop,
not a reason to proceed.

| Rationalization | Reality |
|---|---|
| "I'll just draft a quick template for them to fill in." | NEVER hand your human partner a template, form, or fill-in-the-blank — that inverts the asymmetry and forces the expensive articulation back onto them. Standing prohibition. Spread candidates they discriminate instead. |
| "Their answer was vague, so I'll pick the reasonable reading and move on." | A vague answer is a pointer too. Picking silently smuggles YOUR reading in as theirs. Spread again, narrower, along the axis the vagueness implies. |
| "They're clearly excited — ratification is implied by their enthusiasm." | It is not. Enthusiasm is not the word. Ask for "ratify" or an unmistakable equivalent before treating the intent as settled. |
| "I basically know what they mean; I'll skip the restate." | The restate is the cheapest error-check you have. Skipping it spreads effort around a vector you never confirmed. |
| "My articulation was good — I'll talk them out of 'colder.'" | "Colder" is a measurement, not a challenge. Arguing discards the one signal only they can produce. Move the articulation; do not defend it. |
