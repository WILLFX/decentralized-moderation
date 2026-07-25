# M2.6 — state of play (session handoff)

Read this first, then `specs/m2_6-work-order.md`, which is the actual spec and is
already merged from both audits with verified line references.

## Where things stand

**Branch:** `claude/determined-curie-nkf71s` (restarted from `main` @ `b09ce31`
after PR #6 merged). **Baseline: `forge test` = 143 passing, 16 suites**, default
profile (`via_ir = true`). Reproduce that number before touching anything.

**Sizes** (EIP-170 limit 24,576):

| contract | bytes | margin |
|---|---|---|
| Moderation | 23,795 | **781** |
| StakeRegistry | 8,977 | 15,599 |
| IndexRegistry | 4,287 | 20,289 |

### Done

- **P0-4** (`d1317c1`) — `reward()` pulls its own funding and verifies the measured
  balance delta. Closed the only path to minting withdrawable claims. `Moderation`
  now approves-then-calls instead of pre-transferring.
- **P0-1a** (`81ef77e`) — the Critical's corruption mechanism. `IndexRegistry` mints
  a permanent `globalId`; the position map is keyed by it; entries carry
  `originLogic` / `localCaseId` / `rulesVersion` / `guidelinesVersion` provenance.
  `Moderation` records the minted ids (`Case.entryIds`, view `caseEntryIds`) and
  deletes by them.

### Next, in order

1. **P0-1b — registry-owned dedup.** Dedup still lives in `Moderation`
   (`dedupOwnerPlusOne`), so a replacement logic starts with an empty map and will
   accept content already live in the permanent index. Move the reservation into
   `IndexRegistry`, keyed to the permanent entry/content generation.
2. **P0-1c — end-to-end legacy removal.** `submitRemoval` resolves its target through
   the *current* logic's `cases[targetCaseId]`, so a new logic has no public path to
   adjudicate an entry written by a superseded one. The registry now *permits* it
   (any authorized logic can delete any `globalId`); the game does not *expose* it.
   Note the continuation audit's sharp catch: the M2.5 test that appeared to prove
   cross-version removal was impersonating the logic address and calling the registry
   directly. Do not repeat that — the test must go through `Moderation`'s public API.
3. **P0-2** duty escrow (four bypasses — see the work order; one of them was created
   by the M2.5 partial-commit fix).
4. **P0-3** eligibility epochs, **P0-5** retirement lifecycle, **P0-6** bounded DRAW
   terminality, **P0-7** batched VOID, **P0-8** freeze arithmetic bounds.

## Judgment calls made so far — don't silently reverse them

- **`globalId` starts at 1**, so `0` is a safe "absent" sentinel everywhere.
- **Any authorized logic may delete any entry by global id.** That is deliberate: it
  is the registry-side prerequisite for P0-1c. The *authorization* to remove is
  enforced by the game (an adjudicated removal case), not by the registry.
- **`StakeRegistry.riskPerSeat` is immutable** and `Moderation._validateParams`
  rejects any ruleset with a larger `riskPerSeat`. The two values are different roles
  (duty-unit worth vs per-case lock) and must not be collapsed — collapsing them
  breaks H-11 per-case pinning.
- **`StakeRegistry`'s header documents what is NOT yet guaranteed** (unscoped
  obligations during handover). Tighten that text as P0-5 lands; do not delete it.

## Size is becoming a real constraint

781 bytes of headroom. P0-1b/1c, escrow buckets, epochs and a retirement state
machine all add code to `Moderation`. **Expect to hit the limit mid-milestone.** The
size-reduction pass (recorded in `m2_5-port-work-order.md`) has moved from hygiene to
likely-blocking; the natural seam is moving governance or settlement coordination
into its own module. Measure with `forge build --sizes` after every item so you find
out early rather than at the end.

## Traps that have already cost time

1. **`vm.prank` is consumed by an external call in the argument list.** Compute
   `mod.computeCommit(...)`, `getParams()`, `minFee()` into a local BEFORE pranking.
2. **`vm.warp`/`vm.roll` are invisible to hoisted `block.timestamp`/`block.number`
   under `via_ir`.** Always use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`. The
   failure is silent — more tests break than fail. The rule is documented in
   `StackDeployer.sol` and the README.
3. **Stack-too-deep** in `_settleInit` — cache `Params storage p = _cp(c)` once.
4. **`indexed` is a reserved word**; the case flag is `isIndexed`.
5. **A widen returns the round to `DRAW`** (fresh entropy). Drive loops must handle
   `DRAW` mid-round; guards need ~24 iterations.
6. **Fixtures can go quiet.** The invariant campaign silently stopped adjudicating
   cases when the duty pledge became a draw precondition, and reported zero reverts
   across 65,536 calls while doing nothing. There is now an anti-vacuity test — if you
   change draw eligibility again, re-check that the campaign still settles cases.

## The standing lesson

Two milestones running, the same failure: **a safety property was written in a
comment instead of enforced in code.** `reward()` said "caller must transfer first"
and checked nothing. Every item must end in a contract-level invariant plus a test
that fails on the pre-fix code. "Conservation still holds" is necessary, never
sufficient.

## Standing recommendation — unchanged

No deployment with material funds, and the index is not presented as reliable
safe-search certification, until P0 closes and an independent re-audit of the
three-contract architecture passes against a named commit. The last re-audit attempt
reviewed pre-M2.5 code and produced a stale replay; point the next one at a specific
commit and tell it what has already landed.
