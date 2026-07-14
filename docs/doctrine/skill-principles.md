<!--
  IMPORTED DOCTRINE — verbatim third-party content below the attribution block.
  Source repo:  himalayasy/longspec
  Source file:  PRINCIPLES.md
  License:      MIT
  Imported:     2026-07-14
  Provenance:   Superpower Mod spec §4, row E1 (skill-authoring rubric; drop-in reference).
  Fetched via:  curl -sL https://raw.githubusercontent.com/himalayasy/longspec/main/PRINCIPLES.md
  Rule:         Everything from the next heading down to "## Fork annotations" is a
                verbatim copy of the upstream file. Fork-specific bindings live only in
                the "## Fork annotations (2026-07-14)" section appended at the end.
-->

> **Attribution.** The 16 principles below are imported verbatim from `PRINCIPLES.md`
> in the MIT-licensed repository [`himalayasy/longspec`](https://github.com/himalayasy/longspec),
> imported 2026-07-14 per Superpower Mod spec §4 (row E1). This fork adds only the
> `## Fork annotations (2026-07-14)` section at the end; the principle text itself is unmodified.

---

# Writing Principles for longspec Skills

These 16 principles govern how `longspec` skills are written — and how they evolve. They're equally applicable to any skill prompt aimed at shaping long-horizon agent behavior.

Review your proposal against every principle before editing a skill. Any ⚠️ means rewrite.

## A. Expression — how a single sentence reads

1. **State what *is*, not what *isn't*.** (to avoid LLM sycophantic over-generation — negative phrasing repeats what was already said positively) Main body uses `is / covers / carries / resolves / append / list`. "Don't / Never / Avoid" live only in dedicated anti-pattern sections.

2. **Skip what the LLM already knows.** (to avoid LLM sycophantic over-generation — the model restates common knowledge unless the prompt blocks it) Don't state "collection is deduplicated" (it already is), don't explain what "input" or "output" mean, don't prescribe naming conventions the model will produce anyway.

3. **One goal sentence beats twenty step instructions.** (to avoid path-dependent thinking — LLMs trained on solution steps prefer procedure over judgment criteria) Write "verify it independently," not "run start command, then curl health endpoint, then grep response." Steps belong in reference examples, not in rules.

4. **Examples must stand on their own outside your project.** (to avoid template mimicry — the LLM treats example-specific terms as part of the rule and fails to transfer) Strip the project-specific terms; if the rule still teaches, the examples are fine. Otherwise switch to generic domain examples (rate-limit, authenticated request, etc.).

## B. Content — whether a rule belongs

5. **Write rules only for violations that actually happen.** (to avoid LLM sycophantic over-generation — listing every theoretical case inflates the doc with noise) You should be able to name a real failure the rule prevents. If you can't, it's noise.

6. **Anti-patterns are rationalizations, not mistakes.** (to avoid LLM self-rationalization — the model invents reasons to keep going instead of stopping) "I'll stub it and move on" is a rationalization; "I forgot to run tests" is an operational slip — only the first goes in an anti-pattern section.

7. **Dual check: ambiguity and exploration cost.** (to avoid structural omission — ambiguity means the goal isn't pinned, exploration cost means the anchor is missing) If the agent, using general knowledge plus the current context, can't reach a unique interpretation, or has to grep through files to find the answer — add a disambiguating anchor. If it's unambiguous and zero-cost, keep it short or drop it.

## C. Structure — how a paragraph organizes

8. **Goal sentence first, example second.** (to avoid path-dependent thinking — example-first framing lets the reader mistake the procedure for the criterion) The first sentence pins the criterion. Examples come as separately marked references (`e.g.`, `for reference`), never as the rule itself.

9. **Classification = one-line definition + one-line verification.** (to avoid LLM sycophantic over-generation — per-category field lists duplicate what the model can already infer) Don't list per-category fields (the LLM can infer). Use a single verification condition that applies across all categories.

10. **State machines are named so they can be reconciled.** (to avoid loose naming — natural-language labels defeat machine-checkable reconciliation) `verified / unverified` is better than `ready / not ready` because it fits an explicit check. List trigger conditions exhaustively: "missing OR field-incomplete OR unverified → stop".

11. **Process rules cover four faces.** (to avoid structural omission — rules that only state the goal leave the agent to invent anchor, stuck protocol, or output shape) ① Standard (what good looks like), ② Anchor (where things live), ③ Stuck protocol (what to do when blocked), ④ Artifact shape (what the output looks like). Miss any face and the agent has to explore or rationalize.

## D. Collaboration — the human ↔ agent boundary

12. **When the agent can't find it, hand off to a human.** (to avoid LLM self-rationalization — faced with a dead end, the model fabricates rather than stops) "Ask the user where to create it," "ask the user to verify." No fixtures, mocks, or guesses. Escalation must name a specific action (ask what / where / verify what). This is a specific form of Principle 11's "stuck protocol," listed separately because specificity matters.

## E. Decision — how a skill asks the agent to choose

13. **First Principles — break path dependence.** (to avoid local shortcuts — the model keeps iterating on the current path instead of returning to origin) Before adding any entity, naming, structure, or flow, return to origin:
    - Root question: what is this problem, stripped of current assumptions?
    - Current path: is it still going somewhere useful, or iterating a direction that's already drifted?
    - Alternatives: from the origin, what other paths exist?
    Only list all paths before engaging Principle 14.

    Signals of path dependence: discussion keeps "improving the current version" and not converging; renaming the same thing three times still feels wrong; fields keep being added and the proposal keeps growing. All three say the path itself is off — diverge from origin again.

    When choosing between "one more iteration on the current path" and "return to origin," prefer the latter. The sunk cost of prior iteration is not a reason to continue.

14. **Occam — the smallest viable proposal.** (to avoid local shortcuts — the model picks the first workable option instead of the minimum one)

    Before introducing any entity (skill / doc / field / concept / step / category), return to the problem itself and ask:
    - Is this problem the same object as something an existing solution already handles?
    - Is this addition what the problem actually needs, or implementation noise?
    - Would "reuse or extend an existing carrier" solve it?

    Only proceed to a new-entity proposal when all three confirm "genuinely new / genuinely needed / no existing carrier fits."

    When proposing: first map this entity's dependencies and data flow to neighbors (who provides its input, who consumes its output, which existing entities touch the same data or the same flow — terminology translates by context: read/write/be-read in docs, call/be-called/depend-on in code, upstream/downstream/shared-data in systems). Identify entities that are same-source (two facets of the same problem), co-produced (always change together), or co-consumed (downstream reads together); prefer to reuse or merge their carrier. Then rank remaining candidates by (new components, files touched, new concepts introduced) ascending; recommend the smallest.

    Rationalizations to reject on sight: future extensibility / symmetry / needs new mechanism / this is new so it needs a new carrier / I'm just refining the proposal (when the problem has actually drifted).

15. **MECE — categories are mutually exclusive and collectively exhaustive.** (to avoid sloppy classification — the model settles for "covers common cases" instead of enforcing non-overlap and exhaustion) When a skill gives the agent a classification (type / state / trigger), categories must not overlap (mutual exclusion) and must together cover every case (exhaustion). Overlap means the agent can't place an instance; gaps mean the agent invents a category for unlisted cases.

## F. Conflict arbitration

16. **Apply the principles in this order when they conflict:** (meta-rule — without an arbitration order, authors oscillate between "say more" and "say less" camps)

    - ⓪ **First Principles (13)** — done once up front before any decision
    - ① Entity-relation mapping (the prefix of 14) — decides standalone vs merged carrier
    - ② Real violations + HIL (5, 12) — decides what must be written
    - ③ Four faces (11) — fills in what must be written
    - ④ Occam compression (14) — trims within what 3 produced
    - ⑤ Ambiguity + known-to-LLM dual check (2, 7) — each sentence passes this
    - ⑥ MECE classification (15) — whole-structure check at the end

    The remaining principles (1, 3, 4, 6, 8, 9, 10) are per-sentence quality checks — apply them continuously while writing.

    Without arbitration order, authors oscillate between the "say more" camp (11, 7, 12) and the "say less" camp (14, 2, 5).

---

## Fork annotations (2026-07-14)

How the imported rubric binds onto this fork's practice. These are additive: they
map longspec's principle numbers onto the Superpower Mod harness — they do not
alter the principles above.

- **(a) "State what *is*, not what *isn't*" (§A.1) ↔ the gate-contract voice.**
  Every refusal a fork gate emits names the offense, states the canonical form to
  use instead, and closes with an `Averted:` line naming the failure it prevented.
  That is §1 in enforcement clothing: the gate speaks in the positive ("use X"),
  and the "don't" lives only in the `Averted:` anti-pattern slot — never in the
  main instruction.

- **(b) "One goal sentence beats twenty step instructions" (§A.3) ↔ the enforcement ladder.**
  This fork's ladder pushes procedure *down* out of prose into hooks and CLIs
  (rungs 3–5); skill text that survives carries judgment and criteria only. §3's
  "write the criterion, not the steps" is the same move: the steps become the
  mechanism, and the skill keeps the one goal sentence.

- **(c) "Anti-patterns are rationalizations, not mistakes" (§B.6) ↔ upstream's Red Flags tables.**
  Those tables are load-bearing, eval-tuned content: they catalog the exact
  rationalizations ("I'll stub it and move on") the agent reaches for under
  pressure. §6 is the reason they exist and the reason we keep them intact — a
  fork edit removing a Red Flags row deletes a tested violation-catcher, not noise.

- **(d) Conflict-arbitration order (§F.16) ↔ this fork's instruction priority.**
  §16 gives longspec's authors a fixed order to resolve principle conflicts. The
  fork's analogue for *runtime* conflicts is a fixed instruction priority:
  **Michael's explicit instructions > fork skills > upstream defaults.** When two
  sources disagree, resolve upward in that order — the same discipline §16 applies
  to competing principles, applied to competing instruction sources.
