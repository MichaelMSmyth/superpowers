---
name: environment-research
description: Use when the terrain is unfamiliar or an assumption is unverified before design - probe the real system in disposable scratch space, provoke failures on purpose, record observed-vs-predicted
---

# Environment Research — Mapping Unknown Terrain Before Design

## Overview

A design is only as sound as the terrain it stands on, and terrain is known by
measurement, not by memory. Documentation records what a system was meant to do;
the running system is the sole authority on what it actually does. This skill sends
you to meet that authority first — in disposable scratch space, before a line of
the design exists — because the cheapest moment to meet a failure mode is before
you have built anything that depends on it not existing.

The worked example lives one level up from this fork, in the project repo at
`docs/findings/2026-07-14-subagentstop-dead-seam.md`. A guard organ (B1) was
verified at every layer its authors could reach in-session — unit tests passed, a
manual pipe reproduced the advisory, a headless probe ran clean — and it still
shipped dead, wired to a hook event (SubagentStop) that never fires in the target
harness: 0 firings across a full day against 9 subagent dispatches. Every reachable
layer was green; the one layer nobody probed — live event delivery in the target
surface — was exactly where it failed. One pre-design probe of that seam would have
caught it. That is the whole case for this skill: verify the layer that carries your
assumption, in the surface that will run it, before you commit to a design.

## When to Use

Use this when you are about to design against terrain you have not measured: an API
whose collision behavior you are guessing at, a CLI whose failure output you have
not seen, a hook event you have not watched fire — any assumption load-bearing
enough that a wrong guess reshapes the design. The trigger is unfamiliar terrain OR
an unverified assumption standing upstream of a design that does not yet exist.

When a different skill owns the moment instead:

- A failure that **already happened** — a bug, a test failure, an exception in hand
  — belongs to `systematic-debugging`. That skill explains a present failure by
  tracing it back to a root cause; this one maps unknown terrain before any design
  or failure exists. The boundary is a single test: if something broke, work
  backward from the symptom you have — that is debugging. If nothing has been built
  yet to break, work forward from the question you have not answered — that is
  research.
- Terrain **already measured and recorded** needs no re-probe. When a finding
  already answers your question, read the finding — re-running a settled probe
  spends effort to re-derive what the record already holds.

## Scratch discipline

All probing happens in `scratch/` at the project root — a gitignored sandbox that
exists to be thrown away. When the directory or its `.gitignore` entry is absent,
create both before the first probe; the sandbox is disposable by construction, and
a probe that litters the tracked tree defeats its own disposability.

Findings move out of scratch; files stay. What crosses the boundary from scratch
into the design is the recorded lesson — the observed behavior, the number, the
surprise — carried across as prose into a finding. A probe script, a captured log,
a throwaway fixture lives in scratch and dies there. Copy-pasting a scratch artifact
into the design smuggles unvetted scaffolding into permanent code; the sandbox earns
its freedom precisely because nothing structural escapes it.

## The probe loop

Four rules, in order. The loop turns a hunch into a measurement:

1. **Write the prediction down before running.** State what you expect to observe,
   in `scratch/decisions.jsonl`, before the probe executes. A probe with no prior
   prediction is a demo, not a measurement — without a committed expectation there
   is no gap to detect, and the gap is the entire yield.
2. **Run the probe.** Execute against the real system in the real surface — the one
   that will run the eventual design, not a proxy standing in for it.
3. **Record one line in `scratch/decisions.jsonl`.** One JSON object per probe
   (schema below), written whether the prediction held or missed.
4. **Provoke the failure modes deliberately.** Feed the malformed input, the stale
   cache, the missing file, the colliding version — aim the probe at the edge you
   are least sure of. The happy path is the least informative probe: it confirms
   what you already believed. The boundary conditions are where the terrain diverges
   from your model of it, so that is where the probe points.

## decisions.jsonl schema

One JSON object per line:

`{"ts": "<ISO-8601>", "question": "<what we needed to know>", "prediction": "<expected>", "observed": "<actual>", "matched": true|false, "lesson": "<one line, or null>"}`

`"matched": false` is the most valuable line in the file. It marks the exact
boundary between the model in your head and the system in front of you — the place
your understanding was wrong and now is not. A ledger of all-`true` rows only ever
probed what it already knew.

Rows are append-only: never deleted, never retro-edited. A prediction that missed
stays on the record as it was written — editing it to match what you later learned
erases the measurement and the lesson along with it.

## Harvest

At research end, the rows carrying lessons distill into a finding at
`docs/findings/<YYYY-MM-DD>-<slug>.md` (the project convention). The scratch
directory is disposable; the finding is permanent — it is what a future session
reads instead of re-probing the same terrain. Carry across only what a row's
`lesson` earned: the observed behavior and what it changed, not the scaffolding
that produced it.

An explicit null harvest is a legitimate, recorded outcome. When every prediction
held — nothing surprised you — write that finding too: "probed X, Y, Z; each
behaved as the model predicted; no surprises." A recorded null tells the next
session the terrain was measured and found ordinary, which is exactly the fact that
spares them the re-probe.

## Red Flags

Rationalizations that surface when a probe feels like overhead. Each is a reason to
stay in scratch, not a reason to leave it.

| Rationalization | Reality |
|---|---|
| "I'll just read the docs instead." | Docs describe intent; probes measure behavior. The gap between the two is the exact failure mode this skill exists to catch — the SubagentStop seam was documented and still dead. Read the docs to form the prediction, then probe to test it. |
| "The probe worked first try, moving on." | Then it was not probing the edge. A clean first run means you fed the happy path — the case you already believed. Provoke the failure: malformed input, stale cache, colliding version. The probe that surprises you is the one that paid for itself. |
| "I'll clean up the failed attempts." | The failed attempts ARE the data. A probe that errored, hung, or returned garbage measured a real boundary of the system — deleting it discards the `matched: false` row that was the whole point. Record what failed; leave the mess in scratch. |
