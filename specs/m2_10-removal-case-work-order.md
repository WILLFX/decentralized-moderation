# M2.10 Work Order — the removal case

**Base:** `main` @ `1d399c2`.
**Branch:** **`claude/determined-curie-nkf71s`** — same branch. This is the correct
branch and has been since M2.7; your standing instruction naming
`claude/m2-6-work-order-5amy1q` is stale, and I should have said so two orders ago.
**Normative:** `specs/state-machine-v3.md` §8.4, §8.5, §8.1 @ `1d399c2`.

**This is D3-15, and it is now the P0.** You escalated it and asked whether it
outranks `RulesetGovernor`. **It does, by a wide margin** — the reasoning is in
§8.5 and §10 at the base commit, and the short version is below.

---

## 1. The ruling, so the priority is not re-litigated

A listing is **permanent**. §8.4 withholds re-review from `APPROVED` on the
assumption that a removal case serves instead; the removal case cannot be created;
`APPROVED` is *reserved while listed* so resubmission is closed; and the
reservation clears only on `REMOVED`, which nothing can produce.

**Worse than the permanence §8.6 calls decisive**, on every axis:

| | rate at `prior` 0.665 | recourse |
|---|---|---|
| irrecoverable false **rejection** (§8.6) | 22.8% | — (it *is* the irrecoverable share) |
| permanent false **approval** (FINDINGS §A) | **28.6% at `q = 0`**, 60% at `q = 0.30` | **none** |

And it is the failure a safe-search index exists to prevent: a wrong rejection
withholds something that should have been shown; a wrong approval **shows something
that should not have been**.

The index side is already built and tested for this — §8.1's fifth write and half
of §8.3's `openQuestions` are implemented and unreachable. **This order makes them
reachable.**

## 2. What to build

`actionType` becomes a real parameter of a case.

```
actionType ∈ { LIST, REMOVE }              -- §8.5
claimKey = H(actionType, contentHash, metaHash, topics)
```

**`claimKeyOf` must take the action type**, not hardcode `"LIST"`. A removal case
therefore earns its own key and its own reservation, exactly as §8.5 says, and the
two questions about one piece of content do not collide.

**`policyVersion` stays out of the key** (§8.4). Do not add it while you are in
there.

### 2.1 The verdict means something different, and nothing else changes

A removal case asks *"should this be removed"*. So `verdict == Approve` means
**remove it**. §8.5: *"it runs the same engine"* — same cohort, same `â`, same
three tickets, same challenge round, same settlement. **Do not fork the engine.**
`actionType` changes what the answer is *about*, never how it is reached.

### 2.2 The fifth write (§8.1)

```
DRAW -> FINALIZED, actionType == REMOVE, verdict == Approve
     -> ALSO set the LIST entry for the same (content, topic) to REMOVED,
        and drop it from the topic's enumerable listing
```

Both entry keys are content-derived (§8.2b), so the `LIST` key is **computable**
from the removal case's own fields. Do not store a pointer.

A removal that **fails** writes its own entry and touches nothing else —
`RETAINED` is the case's terminal, not an entry status (§8.2).

### 2.3 `openQuestions` (§8.3)

Increment when a removal case **opens** against listed content; decrement at its
terminal. You already wired the re-review half; this is the other.

### 2.4 The reservation

A successful removal must clear the `LIST` claim's `LISTED` reservation — that is
what makes the content resubmittable, and it is the exit the circle currently
lacks. Say in `DEVIATIONS.md` what it clears to and why.

## 3. What I have not decided, and want you to surface rather than resolve

Three questions this opens that §8 does not answer. **Report them; do not settle
them in Solidity.**

1. **Who pays for a removal case, and is it refunded on success?** §8.5 says it
   *"earns its own key"* and costs a fee. It does not say whether a successful
   removal — which corrects a protocol error — should refund the party who caught
   it. Both readings are defensible and the choice is an incentive, not a detail.
2. **Is there a cooldown between removal attempts on one listing?** §8.5 leaves the
   re-review cooldown open for the same reason (cohort attention is scarce, §10),
   and removal has the identical shape. An uncapped removal is a griefing surface
   against a legitimately listed item.
3. **Can a removal case be opened against content that is not listed?** It should
   revert, but §8 never says so, and the guard is not obviously in either contract.

## 4. Not in scope

- `RulesetGovernor`. Deferred by §1's ruling.
- §8.3's 3/3 conjunct, `CLAIM_BOUNTY` on `UNRESOLVED`, the `execute*()` argument
  idiom. All still §10's, all still deliberately parked.
- Any open parameter.

## 5. Acceptance

1. All six v3 suites green; say the count.
2. **The circle, closed end to end and as one test**: list content, open a removal,
   carry it to a successful terminal, assert the `LIST` entry reads `REMOVED`, that
   it has left the topic's listing, that `SUPER_SAFE` is false throughout the open
   question and stays false after, and that the content is now resubmittable.
3. **The failing removal**, asserting the `LIST` entry is untouched and still
   listed.
4. **Key separation**: a `LIST` and a `REMOVE` case on identical content produce
   different claim keys and different entry keys, and neither reservation blocks
   the other.
5. **Add the removal path to `SystemHandler`** so the stateful invariants cover it.
   This is the point of having built that suite — a new case type that the fuzzer
   cannot reach is a new case type nobody is testing properly.
6. Mutation campaigns re-run for `Moderation` and `IndexRegistry`; combined
   figures, survivors analysed, **INVALID reported as INVALID**.
7. Sizes for all three contracts; `GAS_BUDGETS.md` for the removal path.

## 6. On the two harness corrections

Both were the right call and I want that on the record, because the second one cost
you a round of rework you could have quietly skipped.

**Finding that `M41` had never compiled — and then finding that the fix had only
reached one of three harnesses — is worth more than the scores it corrected.** A
mutation aimed at a `pure` function is exactly where that bug lives, because the
interesting mutations there are the ones that introduce a state read. Two instances,
same class, and the second only surfaced because you went back to check your own
correction.

Carry that discipline into this order. The `strict` bit and the fifth write are both
places where a mutation would naturally introduce a state read into a `pure` key
derivation.
