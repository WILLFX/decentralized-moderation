# M2.6 — state of play (milestone closed, plus a post-close regression pass)

**All P0 items are closed.** The re-audit should target the **`m2.6-close` tag**.
The last code change is `51af155`; everything after it is documentation.

> **Post-close, read this first.** `m2.6-close` was independently verified, and
> that pass found **three blocking regressions in items marked closed** plus three
> fixes that no test discriminated. They are fixed on top of the tag; see the
> "Regressions found after the close" table in `specs/m2_6-work-order.md`. The tag
> is deliberately **not moved** — it is the commit the audit ran against, and
> moving it would invalidate that verification. The pointers in this file still
> name it for that reason; a new tag is cut for the fixed state. Everything from
> here down describes the state **at the tag** unless it says otherwise.

Two notes on that pointer. First, why not the last code commit: the deployed
bytecode is byte-identical between `51af155` and the close, which touches only
comments, docs and deleted test harnesses — all four contract sizes match. But an
auditor reads more than bytecode, and at `51af155` the repository actively misleads.
The resolution record below does not exist, so the deviations from the work order's
prescription look like misses. This file still describes the mid-milestone system,
including a three-contract architecture that is now four. `test/spike/` is still
present and reads as product tests. And `StakeRegistry`'s header still asserts that
obligations are unscoped aggregates and that solvency holds "only if every
authorized logic is correct" — the exact claim P0-5 falsified. Pointing a
re-auditor at a header that contradicts the fix is how a false finding gets
manufactured.

Second, why a tag rather than a hash: a commit cannot contain its own hash, so a
pointer written inside the history can never name the commit it lives in. A tag
lives outside the commit graph and has no such fixed point — and it is the
conventional handle to hand an auditor anyway.

Read `specs/m2_6-work-order.md` for the item-by-item spec; its **Resolution record**
section at the end is the authoritative account of what landed, the four places the
implementation deviates from the prescription and why, and the residuals left open
deliberately.

## Where things stand

**Branch:** `claude/determined-curie-nkf71s`, based on `main` @ `b09ce31`; open as PR #7.
**Suite at the `m2.6-close` tag:** `forge test` = **188 passing, 16 suites**, default
profile (`via_ir = true`), green at every commit. Baseline was 143 / 16.
**Suite now** (tag + the post-close regression pass): **199 passing, 16 suites**.

(The peak during the milestone was 199 / 19. The difference is `test/spike/`, three
throwaway suites that existed only to produce the gas numbers behind the
checkpointed-tree rejection, the MAX_PANEL curve and the VOID curve. Those numbers
are recorded in `contracts/GAS_BUDGETS.md` and `ProtocolLimits`; the code that
produced them is deleted, because a measurement harness that outlives its decision
becomes something a reader mistakes for a test of the product.)

**Sizes** (EIP-170 limit 24,576):

| contract | bytes | margin |
|---|---|---|
| Moderation | 23,296 | 1,280 |
| StakeRegistry | 12,876 | 11,700 |
| IndexRegistry | 5,511 | 19,065 |
| RulesetGovernor | 4,210 | 20,366 |

`Moderation` ends the milestone **smaller than it started** (23,795 -> 23,296)
despite eleven items landing in it, because the structural split gave back more
than they cost.

After the post-close regression pass: `Moderation` 24,107 (469 free),
`StakeRegistry` 12,745, `IndexRegistry` 6,174, `RulesetGovernor` 4,459. The margin
is thin again and it is the binding constraint on anything further in the game
contract.

## The architecture is now four contracts, not three

`RulesetGovernor` was split out of `Moderation` when it hit EIP-170 mid-milestone.
The seam is **authoring vs enforcement**: proposing/validating/timelocking a ruleset
is cold and validation-heavy, enforcing one is on every hot path. Ruleset *storage*
deliberately stayed in `Moderation` — `_cp()` reads it per phase transition.

A re-audit scoped to "the three-contract architecture" is scoped wrong; it is four.

## What changed, in one line each

- **Identity** is minted by the permanent registry, not by replaceable logic.
- **Dedup** lives in the registry too, so it survives a migration.
- **Legacy entries** are adjudicable through a replacement logic.
- **Duty reservations escrow real collateral**; all four bypasses are closed.
- **Eligibility changes only at fixed epoch boundaries** — constant by construction
  across any draw window, so there is nothing to grind and nothing to re-arm on.
- **Obligations are keyed** `(authEpoch, logic, moderator, caseRef)`, closing both
  cross-logic and cross-case discharge.
- **Logic contracts retire** through `SETTLE_ONLY` before revocation, and revocation
  is gated on an on-chain drain signal.
- **Every panel-scaled loop is batched**: seat draw, settlement, VOID disposal.
- **A draw that cannot complete now ends**, permissionlessly.
- **The freeze arithmetic is bounded at both ends**, including the composite product
  the old validator could not see.

## Judgment calls — don't silently reverse them

Beyond the four deviations recorded in the work order:

- **`globalId` starts at 1**, so `0` is a safe "absent" sentinel everywhere.
- **Any authorized logic may delete any entry by global id.** Deliberate: it is the
  registry-side prerequisite for cross-version removal. The *authorization* to
  remove is enforced by the game (an adjudicated removal case), not the registry.
- **`StakeRegistry.riskPerSeat` is immutable** and a ruleset may not exceed it. The
  two `riskPerSeat` values are different roles and must not be collapsed.
- **The moderator struct is the authority for what may be seated; the sortition tree
  is only the sampling distribution.** This is what makes P0-3's deferred tree
  updates safe alongside P0-2's escrow, and it is load-bearing in `drawPanel`.
- **`ProtocolLimits.MAX_PANEL` leads with which loop currently sets the bound.** It
  has moved twice; the number alone is not the useful fact.

## Traps that have already cost time

1. **`vm.prank` is consumed by an external call in the argument list.** Compute
   `mod.computeCommit(...)`, `getParams()`, `minFee()` into a local BEFORE pranking.
2. **`vm.warp`/`vm.roll` are invisible to hoisted `block.timestamp`/`block.number`
   under `via_ir`.** Always use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`.
   The failure is silent.
3. **Stack-too-deep** in the settle loop. It is at the IR limit — this is why P0-5's
   `caseRef` is stamped on the Round rather than threaded through the helpers.
4. **`indexed` is a reserved word**; the case flag is `isIndexed`.
5. **A widen returns the round to `DRAW`** (fresh entropy). Drive loops must handle
   `DRAW` mid-round.
6. **Fixtures can go quiet.** The invariant campaign once silently stopped
   adjudicating cases while reporting zero reverts. There is an anti-vacuity test.
7. **New in M2.6:** weight staged in an epoch is not drawable until the next
   boundary, so any fixture that stakes and then expects a draw must call
   `_settleEpoch`. And a seed whose window would straddle a boundary is DEFERRED,
   so rolling a fixed `SEED_LAG + 1` is no longer enough — use `_rollToSeed`.

## The standing lesson, updated

Two milestones running, the lesson was *a safety property written in a comment
instead of enforced in code*. M2.6 adds a second one: **an aggregate is not an
identity.** Every P0 here reduces to the same shape — a caseId that was local where
it had to be global, a dedup map that died with its contract, a collateral pool that
could not say which case it backed, a version counter standing in for an epoch.
Conservation held throughout all of them, which is exactly why they were invisible.
Conservation is necessary and never sufficient.

The post-close pass added two more, both of the same family:

- **A gate on one of two registries is not a gate.** `StakeRegistry.canRevoke` was
  correct and useless on its own: a case's final step touches both registries, so
  revoking the ungated one stranded the case *and* pinned the gated one shut
  forever. Check the whole boundary, not the half you built first.
- **Bounded work followed by a revert is no work.** The epoch drain did 64 items
  and then reverted if that was not enough, discarding them. It looked like
  progress-plus-backpressure and was actually a permanent stall. If a function may
  revert, it must not be the one making the progress.

And one about tests rather than code: **three fixes could be reverted with the
suite green.** A fixture that cannot distinguish the old behaviour from the new is
not coverage, however green it is — the H-09 fixture used one address holding one
seat, which satisfies "count revealers" and "count seats" identically.

Two bugs in this milestone were found by reading rather than by a failing test — the
cross-case escrow drain (written in P0-2, caught in P0-5) and the commit path
measuring the wrong bucket after the escrow moved. Both were invisible to the suite
because the fixtures were too generous to reach them.

## Standing recommendation

No deployment with material funds, and the index is not presented as reliable
safe-search certification, until an independent re-audit of the **four-contract**
architecture passes against the **`m2.6-close`** tag.

Point the re-auditor at:
1. This file and the work order's Resolution record — the deviations especially.
2. `contracts/GAS_BUDGETS.md` — every bound is measured, and it records which loop
   sets each one.
3. `StakeRegistry`'s header "what this does NOT yet guarantee" section, which was
   written before P0-5 and should be re-read now that obligation scoping has landed.

The open P1/P2 items are listed in the work order. **P1-1 (widen seats bypass
escrow) is the most substantive**: it is the one remaining place a seat can exist
without backing.
