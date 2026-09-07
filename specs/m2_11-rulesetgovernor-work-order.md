# M2.11 Work Order — `RulesetGovernor`, the fourth contract

**Base:** `main` @ `f517a2f`.
**Branch:** **`claude/determined-curie-nkf71s`**.
**Normative:** `specs/state-machine-v3.md` §1, §4.1, §10 @ `f517a2f`.

You asked whether to build this or take the audit with three. **Build it** — the
reasoning is §1 below, and the scope is smaller than §10 used to imply.

---

## 1. Why this and not the audit

Two of §10's rows for this contract closed themselves while you were building the
other three, and I corrected them at `f517a2f` rather than let the order inherit
them:

- **The `BLOCK_TIME` bound is already validated**, and better than §10 asked.
  `applyParams` rejects `commitBlocks > SEED_LAG + BLOCKHASH_HORIZON` directly —
  the constraint itself, not the `4.651 s` wall-clock consequence that would drift
  if any of the three inputs moved. And it sits one layer *below* the governor,
  where replacing the governor cannot bypass it. **Leave it there.** Do not move it
  and do not duplicate it.
- **What is actually left is a governance asymmetry nobody chose.**
  `StakeRegistry` timelocks everything a governor can do — caps, condemnation,
  maintenance withdrawal. `Moderation.applyParams` is `onlyGovernor` and takes
  effect **immediately**: no pending record, no `eta`, nothing to observe or exit
  ahead of.

I27 pins parameters per case at submission, so **live cases are safe and only
future ones move**. That is what makes this a risk asymmetry rather than a
correctness defect — and it is exactly the class an auditor should find *already
closed*, because it is a design choice, not a bug. Auditing three of four hands
them a hole where governance belongs and spends findings on it.

## 2. The design call that keeps `Moderation` under EIP-170

**`Moderation` is at 21,428 B — 87.2%, 3,148 B spare.** The naive reading of "add
a timelock to `applyParams`" puts a `PendingParams` struct and a propose/cancel/
execute trio inside `Moderation`, and `Params` is a wide struct. That could cost
more than the headroom.

**So it goes the other way round:**

```
RulesetGovernor holds the pending Params, the eta, and the propose/cancel/execute
Moderation.applyParams stays exactly as it is, callable only by the governor
```

`Moderation` becomes the governor's *target*, not its host. **Expected `Moderation`
delta: zero.** If you find yourself editing `Moderation` for more than an address
type or a comment, stop and tell me — that is a sign the split is wrong, not a sign
to spend the headroom.

`applyParams`'s own validation stays where it is. The governor validating too is
fine and cheap; the governor validating *instead* is not.

## 3. Fix the `execute*()` idiom here, and only here

§10 carries a low: `executeCaps()` and `executeMaintenanceWithdrawal()` execute
*whatever is pending*, so inside a multisig one signer can queue a change, a second
replace it, and an approval given for the first executes the second. The timelock
defuses it — a replacement calls `propose` again and resets the `eta` — but the
signature does not.

**This contract is new, so it does not have to inherit that.**
`executeParams(Params calldata p)` should take the parameters and require they
match the pending record — hash comparison is enough and is cheaper than a
deep struct compare.

**Do not fix `StakeRegistry`'s two.** They are inside a 33/33 mutation baseline and
that is a separate, deliberate decision. This is the pattern going forward, not a
retrofit.

## 4. `guidelinesVersion` is a measurement dependency, not just a parameter

§4.1 pins `guidelinesVersion` per case. `measurement/prior/README.md` requires it
because **cases decided under different guideline text are different experiments
and must not be pooled** — the whole `prior` measurement fragments along it.

So the governor must make a change **observable and ordered**:

- the version is **monotonic** — never reused, never decreasing;
- the **hash of the guideline text** is recorded with the version, so a reader can
  tell which text a case was decided under without trusting an off-chain label;
- an event carries both, because the measurement reads logs, not storage.

A version bump that is invisible in the logs silently splits the dataset, and the
split is only discovered when the sample turns out underpowered.

## 5. Not in scope

- **Consolidating `StakeRegistry`'s timelocks into this contract.** §10 asks
  whether they should share one; the answer is **not now** — they are built, tested
  and mutation-verified, and consolidating means touching all three again. The
  question stays open and recorded.
- Moving or duplicating the `commitBlocks` bound (§2).
- `CLAIM_BOUNTY` on `UNRESOLVED`, §8.3's 3/3 conjunct, D3-19's removal
  fee/cooldown. All still parked.
- Any open parameter value.

## 6. Acceptance

1. All v3 suites green; say the count and confirm `Moderation`'s delta is zero.
2. **The timelock's point, tested**: a proposed parameter change is visible and
   inert until `eta`, and a case submitted before it settles under the old
   parameters (I27) while one submitted after settles under the new.
3. **The swap defence of §3**: an execute naming parameters that do not match the
   pending record reverts, and a replacement resets the `eta`.
4. **`guidelinesVersion` monotonicity and its event**, including that a reader can
   recover which text a case used from logs alone.
5. **Add the governor to `SystemHandler`** — a parameter change mid-run is exactly
   the sequence the stateful invariants should survive, and I27 is the invariant
   that should hold across it.
6. Mutation campaign for the new contract; combined figures, survivors analysed,
   **INVALID reported as INVALID**. Watch the `pure`/`view` trap — you have hit it
   twice and a version-hash derivation is the same shape.
7. Sizes for all four contracts.
8. **A deploy script.** You flagged its absence yourself: the wiring order — grant
   caps, grant writer, set governor, `applyParams` — has never been executed as a
   unit, and a four-contract system whose bring-up sequence is untested is a system
   nobody has actually run.

## 7. Deliverable

One commit on **`claude/determined-curie-nkf71s`**, with the four sizes, the
mutation figures, and anything §1/§4.1/§10 could not answer.

**After this the architecture is complete**, and my recommendation is that the
independent re-audit runs against that commit. The standing constraint is unchanged
either way: no deployment with material funds and no presentation of the index as
reliable safe-search certification until it passes.
