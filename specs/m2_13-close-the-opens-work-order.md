# M2.13 Work Order — close the closeable

**Base:** `main` @ `e08b041`.
**Branch:** **`claude/determined-curie-nkf71s`**.
**Normative:** `specs/state-machine-v3.md` §4.8, §8.3, §10 @ `e08b041`.

M2.12 said the next thing after it was an external audit. This comes first, and
the reason is a correction to how I was going to run that audit: **anything we can
resolve ourselves should be resolved, not written into a brief.** An auditor's
attention spent re-deriving a question we could have answered is attention not
spent finding what we missed.

Three questions I had parked are now decided at `e08b041`, and two things I had
deferred are closeable. **After this there is nothing I know of left to do.**

---

## 1. §8.3 — the 3/3 conjunct is dropped

`SUPER_SAFE` no longer requires a unanimous ticket draw. Every other conjunct is
unchanged.

The reason, so the change is not read as a weakening: `SUPER_SAFE` meant *"met the
real criteria, then won a coin flip"* — the label already published a random
subsample, excluding 7% of qualifying content at `N = 40` and 16% at `N = 16` on a
draw carrying no information about the content. **Dropping it stops the label lying
about its own selectivity.** Every remaining conjunct is a tally fact, so nothing
enters `SUPER_SAFE` that a unanimous, fully-revealed, super-quorum cohort did not
approve.

`unanimousDraw` was stored for this and this only. **If nothing else reads it,
remove the field** — and say what that does to `Case`'s packing and to
`Moderation`'s size, which is at 21,726 B.

## 2. §4.8 — `CLAIM_BOUNTY` is paid on all three `UNRESOLVED` rows

To whoever poked the terminal transition, exactly as `DRAW_BOUNTY` already pays on
`NO_RANDOMNESS`.

I parked this at M2.7 as a fee-schedule change. That classification was wrong:
§4.8's own rule is *"a bounty is refunded where the transition it pays for cannot
occur, and paid where that transition was performed"*, and on every `UNRESOLVED`
row it **was** performed, permissionlessly, by someone paying gas. Retention was
the same rule applied inconsistently.

**And retaining it is worse than untidy.** `NO_TURNOUT` and `NO_REVEALS` have no
party who gains from poking them — unlike `NO_RANDOMNESS`, where §7.3 makes poking
dominant for the plurality-losing side. So an unpaid poke leaves a transition
**nobody is funded to make**, on the two rows a thin registry reaches most often.

Your **M47** pins the current retention. Re-anchor it to pin the new rule rather
than deleting it — the property still needs a mutation, it is just a different
property now.

## 3. D3-19 — no refund, no cooldown

Both decided; implement nothing new, and record the reasoning in `DEVIATIONS.md`
against the entry that raised it, because the refund answer inverts the obvious
one:

Refunding a **successful** removal looks like paying whoever corrects a protocol
error. But a removal is judged by the same engine at the same accuracy, so a
removal against **legitimately listed** content carries at the false-approval
rate — 60% at `prior` 0.665, `q = 0.30`. Refund-on-success makes censorship free in
the majority of attempts at the accuracy this design has to assume. **The fee is
the only thing pricing a censorship attempt.**

No cooldown because repetition is already bounded: a failed removal permanently
reserves the `REMOVE` key under §8.4's `REJECTED` row — it is an ordinary claim and
you correctly did not fork the engine — so a second identical removal is refused,
and `reopen` carries the tally forward and is self-defeating.

## 4. The `execute*()` retrofit — do it now

`executeCaps()` and `executeMaintenanceWithdrawal()` execute whatever is pending.
`RulesetGovernor` already takes the argument and matches against the commitment;
`StakeRegistry`'s two do not.

I deferred this because they sit inside a 33/33 baseline. That was right when the
baseline was the only evidence we had and re-running it was expensive. **It is no
longer either** — the harnesses work, they report INVALID correctly, and a re-run
is a known cost. Leaving a known governance hazard in place so a number stays
undisturbed is the wrong trade, and it is exactly the kind of thing that should not
reach an auditor as "deferred".

Same shape as the governor's: take the parameters, compare against the pending
record. Re-run `StakeRegistry`'s campaign and report the new combined figure.

## 5. The Python differential — it is solvable, so solve it

`DrawProperties.t.sol` checks the draw against the closed form. That is a real
check and shares no code with the contract, but it does not cross-check the
**ticket derivation** — the keccak-domain-separated `u[i]`, which is the highest
-consequence expression in the system.

You reported this blocked because Python here has no keccak and hand-rolling one
risks a bug that makes the comparison meaningless. **That risk is exactly what
known-answer tests retire.** Keccak-256 has published KATs; a pure-Python
implementation that reproduces them is not a guess.

- Implement or vendor keccak-256 in `simulation/v3/`, **validated against published
  KATs as the first thing the module does**. If it fails a KAT, it must refuse to
  run rather than produce numbers.
- Extend `protocol_v3.py` to derive `u[0..2]` exactly as §4.5 specifies —
  `H(OUTCOME_DOMAIN, chainId, contract, caseId, i, entropy)`.
- A Foundry test emits `(caseId, entropy, tally) → (u[0..2], verdict)` vectors;
  Python reproduces them independently.

**If the KATs do not pass, stop and report it rather than shipping an unvalidated
hash.** An unvalidated differential is worse than none, because it looks like
two-implementation agreement and is not.

## 6. Acceptance

1. All v3 suites green; count, and four sizes with `Moderation`'s delta from §1.
2. §1, §2 and §4 each tested, and §2's tested on all three rows.
3. The differential passing on vectors neither side chose to flatter itself — sweep
   tallies and entropies, do not hand-pick.
4. Mutation campaigns re-run for every contract you touch; combined figures,
   survivors analysed, **INVALID reported as INVALID**.
5. `DEVIATIONS.md` for §3's reasoning and anything §1–§5 could not answer.

## 7. After this

Nothing further is planned. If §5's KATs fail, or §1 moves `Moderation` in a way
that matters, those are the only two things I expect to hear about.
