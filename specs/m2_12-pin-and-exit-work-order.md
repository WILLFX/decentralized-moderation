# M2.12 Work Order — the guidelines pin, and the governor's exit

**Base:** `main` @ `3d63899`.
**Branch:** **`claude/determined-curie-nkf71s`**.
**Normative:** `specs/state-machine-v3.md` §4.1, §10 @ `3d63899`.

Two rulings on what you escalated at M2.11. **Both are small, both close before the
audit, and this is the last order before it.**

---

## 1. D3-21 — the pin. And the deciding argument is not the one you gave

You framed it as a measurement question: does `measurement/prior` need the text in
force at submission, or the text moderators read while voting? Good question, and
it's the wrong one to decide on — **fairness settles it first, and harder.**

`d` is charged for voting incoherently with the settled side (§5.1). If the
guidelines change while a case is live, moderators who committed before read one
text and those after read another, and whichever side loses is **debited for
correctly applying the instructions it was given.**

That is I27's own argument, applied to what a moderator is *asked* rather than what
they are paid — and it is a stronger case for pinning than parameters ever had.

**So the mid-case question dissolves rather than being answered.** Under a pin,
every moderator on a case reads the version pinned at its submission, whatever
governance does meanwhile. That is why a pin is the right mechanism and a join is
not, and why the answer does not depend on which reading of `measurement/prior` is
correct.

### What to build

`guidelinesVersion` becomes a **real `uint32` field on `Case`**, pinned at
submission exactly as `paramsVersion` is (§4.1 at the base commit).

- **The height join stays** as the governor's public record — version → text hash →
  effective block. It is the right thing for a *reader* recovering text. It is not
  the right thing for a *case* recording what it asked. Both exist; only one is
  authoritative for a case.
- **The text stays off-chain.** The pin carries a version; the governor's log
  carries the hash. Do not put text on chain.
- `Moderation` has **3,148 B**. A `uint32` beside `paramsVersion` should pack.
  **If it does not fit, that is a finding — report it, do not keep the join as a
  substitute.**

## 2. D3-20 — the governor's exit

`Moderation.governor` is mutable via `setGovernor`, which is `onlyGovernor` — and
`RulesetGovernor` exposes no caller, so the field is frozen because nobody wrote
one.

**Frozen by omission reads as deliberate to an auditor and was not.** That is the
reason to close it rather than document it: an auditor should be able to tell a
decision from an oversight, and right now this one is indistinguishable.

- Governor-side only. `RulesetGovernor` has **20,249 B** spare and `Moderation`'s
  delta must again be **zero**.
- Timelocked, on the same `propose`/`cancel`/`execute` shape, with §3's argument
  match from M2.11 — `executeGovernorChange(address)` checks against the pending
  commitment.
- **Reciprocity re-checked at execute, not at propose.** An incoming governor that
  is not already bound to this same `Moderation` bricks the pair permanently, and
  the interval between propose and execute is exactly when that could stop being
  true.

## 3. Not in scope

Everything still parked stays parked: `CLAIM_BOUNTY` on `UNRESOLVED`, §8.3's 3/3
conjunct, D3-19's removal fee and cooldown, consolidating `StakeRegistry`'s
timelocks, the `execute*()` retrofit on the older two contracts.

**Do not start anything else.** After this, the next thing that happens to this
codebase is an external audit.

## 4. Acceptance

1. All v3 suites green; count, and **confirm `Moderation`'s delta for D3-20 is
   zero** and report it for D3-21.
2. **The pin's point, tested as fairness and not as bookkeeping**: a case is
   submitted, the guidelines change while it is live, and every moderator on that
   case is judged — and debited — against the pinned version. A test that only
   reads the field back has not tested this.
3. **Reciprocity**: an incoming governor not bound to this `Moderation` is refused
   at execute, including the case where it was bound at propose and unbound after.
4. `SystemHandler` gets the governor change, so the stateful invariants cross it.
5. Mutation campaigns for both touched contracts; **INVALID reported as INVALID**,
   and watch the `pure`/`view` trap once more — a version-to-hash lookup is that
   shape.
6. Four sizes.
7. `DeployV3.s.sol` and its `verify()` updated for the new wiring.

## 5. One thing I want in the report

**A list of every place you had to guess**, across all six orders, that is still
guessed. Not defects and not open parameters — places where §-something said one
thing, the code needed a decision finer than it, and you made a defensible call
that nobody has ratified. `DEVIATIONS.md` has some of these; I want the ones that
did not rise to an entry.

That list is what an auditor is most likely to find and least likely to be told,
and it is worth more to me than another green table.
