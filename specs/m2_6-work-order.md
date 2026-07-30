# M2.6 Work Order — Registry-Boundary Remediation

**Base:** `main` @ `b09ce31` (PR #6, M2.5 merged).
**Branch:** `claude/determined-curie-nkf71s` (restarted from `main`; the prior PR merged).
**Trigger:** Independent fresh-eyes audit of `main` @ `b09ce31` — 1 Critical, 9 High,
1 High-economic, 10 Medium. Every Critical/High cited below was **reproduced against
the actual code before this order was written**; line references are from `b09ce31`.

## Status of the audits

Both audits reviewed the same commit, `b09ce31`. **This work order merges them.**

- **Fresh-eyes audit.** No prior context. Verified 8/8 on the points checked.
- **Continuation audit.** Knew the July findings; includes a status table for all 22
  of them. Verified 4/4 on its unique findings.
- *(An earlier "continuation" attempt was a stale replay of the July review against
  pre-M2.5 code and was discarded. The real one arrived afterwards and is used here.)*

### Do they conflict? No — and that is the useful result

They were compared finding-by-finding specifically to check for fixes pulling in
opposite directions. **On every point both cover, they agree** — same root cause,
same prescribed direction (global identity, real duty escrow, eligibility epochs,
bounded terminality, per-batch keeper pay, exclusion on widen). Neither prescribes
anything the other forbids. What differs is *coverage*, and each caught real things
the other missed:

**Fresh-eyes found, continuation missed:**
- `reward()` credits unfunded stake (the only path to minting withdrawable claims).
  **Already fixed — M2.6-P0-4, commit `d1317c1`.**
- "uncontested" semantics conflict between README and code.

**Continuation found, fresh-eyes missed** (all four verified against the code):
- **VOID is still atomic** — `_void()` loops `seatHolders` with no cursor, and it is
  called *inside* `closeReveal`, so exceeding gas reverts the transition and strands
  the case in expired REVEAL. Settlement was batched; VOID was not. → **P0-7**
- **`freezeCap` has no upper bound** (`Moderation.sol:1522` checks only `< WAD`), so
  accepted parameters can overflow `FreezeMath` inside `_settleInit` and make every
  settlement attempt revert. → **P0-8**
- **A fourth duty bypass: partial commit.** `commitVote` reduces `s` to what the
  moderator can afford and still sets `committed[msg.sender] = true`, so settlement
  takes the committed path and the unbacked seats get **no disposition at all**
  (assigned 10, afford 1 → 9 seats vanish penalty-free). This is a hole *created by*
  the M2.5 partial-commit fix. → folded into **P0-2**
- **`MAX_PANEL = 512` is not evidence-based** — the largest measured draw is 47 seats
  at ~4.39M gas. → **P1-3**

Continuation also sharpened three items: widening **reopens commit/reveal windows to
earlier nonparticipants** (optional-stopping across tranches, not just inert seats);
**freeze expiries differ by settlement batch** for participants in the same case; and
a **revoked logic still accepts fees**, becoming a permanent fee trap with no refund
path.

**Neither audit's fixes need to be undone or reworked for the other.** Where the
continuation is more complete (duty bypasses, retirement lifecycle), take its version.

## What M2.5 got right (independently confirmed)

The fresh auditor had no knowledge of the July findings yet independently endorsed
per-case ruleset pinning, commitment domain separation, hard phase windows, fresh
entropy per widen, pull-based appeal payouts, batched settlement, and
transfer-before-credit reward ordering. The seventeen July findings are closed. Do
not re-litigate them.

## The one sentence that matters

**M2.5 moved the bugs to the boundary it created.** Identities are local where they
must be global; liabilities are aggregate where they must be obligation-scoped;
funding rules are written in comments where they must be enforced in code; selected
collateral stays user-mutable where it must be escrowed; and the live draw tree is
treated as an epoch snapshot when it is nothing of the kind.

Note the recurring failure: *the safety property was documented instead of enforced.*
`reward()` carries the comment "caller must transfer the tokens first" and no check.
Every item below must end in a contract-level invariant, not a doc line.

## Rules

1. One work item per commit, `M2.6-<ID>: <summary>`, in the order below.
2. `forge test` green at every commit (baseline **140**, 16 suites, under the default
   `via_ir` profile). No test-count regression.
3. Each item ships the regression test named in it, and the test must fail on the
   pre-fix code. Verify that ordering explicitly.
4. Where an item overturns a DEVIATIONS entry, strike it in the same commit and cite
   the finding.
5. Both conservation identities must hold after every item:
   `balanceOf(Moderation) == openPotsTotal + totalPendingBond + totalPendingPayout + totalSettling`
   and `balanceOf(StakeRegistry) == stakeReg.stakeBuckets()`.

---

## P0 — deployment blockers

### P0-1. CRITICAL — the permanent index has no global identity

**Confirmed.** `IndexRegistry` keys entries by `(topicKey, caseId)`
(`entryPosPlusOne[topicKey][caseId]`, `IndexRegistry.sol:108`), and `caseId` comes
from each logic contract's own `nextCaseId++` starting at 0 (`Moderation.sol:301,434`).
A replacement logic's first case therefore collides with the original logic's first
case: `writeEntry` appends and **overwrites the reverse-map slot**. The older entry
becomes a ghost — still returned by `entryAt`/pagination, reported absent by
`isIndexed`, and no longer deletable by its identifier. Removal across versions is
impossible anyway: `submitRemoval` resolves the target through the *current* logic's
`cases[targetCaseId]`. Dedup also restarts, since it lives in `Moderation`.

The M2.5 migration test creates exactly this precondition and only asserts the array
length reached two.

**Fix.** Registry-owned identity. `IndexRegistry` mints
`globalEntryId = nextEntryId++` and stores at least `originLogic`, `logicEpoch`,
`localCaseId`, `rulesVersion`/`guidelinesVersion`, plus the existing fields.
Deletion and removal target `globalEntryId`. `writeEntry` must **reject** a reused
global ID rather than overwrite. Move the live-content dedup key into the registry
(or expose a permanent content-generation id) so it survives migration.

**Tests.** Two logics each write their local case 0 → distinct global IDs, both
independently deletable, neither ghosted; a legacy entry is removable through the new
logic; identical content cannot be re-indexed after migration.

*(Verified 2026-07: all three hold. Claim 1 is asserted inside
`Migration.test_live_migration_preserves_stake_and_index` — same `localCaseId`,
distinct `globalId`, both `isIndexed`, deleted one at a time with no ghost left.
Claims 2 and 3 are `test_legacy_entry_is_removable_through_the_new_logic` and
`test_identical_content_cannot_be_reindexed_after_migration`. Every name on this
line refers to something in `src/`.)*

### P0-2. Duty reservation must escrow real collateral

**Confirmed.** `drawPanel` increments `dutyReserved` but moves no tokens; the seat's
collateral stays in `free` and stays user-controlled. `penalizeNoShow`
(`StakeRegistry.sol`) opens with `if (m.dutyUnits == 0) return;` and computes
`usable = free − pending − exitAmount`. So a selected moderator escapes the penalty
entirely by either calling `setDutyUnits(0)` (no check that `dutyUnits >= dutyReserved`)
**or** `requestExit(free)` — the exit need not complete. The no-show penalty is the
stated defence against appeal-panel obstruction (H-10); it currently costs nothing.

**Fix.** A distinct `dutyBonded` bucket. At draw, move `riskPerSeat` per reserved seat
`free → dutyBonded`. `dutyBonded` is not exitable, not reducible by `setDutyUnits`,
not available to other cases. Commit converts `dutyBonded → committed`; no-show
freezes it directly; release returns it to `free`. Minimum acceptable alternative if
the bucket is deferred: enforce `dutyUnits >= dutyReserved` and
`exitAmount <= free − dutyReserved * riskPerSeat` — but the bucket is far easier to
prove.

**Two further bypasses (continuation audit) — the fix must close all four:**

3. **Partial commit excuses the unbacked seats.** `commitVote` reduces `s` to what
   the moderator can afford and still sets `committed[msg.sender] = true`, so
   settlement takes the committed path and the remaining assigned seats receive **no
   disposition** — assigned 10, afford 1, and 9 seats disappear penalty-free. This
   hole was *created by* the M2.5 partial-commit fix: it solved the liveness problem
   (a min-stake holder drawn twice could not commit at all) and opened a penalty
   problem. Both must hold: partial commit stays possible, unfulfilled assignments
   still get penalised and released.
4. **Backing is consumed elsewhere.** Because nothing is escrowed, the same free
   stake can back several outstanding assignments, be locked by whichever case
   commits first, or be exit-reserved. The tree stops issuing *new* duty once
   capacity is reserved, but nothing protects the stake behind assignments already
   made.

**Tests.** *(Corrected 2026-07 — one of the four named cases describes behaviour
that was deliberately not built. See deviation #1 in the resolution record.)*

- Post-selection `setDutyUnits(0)` → `test_bypass_setDutyUnits_zero_after_selection`.
  The un-pledge is refused (`DutyReserved`), the escrow survives, and the penalty
  applies.
- Post-selection `requestExit(all free)` →
  `test_bypass_requestExit_after_selection`. The exit cannot reach the escrow, and
  a completed `withdraw()` does not carry it out.
- Cross-case consumption of the same backing →
  `test_bypass_same_backing_cannot_cover_two_assignments`, with
  `test_settling_one_case_cannot_drain_another_cases_escrow` and
  `test_release_returns_escrow_exactly_once` covering the double-spend direction.
- **`commit-one-of-ten` does NOT "leave the penalty payable and applied", and no
  test asserts that it does.** Bypass 3 was closed *structurally* rather than by a
  penalty: once a seat is only issued when its collateral can be escrowed, every
  assigned seat is backed and `commitVote` commits all of them, so a partial commit
  is unreachable through the draw. Building the penalty path would have been dead
  code. `test_H07_overdrawn_moderator_commits_what_it_can_afford` exercises the
  clamp itself using `__injectWidenSeats` — a harness that bypasses the registry —
  and `test_every_drawn_seat_is_backed_by_its_own_escrow_at_commit` asserts the
  invariant that makes the production case unreachable. The counter this line
  implied (`unbackedSeats`) was deleted in `M2.6-P0-2b`.

### P0-7. VOID must be batched like settlement

**Confirmed.** `_void()` loops the entire `seatHolders` array with no cursor, calling
the registry to freeze/penalise and release duty for every address, then refunds the
submitter — all in one transaction. Settlement was batched in M2.5; VOID was not.
Worse, `_void()` is invoked *inside* `closeReveal()`, so if it exceeds the block
limit the whole transition reverts and the case is stuck in an expired REVEAL with no
other exit. An adversarially widened depth-0 panel reaches this directly, and P1-3's
validator gap makes far larger panels configurable.

**Fix.** A `VOID_SETTLING` phase with the same bounded participant cursor as
`SETTLING`. `closeReveal` must never do unbounded work.

**Test.** A depth-0 VOID at the maximum *accepted* configuration completes in bounded
batches; each batch under the ceiling; the submitter is refunded exactly once.

### P0-8. Bound the freeze arithmetic

**Confirmed.** `_validateParams` checks only `freezeCap < WAD` (`Moderation.sol:1522`)
— a lower bound, no upper bound. `FreezeMath` computes `(freezeCap − WAD) × oneMinusExp`
and then `freezeBase × power` with checked arithmetic, and `_settleInit` calls it
*before* the case reaches a recoverable state. An accepted-but-large `freezeCap`
therefore makes every settlement attempt revert permanently. `MAX_FREEZE` bounds
`freezeBase` and `failedRevealFreeze` but not the amplified result.

**Fix.** Validate both `freezeCap <= MAX_FREEZE_MULTIPLIER` and
`mulDiv(freezeBase, freezeCap, WAD) <= MAX_FREEZE`. Use full-precision `mulDiv` in
`FreezeMath` and defensively clamp the returned duration, so a future validation slip
cannot brick settlement.

**Test.** The maximum accepted freeze configuration settles; a configuration that
would overflow is rejected at proposal time.

### P0-3. Replace the pseudo-epoch with a real one

**Confirmed, broken in both directions.**
*Griefing:* `setDutyUnits` bumps `eligibilityAddVersion` whenever `units > 0` with no
check that the value changed or that weight actually grew — so any pledged moderator
can call `setDutyUnits(sameValue)` after each seed matures and force **every** pending
case to re-arm, indefinitely, for gas. The counter is global, so one actor stalls all
cases. `activate`/`thaw` bump unconditionally too.
*The attack it was meant to stop is still open:* `release`, `reward`, and
`releaseDuty` all add draw-eligible weight and bump the version **zero** times
(verified). Weight removals (`setDutyUnits(0)`, `requestExit`) also don't bump — and
the M2.5 note calling that a benign one-directional residual is wrong: removing an
interval remaps the whole weighted tree, so it is grinding over tree states, not
self-exclusion.

**Fix.** Genuine eligibility epochs. Stake/duty changes made in epoch `e` take effect
in `e+1`; each case pins an epoch root at arm time; all draws for that seed use that
immutable root; no live operation can mutate it. Delete `eligibilityAddVersion`.
Strike the D-8 residual note.

> **H-03A / H-03B — reopened twice, closed in `M2.6-P0-3d`.**
>
> **The property, stated once and in the form that is actually satisfiable.** For
> any post-seed action A with subject x, let S and S′ be the seat sequences without
> and with A. Restricted to addresses other than x, S and S′ must agree position by
> position for as far as the shorter one runs. A shorter run may extend; it must
> never diverge. Sequences are compared **with multiplicity**, not as sets.
>
> The stronger reading — "no third party is affected at all" — is not a stricter
> target, it is an inconsistent one. The panel is capped at `count`, so any action
> that makes x more seatable necessarily takes a slot the fixed sequence would have
> carried further down. Forbidding that means forbidding post-seed seatability
> change entirely, i.e. snapshot seatability, which breaks P0-2.
>
> **Accepted consequence: cut-point mobility.** Prefix-relation confines all
> divergence to the tail. An attacker can therefore move the CUT POINT — becoming
> seatable displaces the last accepted third party; becoming unseatable extends the
> run and adds one. It can never substitute one third party for another in the
> middle. The capability is priced by stake share, not by identity count: an
> attacker cannot choose *where* in the walk it appears, only whether to convert an
> appearance into a seat, so expected displacements ≈ f × (attempts to fill), and
> every seat it takes costs escrow plus commit/reveal or the no-show penalty.
> Accepted, and recorded here rather than discovered in a later round.
>
> **What was wrong, in two rounds.**
>
> *H-03A (downward).* P0-3 froze the sortition tree between epochs and concluded
> eligibility was "constant by construction, so there is nothing to grind". The tree
> was constant; the SEATABLE SET was not. `drawPanel` read the live struct to decide
> seatability — correct, and required by P0-2 — and removed a rejected address with
> `stakeTree.set(seat, 0)` to save attempts. That remapped every later interval. So
> an unseated holder could zero its duty, or `requestExit(free)`, after its seed's
> blockhash was public and steer the panel.
>
> *P0-3c closed two levers, not the property.* It suppressed the tree write for
> voluntary reductions. Two classes survived it:
>   - **the exhaustion asymmetry**, still downward: a moderator seated to its
>     capacity limit triggered the exclusion, one that had cut was never seated and
>     so never removed. Two trees, third parties move. Cheapest at
>     `riskPerSeat == MIN_STAKE`, where a minimum-stake identity exhausts on its
>     first seat.
>   - **H-03B (upward), across batches.** `DRAW_SEATS_PER_BATCH = 24`, so a panel
>     above that returns to the caller with the seed and batch 1's seats both
>     public. `setDutyUnits` upward, `activate`, `thaw` and `claim` on another case
>     each RAISE a live seatability input, changing acceptance in batch 2 — and
>     `voluntaryCutEpoch` did not apply, because none of them are reductions. The
>     comment asserting that raising capacity is not a lever was true within one
>     `drawPanel` call and false across batches.
>
> **The fix is one sentence: `drawPanel` performs no writes to `stakeTree`.**
> Verified by inspection — the tree is written in exactly two places, `initialize`
> and `_drainEpochs` at a boundary — so the sortition tree is now immutable for the
> whole of an epoch, which is the property P0-3 claimed and never had.
>
> Everything else follows. `addr(i) = draw(keccak(seed, offset + i))` depends on the
> seed, the attempt index and the tree; all three are fixed before the seed becomes
> public, pinned by three interlocks: `_armSeed` keeps a seed's window inside one
> epoch and `realizeSeats` re-arms if the epoch turns over; the cursor accumulates
> ATTEMPTS, so batches are contiguous segments of one walk; and the tree cannot
> move. Live seatability inputs feed only accept/deny, which changes how far the
> walk runs and never what the walk is. **A freeze closes with them** — it still
> denies, so a penalised moderator is never seated, and it stops being the remap
> lever P0-3c had to carve out as an accepted residual.
>
> **`voluntaryCutEpoch` is deleted.** With no write to suppress it had nothing left
> to do, and a superseded mechanism with a live write path reads as defence it no
> longer provides — the K-4 reasoning.
>
> **Rejected alternatives, with the reasoning.** *In-memory exhaustion accounting
> during descent*: subtracting excluded weight during descent moves the interval
> mapping exactly as a tree write does — it saves SSTOREs, not information — and
> even offer-based in-memory exclusion leaks across batches, because batch 2's start
> offset is attempts-consumed by batch 1, which denials change. *Persisted
> offer-based exclusion* is sound (cumulative offers are a function of the fixed
> walk) and was measured head-to-head; it produced identical fill in every scenario
> at +0.6M to +3.2M gas, because `cap ∝ weight` means it cannot fire until `count`
> approaches total network capacity. Rejected on evidence. *Snapshot seatability
> with escrow pre-reserved at the boundary* would satisfy P0-2, but it turns a duty
> pledge from an offer into a standing hard lock of full pledged capacity — a
> product decision about capital efficiency and participation, out of scope — and
> its force-unpledge branch would reintroduce the downward lever.
>
> **`ATTEMPTS_PER_SEAT`: 2 → 6, measured.** Not seating an unseatable address means
> it can be drawn again, so the budget pays for it. 6 was chosen against a
> pre-committed bar (P99 fill ≥ 95%, batch under 80% of the 8M ceiling) across
> ordinary load, honest churn at 10%, adversarial absorbers at 30% and 50%, a
> post-settlement frozen cohort of 47, and a scarce network. It is FREE in every
> dense case: the panel fills long before the cap binds, so gas at 6 equals gas at
> 2. Documented breaking point: usable capacity ≈ the seat target, where filling is
> coupon-collector-bound and no budget helps.
>
> **The P0-3c documentation gap, recorded here because it was never measured.**
> P0-3c changed what an attempt means — it left cutters in the tree absorbing
> attempts — and did not re-derive `maxAttempts`, which had been sized when every
> unseatable address was removed. Measured now: at the agreed f = 0.3 bar, P0-3c is
> **adequate** (0/100 short panels in a dense network). It degrades at f = 0.5
> (51/100 short) and, in a scarce network at 25% absorbing capacity, introduced a
> 4/100 short-panel rate where the pre-P0-3c behaviour was 0/100. The severe scarce
> case (40% absorbing, usable capacity == target) is 95/100 short even pre-P0-3c, so
> that one is scarcity, not P0-3c. No separate exposure record was warranted; the
> measurement is the record. Under P0-3d the same scarce cell returns to 0/100.
>
> **Constants re-derived**, since the loop changed: the seat-draw batch came out
> slightly cheaper (3,746,905 → 3,664,261 gas) and the 47-seat/1000-moderator row
> likewise (7,201,469 → 7,039,728), so `MAX_PANEL = 128` and
> `DRAW_SEATS_PER_BATCH = 24` both stand.
>
> **Tests.** Six discriminate against the pre-fix code: the exhaustion asymmetry
> (asserting the subject was seated at a NON-FINAL position, or nothing follows it
> to remap); a multi-unit variant so the fix cannot special-case the minimum-stake
> path; `thaw` between batches, driven through `realizeSeats`; panel fill under 25%
> absorption; the pre-draw-walk subsequence guard; and the deleted-selector guard.
> Two are labelled guards rather than discriminators and say why in the test:
> batching transparency (which the old restore loop also satisfied) and
> `setDutyUnits` upward (which P0-3c's flag happened to cover, because the subject
> had flagged itself on the way down).

### P0-4. `reward()` must be funded atomically

**Confirmed.** `StakeRegistry.reward()` increments `free` and `totalFreeStake` with no
`transferFrom`, no balance-delta check, no surplus check, no case binding. Honest
`Moderation` transfers first — but the registry does not require it, and the test
pre-mints manually. Any authorized logic (old, new, buggy, or malicious) can mint
withdrawable claims from nothing: `reward(attacker, X)` then `requestExit(X)` then
`withdraw()` drains real stakers' tokens. `requestExit` doesn't even require
`m.exists`.

This makes "the registry isolates principal from replaceable logic" false as written.

**Fix.** `reward` pulls its own funding: measure `balanceOf` before/after a
`transferFrom(msg.sender, ...)` and require the exact delta; or track
`surplus = balance − liabilities` and cap credits by it. Prefer the pull — it also
catches wrong-token funding. Update the trust-model docs to state what the registry
actually guarantees.

**Test.** An authorized-but-unfunded `reward` reverts; conservation cannot be broken
by a hostile logic contract.

### P0-5. Obligation-scoped registry accounting

**Confirmed.** During handover both logics are authorized, and `lock`, `release`,
`freeze`, `releaseDuty`, `setTrack`, `reward` carry no obligation id and no
originating-logic namespace — only aggregates. So logic B can release stake committed
by logic A, freeze A's committed stake under B's case, release A's duty reservations,
or overwrite track A expects; A's later honest settlement can underflow and revert.
`releaseDuty` silently clamps rather than surfacing double release. There is no
on-chain `canRevoke(logic)` — revocation relies on governance *believing* the old
logic drained, and old `Moderation` has no retirement mode, so users can keep opening
cases during the supposed drain.

**Continuation audit sharpens this into a retirement lifecycle.** Three further
facts, each verified: revoking a live logic *strands* its cases (its pot, its
committed stake, its duty reservations, its unpaid appeal contributors — the new
logic cannot settle them because the case storage lives in the old contract); the old
logic cannot be made settle-only, so an attacker can keep opening cases in it and it
never provably drains; and a **revoked** logic still accepts fees, since `submit`
never checks its own authorization — every retired contract becomes a permanent fee
trap with no refund path. `openPotsTotal` is decremented at settlement *init*, so it
is not a valid drain signal either.

**Fix.** Creator-scoped obligation handles
(`keccak256(logicEpoch, logic, caseId, depth, moderator)`); only the creating logic
may release or freeze its own obligation. Per-logic open-obligation counters and an
on-chain `canRevoke(logic)`. A `RETIRING` mode on the logic that rejects new
submissions while preserving settlement.

Add logic states `NONE | OPEN_AND_SETTLE | SETTLE_ONLY`, moved atomically across
**both** registries (they are governed independently today, so a logic can be
authorized in one and not the other — a case can then settle its stake and fail its
index write). `submit`/`submitRemoval` must reject when not `OPEN_AND_SETTLE`.

**Tests.** *(Corrected 2026-07 — as originally written this line claimed more than
was built, and named a function that does not exist. What follows is what is
actually scoped and actually tested; see `test_cross_logic_discharge_reverts`.)*

- **`release` and `freeze` revert** `NotYourObligation` cross-logic and cross-case.
  Both take a `caseRef` and go through `_debit`.
- **`lock` writes into the caller's own namespace** — a handle keyed by
  `(authEpoch[msg.sender], msg.sender, moderator, caseRef)` — so it cannot add to
  another logic's obligation.
- **`settleDuty` does not revert cross-logic; it clamps to the caller's own
  (empty) obligation and is a no-op.** That is the correct behaviour — settlement
  must never be able to fail on a foreign call — but it is not a revert, and the
  test asserts the victim's escrow is untouched rather than expecting one.
- **`releaseDuty` no longer exists.** It was folded into `settleDuty` in
  M2.6-P0-2, because penalising and releasing must share one clamp against one
  balance. Its sibling `penalizeNoShow` was deleted in M2.6-P0-5c.
- **`setTrack` is NOT scoped and there is no such test.** It takes no `caseRef` and
  performs an absolute write (`StakeRegistry.sol:571`), so `onlyLogic` is the only
  gate — which blocks a revoked logic and nothing else. During a handover both
  logics are authorized, so B can overwrite any moderator's track. This is
  **K-5** in the open table below; it was not built and cannot be tested as
  written.

Also tested: `canRevoke` is false until counters hit zero; a retiring logic rejects
submissions but still settles; a revoked logic refuses fees rather than trapping
them; desynchronized registry authorization is unreachable.

### P0-6. Bounded DRAW terminality

**Confirmed.** `drawPanel` may seat fewer than requested, and the case still enters
COMMIT. If those seats reveal below quorum, `_closeReveal` re-arms and returns to
DRAW — but the stuck case's own reservations keep the tree empty, so
`Moderation.sol:520` reverts `NoEligibleModerators` before any widen attempt can be
consumed. No autonomous terminal path exists. The same holds for a case opened when
no capacity exists at all: the fee is taken and every draw reverts.

**Fix.** Make empty/short draws part of the bounded state machine: consume a
draw-failure attempt, and after the cap resolve as under-quorum, VOID+refund at depth
0, or preserve-prior+refund on appeal — releasing all duty reservations. Add a
draw deadline permitting a permissionless refund when the network has no capacity.

**Test.** A case that exhausts network capacity reaches a terminal state without
external intervention and refunds correctly.

---

## P1 — correctness and operational quality

### P1-1. Widen seats on an already-committed moderator
**Re-scoped 2026-07 — the original description was wrong, and its error is
recorded here because it propagated into the M2.6 resolution record and the
`unbackedSeats` mechanism.**

Wrong as written: *"uncollateralized ... the one place where a seat can still exist
without backing."* **Widen seats ARE escrowed.** A widen sets `r.pendingDraw` and
returns the round to DRAW (`_closeReveal`), so the added seats are drawn through
`realizeSeats` -> `_drawSeats` -> `StakeRegistry.drawPanel`, which bonds
`riskPerSeat` per seat like any other seat — onto the same `caseRef`, since it is
the same round. There is no path that adds a seat without going through
`drawPanel`.

The claim came from reading `__injectWidenSeats`, a **test harness** that writes
`r.seats` directly and therefore bypasses the escrow. Reasoning off a harness
rather than off production is what produced it. `unbackedSeats` was then added as
defence in depth against a condition that cannot occur; it is deleted in
`M2.6-P0-2b`, with the reachability argument and an invariant test in its place.

What P1-1 actually is — two distinct problems, both open:

**(a) A widen seat on an already-committed moderator is inert but paid for.**
`commitVote` has already run for that address, so the extra seat is never added to
`committedSeats`, never tallied at reveal, and never penalized at settlement
(`!r.committed[a]` is false). At settlement `_settleDuty` passes the POST-widen
`r.seats[a]` with `penalty = 0`, so its escrow is released in full. Nothing is
lost and nothing is minted — but the seat consumed one of the widen's slots and
recruited no new voter, so a widen that adds `k` seats can recruit fewer than `k`
fresh participants. A high-weight moderator absorbs these, and can induce them
deliberately: commit, withhold the reveal to force the widen, soak its seats.
Fix: `topUpCommittedSeats` (lock the delta, raise `committedSeats`), or exclude
already-committed addresses from later widen draws.

**(b) A widen reopens the commit window for first-tranche no-shows.**
Not previously recorded anywhere. The widen returns the round to DRAW and the next
`realizeSeats` sets a **fresh** `c.phaseDeadline` for COMMIT. `commitVote` gates
only on `r.committed[msg.sender]`, which is still false for a first-tranche
seat-holder that never committed — so it may commit in the later window. The
consequences:
  - the commit deadline is not a hard per-tranche deadline. A seat-holder can
    wait out the first window, observe who committed and how many, and then decide;
  - the H-10 no-show penalty is evadable. Failing to commit in your own window
    costs one seat's escrow frozen; committing late instead costs nothing at that
    point, and the worst later outcome is the failed-reveal freeze on committed
    stake — a different and possibly smaller cost;
  - and the withheld reveal that forced the widen is the same action that creates
    the second chance, so (a) and (b) compose.
Fix direction: record the tranche a seat was drawn in and gate `commitVote` on
that tranche's deadline, which also gives P1-7 (widen tranche deadlines) its
mechanism.

### P1-2. Deployment activation
Confirmed: the constructor validates only `riskPerSeat` vs the registry's duty unit.
Add a one-way `activate()` requiring `token != 0`, `token == stakeReg.token()`,
`stakeReg.isLogic(this)`, `indexReg.isLogic(this)`, `guidelinesVersion > 0`, and
expected registry code hashes. `submit`/`submitRemoval` require `active`. A
token-mismatch deployment silently makes the registry insolvent in one asset while
accumulating another.

**Landed as item 4 (post-close), and NOT as an `activate()` gate.** This item was
flagged by both original audits and then lost to a duplicate P1-2 numbering — the
number was reused for batched seat drawing — so it survived the whole milestone
unbuilt. Closed piecewise instead:

- `token == stakeReg.token()` is a **constructor** check. Both `token` and
  `stakeReg` are immutable, so the relation is fixed at construction and a revert
  there makes the bad deployment unrepresentable; an activation flag would add
  state and a live selector to guard a state that can no longer arise. It subsumes
  `token != 0`, because the registry rejects a zero token at its own construction.
- `stakeReg.isLogic(this)` and `indexReg.isLogic(this)` are enforced continuously by
  P0-5's `_requireOpen`, which is strictly stronger than a one-shot activation
  check: authorization can be revoked *after* activation, and a gate that only ran
  once would not see it.
- **Deliberately not taken:** `guidelinesVersion > 0` and expected registry code
  hashes. The first is an operational precondition, not a safety one — a case
  submitted under version 0 pins version 0 and adjudicates consistently. The second
  pins registry bytecode into the game contract, which forecloses exactly the
  registry upgrade the M2.5 split exists to permit.

The audit's statement of the harm understates it. It is not an accounting
mismatch: settlement's `reward()` pulls `StakeRegistry.token()` from the logic
contract, which under a mismatch it does not hold, so the transfer reverts and takes
`claim` with it. Every adjudicated case bricks in SETTLING with its seat-holders'
committed stake **locked permanently**, while `submit` keeps taking fees. VOIDs
still drain, because they pay the submitter in the logic's own token and never call
`reward()` — so the fault presents as intermittent rather than total.

Also: **`MAX_PANEL = 512` is not evidence-based.** The largest measured draw is 47
seats over 1,000 moderators at ~4.39M gas, and `realizeSeats` attempts a whole target
in one call. Either derive the cap from a real worst-case benchmark or make seat
drawing itself cursor-based. Requiring `commitTargets.length == maxDepth + 1` also
removes the clamping ambiguity behind the total-draw miscount entirely.

### P1-3. Parameter validator must model the runtime state space
Confirmed: `_validateParams` iterates `commitTargets.length` (`Moderation.sol:1537`)
while runtime clamps to the last entry — `commitTargets=[400], maxDepth=8, maxWiden=8`
validates as 3,600 draws and executes up to 32,400. Iterate `depth = 0..maxDepth`
using the runtime clamp. Add caps for `freezeCap`, track, `freezeBase * power`, fee
and pot arithmetic; require `trackDecay < WAD`.

**Clamping fix landed** (validator commit, post-close). The aggregate loop now runs
`d = 0..maxDepth` over `_runtimeTarget(commitTargets, d)`, which mirrors
`Moderation._commitTarget`'s clamp and nothing else. At the current caps the
reachable figure is `[MAX_PANEL]` with both retry budgets at 8: validated 1,152
before, reachable 10,368. Two tests, both failing pre-fix — an explicit fixture and
a fuzz property asserting acceptance tracks the runtime-clamped sum, with ascending
targets so a uniform array cannot pass it vacuously.

The shape matters as much as the number. `totalDraws` is now
`Σ_{d=0..maxDepth} attempts × runtimeTarget(d)` with `attempts` a single named
per-depth budget (`1 + maxWiden` today), so a retry axis added later multiplies into
`attempts` and needs no new term and no second loop. This was a precondition for the
item-2b stall round, which adds exactly such an axis.

The `freezeCap` / `freezeBase * power` caps landed with P0-8. **Remaining:
`trackDecay < WAD`** — the check is `> L.WAD`, so `trackDecay == WAD` is still
accepted. Deliberately not folded in here; it is a calibration question, not a
bound-shape one.

### P1-4. Retry economics
Rejection clears the dedup reservation, so identical content is resubmittable at the
base fee — cheaper than the ≥2× pot appeal, with a fresh panel and fresh probabilistic
draw. With per-attempt approval probability `p`, `N` retries succeed with
`1−(1−p)^N`. Persist review history in the **registry** (so migration doesn't reset
it) and price retries: escalating fee, cooldown, or fold resubmission into the
existing appeal ladder.

---

### P1-7. Widening tranches must close, and should exclude prior participants

Beyond the inert-seat problem: because the same `Round` object is reused, a widen
**reopens the commit and reveal windows to earlier nonparticipants**. A moderator can
deliberately miss its window, watch the panel expand and votes disclose, then join a
later tranche — an optional-stopping strategy across tranches, with no failed-
participation penalty for the window it skipped. Model each widen tranche with its
own deadlines and finalize missed assignments as failed; and prefer *excluding*
already-selected addresses from later widen draws, which is what widening is for
(adding independent participation, not re-drawing the same identity).

### P1-8. One case-level penalty reference time

Freeze deadlines are computed as `block.timestamp + duration` at the moment each
participant's cursor position is processed, so participants in a later settlement
batch get a later expiry than participants in the same case settled earlier — and a
slow settlement adds the whole freeze on top of an already long committed lock.
Record a `penaltyReferenceTime` at finalization/settle-init and derive every absolute
deadline from it.

### P1-5. Quorum counts seats, not independent moderators

Ordinary round progression uses `revealedSeats >= minReveals`, so a single moderator
holding three collateralized seats satisfies the default quorum alone. Only the
`fullQuorum` (supersafe) gate requires independent revealers. An entry decided by one
address therefore still enters the ordinary index. Either raise ordinary progression
to an independent-address threshold, or state explicitly — in the README and in the
client — that ordinary index membership carries no independence guarantee. This is a
product decision, not a pure code fix; make it deliberately.

### P1-6. Conservation should be `balance >= liabilities`, plus tracked surplus

Both conservation identities are exact equalities today. Anyone can break that by
transferring tokens directly to either contract — the protocol stays solvent but the
assertion fails, and a broken invariant that fires on a harmless donation trains
people to ignore it. Restate operational invariants as `balance >= liabilities` with
surplus tracked separately, and add a sweep path for surplus (to the fee pot or
governance) so donations cannot accumulate untracked. Update the test helpers to
match.

## P2 — economics, semantics, hardening

- **Keeper incentives.** The whole bounty goes to the final batch caller; earlier
  batchers can be front-run and get nothing. Pay per processed seat, or grant the
  initiator a timed completion right.
- **Product semantics.** Decide vote-uncontested vs process-uncontested (a funded
  appeal is arguably a public objection, which the README implies but the code does
  not). Document that ordinary index membership is *not* certification.
- **Pagination stability.** Swap-and-pop reorders arrays; concurrent deletion can make
  a paginating client skip or double-count. Paginate over monotonic global IDs with
  tombstones once P0-1 lands. Harden `cursor + limit` overflow in `supersafeEntries`.
- **`dedupOwner()` cannot represent case zero.** Storage is `caseId + 1`, but the
  getter subtracts one and returns 0 both for an unreserved key and for one owned by
  case 0. Return `(bool exists, uint256 caseId)` or the raw plus-one value.
- **`Moderation.supersafeEntries(topic)` is still unbounded** — the registry view is
  paginated, but the compatibility wrapper calls it with the entire topic length, so
  the preserved ABI is not operationally safe at scale.
- **Track decay** is event-based, not time-based, despite the docs. Add lazy
  timestamp decay or fix the documentation.
- **Two-step governance transfer on `Moderation`** (the registries already have it);
  reject the zero address.
- **Multi-seat no-show** costs only one seat's worth. Consider
  `penaltyUnits = min(seats, P_max)`.
- **Randomness** remains proposer-influenceable; compare per-case controllable value
  against that cost, and plan a VRF/beacon path.
- **Draws are capacity-depleting, not with-replacement.** Simulations and docs must
  model the actual process; binomial conclusions are invalid.
- **Code size.** 1,184 B of headroom under `via_ir` when this was written; see the
  per-item table in `contracts/GAS_BUDGETS.md` for the live figure. CI must block on
  exact compiler version, optimizer settings, `via_ir`, and size.

  > **The size gate must name the deployed contracts.** There is no `.github/`
  > in this repo yet, so this is forward-looking rather than a broken gate — but
  > a naive `forge build --sizes` in CI **fails permanently for a non-reason**.
  > The command already exits non-zero, and did at `b09ce31` before any M2.6 work:
  > `ModerationHarness` is 26,783 B, over EIP-170. It is the test-only subclass
  > carrying the storage injectors, it is never deployed, and `forge test` does
  > not enforce the limit on it. Assert on `Moderation`, `StakeRegistry` and
  > `IndexRegistry` specifically (parse the `--sizes` table, or use
  > `forge build --sizes --json` and check those three keys). A gate that shells
  > out to `forge build --sizes` and trusts its exit code is red from day one,
  > and the first person to see it will disable it.
- **Track farming.** A moderator earns +1 track for coherent participation in a
  single-round undisputed case, so easy self-submitted content can farm reputation.
  Saturation and fees bound it, but it needs simulation against the *actual* duty-pool
  and retry behaviour, not the pre-M2.5 model.
- **Trust-model documentation must state the real invariant.** Today's docs imply the
  registry isolates principal from replaceable logic. Until P0-4 and P0-5 land, the
  honest statement is: *solvency holds only if every authorized logic is correct,
  non-malicious, uses the same token, funds rewards before crediting, and never
  touches another logic's obligations.* Rewrite the `StakeRegistry` header and
  `DEVIATIONS.md` to say that, then tighten it as each fix lands.
- **Economic re-validation** and an **independent re-audit of the four-contract
  architecture** — still outstanding, and now more clearly required than before.
  The re-audit must be pointed at a specific commit; the last attempt reviewed
  pre-M2.5 code and produced a stale replay.

---

## Test gaps the audit identified (each becomes a named test)

The findings above map to concrete blind spots in the current 140-test suite. These
are not optional extras — several findings exist *because* the fixture stopped short:

1. Two logic contracts each writing their local case 0 to the same topic; then
   deleting each independently (P0-1).
2. Removing a legacy entry through a replacement logic (P0-1).
3. Identical content re-indexed after migration because dedup restarted (P0-1).
4. `setDutyUnits(0)` **after** selection, then no-show (P0-2).
5. `requestExit(all free)` after selection, then no-show (P0-2).
6. Repeated no-op `setDutyUnits(sameValue)` stalling every pending draw (P0-3).
7. `release`, `reward`, `releaseDuty` each changing eligible weight against a
   an already-public seed (P0-3).
8. `reward()` called by an authorized logic that transferred nothing (P0-4).
9. Cross-logic `release`/`freeze`/`releaseDuty`/`setTrack` during handover (P0-5).
10. A short panel driven all the way through reveal and the next widen, to a terminal
    state (P0-6) — the existing test establishes the precondition and stops.
11. A case opened when the network has zero pledged capacity (P0-6).
12. A committed moderator receiving widen seats, then settling — assert the extra
    seats are either collateralized or penalized, never silently released (P1-1).
13. ~~Deployment with a token that differs from `stakeReg.token()` (P1-2).~~
    **Covered** by item 4: `test_deployment_against_a_foreign_token_is_refused`
    plus its matching-token counterpart.
14. ~~Deployment authorized in one registry but not the other (P1-2).~~ **Covered**
    by P0-5's `_requireOpen`, which checks BOTH registries at submit —
    `test_desynchronized_registry_authorization_rejects_submissions`.
15. ~~A ruleset that passes validation but exceeds `MAX_TOTAL_DRAWS` at runtime
    through target clamping (P1-3).~~ **Covered** by the validator commit:
    `test_short_target_array_cannot_smuggle_draws_past_the_aggregate_bound` and
    `testFuzz_aggregate_bound_tracks_the_runtime_clamped_sum`, both demonstrated
    failing against the array-indexed loop.
16. Rejected content resubmitted at base fee (P1-4).
17. A direct token transfer to either contract not breaking the invariant (P1-6).

---

## Sequencing

P0-1 (index identity) and P0-4 (reward funding) are independent and can land first —
P0-4 is small and closes the only path to unfunded withdrawable claims, so do it
first. P0-2 (duty bonding) and P0-3 (epochs) both rewrite `StakeRegistry` eligibility
state; do them adjacently, epochs after bonding. P0-5 (obligation scoping) touches
every privileged API, so it lands after P0-2/3 have settled their shapes. P0-6 is
independent. P1-1 depends on P0-2's bonding. Everything else follows.

## Standing recommendation — unchanged

No deployment with material funds, and the index is not presented as reliable
safe-search certification, until P0 closes and an independent re-audit of the
four-contract architecture passes. Treat the current code as an advanced prototype.
(Both counts said "three" when this order was written. M2.6 split `RulesetGovernor`
out of `Moderation` at EIP-170, so a review scoped to three contracts would leave
the governor — which holds all ruleset validation — unreviewed.)

---

# Resolution record (M2.6 close)

Every P0 item is closed. This section is the authoritative record of what landed
and, where the implementation departs from the prescription above, why. **A
re-auditor should read the deviations as decisions, not as misses** — each was
measured or reasoned about explicitly, and each is reproducible from the commit
it landed in.

Baseline `main` @ `b09ce31`: 143 tests, 16 suites. The milestone peaked at 199 / 19;
the difference is `test/spike/`, deleted at close — throwaway harnesses whose gas
numbers are recorded in `GAS_BUDGETS.md` and `ProtocolLimits`. At the
`m2.6-close` tag (`a05343a`): 188 tests, 16 suites, `Moderation` 23,296 B.

**Post-close.** An independent verification pass against that tag found four
blocking regressions in items this record marked closed, plus four more found on
re-reading (P0-5d, P0-6c, P0-3c and then P0-3d, which reopened P0-3c) and three
fixes with no discriminating test coverage. They are recorded in their own section below and are
fixed on top in seven commits (`a05343a..4864d80`); the `m2.6-close` tag is
deliberately NOT moved, because it is the commit the audit ran against and moving
it would invalidate that verification. Current state: **218 tests, 18 suites**,
green at every commit, `Moderation` 24,137 B (439 free — see "Size position"). The
seventeenth suite is `StalledDraw.t.sol`, split out of `CaseLifecycle.t.sol` when
that contract outgrew the `via_ir` pipeline; a file move, not new coverage.

## P0 — all closed

| Item | Commit | What landed |
|---|---|---|
| P0-1a CRITICAL global entry identity | `81ef77e` | `IndexRegistry` mints a permanent `globalId`; the position map is keyed by it; entries carry origin/provenance |
| P0-1b registry-owned dedup | `bc0f5a4` | Content reservation moved to `IndexRegistry`, keyed `(logic, caseId)`; survives migration |
| P0-1c legacy removal | `f6b4a62` | `submitLegacyRemoval(globalEntryId, fee)`; deletion frees the reservation |
| P0-2 duty escrow | `5778dc9` | `dutyBonded` bucket; all four bypasses closed |
| P0-3 eligibility epochs | `e4bcf2e` | Weight changes take effect only at fixed-cadence epoch boundaries; `eligibilityAddVersion` deleted |
| P0-4 funded `reward()` | `d1317c1` | Pulls its own funding, verifies the measured balance delta |
| P0-5a obligation handles | `f363522` | `keccak256(authEpoch, logic, moderator, caseRef)`; cross-logic AND cross-case isolation |
| P0-5b retirement lifecycle | `b5315e1` | `NONE \| OPEN_AND_SETTLE \| SETTLE_ONLY`, `canRevoke`, fee rejection |
| P0-6 stalled-draw terminality | `49a9627` | `resolveStalledDraw`, permissionless and deadline-gated |
| P0-7 batched VOID | `9e2f475` | `VOID_SETTLING` phase; `closeReveal` is O(1) |
| P0-8 freeze bounds | `51af155` | Upper bound, composite bound, full-precision `mulDiv`, defensive clamp |

Also landed, not in the original list but P0 in effect:

| Item | Commit | Why |
|---|---|---|
| MAX_PANEL clamp | `31ba212` | Filed as a P1 note; it is a P0. `_validateParams` accepted panels whose draw cost 55,231,377 gas — 3x the Gnosis block limit — and H-11 pins the ruleset per case, so every case under one was unfinalizable |
| Structural split | `cef84d4` | `Moderation` hit EIP-170 at P0-1c. Ruleset authoring moved to `RulesetGovernor` |
| P1-2 batched seat draw | `27f7e2f` | Promoted ahead of P0-6/7/8: two findings had named it a precondition, and P0-7's per-seat state would have been shaped around a constraint it removes |

## Regressions found after the close, in items marked closed

Independently verified against `m2.6-close` (`a05343a`) by a separate session —
24 probe tests and 20 fix-reverts — and confirmed against the code before being
worked. These are **not new scope**: each is a defect in an item this record
already claimed closed, and four of them were live blockers.

The suite went 188 -> 218 tests, green at every commit. Suite count went 16 -> 17:
`CaseLifecycle.t.sol` outgrew the `via_ir` pipeline ("Tag too large for reserved
space") while P0-6c's tests were being added, so the P0-6 family moved to
`StalledDraw.t.sol`. That is a file move, not a coverage change.

| Item | Commit | The regression, and what closed it |
|---|---|---|
| P0-5b was built on ONE registry | `3d3710f` | `StakeRegistry.revokeLogic` required `canRevoke`; `IndexRegistry.revokeLogic` required nothing. Governance could revoke index-side with a case in SETTLING; `_settleFinish` writes entries AND releases stake in the same call, so from that moment every `claim()` reverted `NotLogic`, the case never finished, its stake obligations never closed, and `StakeRegistry.canRevoke` never flipped. The stake-side gate did not prevent the strand — it guaranteed the deadlock was permanent. `IndexRegistry` now has `logicOpenCases` / `canRevoke` / `LogicStillHasObligations`, opened per case at submit and closed at SETTLED or VOID. The unit is the **case**, not the content reservation: removals take no reservation yet still delete at settlement, and an approved submission's reservation outlives its case by design. |
| P0-3's drain rolled back its own work | `bf003b3` | `drawPanel` drained `DRAIN_BUDGET` staged items and then reverted `EpochNotSettled` if that was not enough — unwinding the drain with the revert. Every draw redid the same first 64 items and discarded them again, so any epoch staging more than one budget halted **every draw in the protocol** until an external `advanceEpoch` call, whose progress survives only because it does not revert. Ordinary traffic reaches it: `_stageSeated` skips the dedupe flag by design, so one 48-seat panel plus normal joining passes 64 inside a 256-block epoch. Not closed by raising the budget — that moves the cliff. A settled epoch is now a precondition of `drawPanel`, which does no rollback-able work before checking it, and `realizeSeats` drains `EPOCH_DRAIN_STEPS = 128` and RETURNS, so repeated pokes recover with no keeper. |
| P0-6 covered one of its two paths | `0dae983` | `resolveStalledDraw` at depth 0 VOIDs and `_voidStep` checks `c.drawAbandoned`. At depth > 0 it calls `_failAppealRound`, so the case FINALIZES and drains through `_settleStep` — which did not check it, and froze one seat's stake per moderator seated in an appeal round whose draw was abandoned, for missing a commit window that never opened. |
| Three fixes had no discriminating test | `a02573d` | `_fullQuorum`'s independent-revealer check (the fixture used one address with one seat, so `revealedCount` and `revealedSeats` were indistinguishable), `_armSeed` on the widen path (only `_openRound`'s call was covered), and `unbackedSeats` — which P0-2 **did** make unreachable, so it is deleted rather than kept, with the reachability argument and an invariant test in its place. Also fixes `_supersafe`, which read the suite-level registry rather than the one the passed-in harness writes to, so both H-09 `length == 0` assertions held vacuously. |
| P0-5a left one unscoped selector | `4864d80` | `StakeRegistry.penalizeNoShow` was superseded by `settleDuty` in P0-2 and had had no caller since — but it kept a live selector, callable by any authorized logic, that wrote the POOLED `m.dutyBonded` with no `caseRef`. `dutyBonded` pools escrow across every case a moderator is seated in, so it could freeze collateral posted for a DIFFERENT case's outstanding seat: the exact class P0-5a made unrepresentable everywhere else. Filed as a P1 on the strength of "no production caller" — which is precisely the argument that failed for `settleDuty`'s own double-release, and the reason obligations are keyed per case rather than per logic. **Deleted**, not given a `caseRef`: a retrofitted version would be dead code with a live selector, the same hazard in a shape that reads as safe. `NoShowPenalized` survives, emitted by `settleDuty`, so no indexed event signature changes. |
| P0-5a: governance could orphan live handles | `28717cb` | `executeLogic` bumped `authEpoch` unconditionally, and `authEpoch` is part of every obligation handle. Re-executing a proposal for an ALREADY-authorized logic — a duplicate proposal, a re-run script, a governance slip — renamed the whole namespace in one transaction and orphaned every live handle: `_debit` then reverted `NotYourObligation` on the rightful owner's own settlement, permanently, so committed stake was stranded, escrow could not be released, and the per-logic counters never reached zero — `canRevoke` stayed false forever and the contract could not even be retired out of the way. Nothing minted, conservation intact, invisible to the invariant campaign. Now refused when the target is already authorized and not drained; a first authorization from `NONE` is unaffected, which is the only case where the bump has a job (revocation requires `canRevoke`, so a logic at `NONE` has no live handles). Consequence named rather than hidden: a SETTLE_ONLY logic cannot be un-retired while it holds obligations — a governance action whose effect silently depends on drain state is worse than one that fails loudly. `IndexRegistry` has no `authEpoch` so it had no orphaning hole, and the audit's asymmetry (`caseOpen` not epoch-keyed, index flags surviving while stake handles die) **is now benign** — but only because P0-5b gated index revocation on drain, so a flag can never outlive its case. The same gate is added there anyway, to stop governance creating a stake/index desync by executing the pair. |
| P0-6b's amnesty was H-10 evasion | `dd0ee13` | The abandoned-draw amnesty keyed on `c.drawAbandoned` alone. True for a round that stalled before COMMIT opened; false once it has widened, since a widen only happens after a commit window opened and closed. Moderators pledging exactly the depth-0 target could get seated, refuse to commit, let the round widen, and have the re-draw stall on the capacity they were still holding — `resolveStalledDraw` then released all of them, while `test_void_with_no_commits_penalizes_no_shows` freezes the identical refusal when the draw completes. The penalty depended on whether the attacker left capacity for the widen, which the attacker chooses. Gated on `r.widenCount == 0`. **Known imprecision, taken deliberately:** this over-penalises the widen tranche, drawn by the widen itself and never given a window. In the attack it has no false positives, because the attackers hold the capacity that stalls the re-draw so the widen tranche is empty by construction; where it does bite the cost is one seat's escrow for one `failedRevealFreeze`. Separating the tranches needs per-seat window provenance — the same mechanism P1-1(b) needs, filed there to be built once. |
| P0-3 was closed on an overstated claim (H-03A) | `<P0-3c>` | The record said eligibility is "constant by construction across any draw window, so there is nothing to grind". The sortition TREE is constant; the SEATABLE SET is not. `drawPanel` reads the live struct to decide seatability — correct, and required by P0-2 — but rejected an unseatable address with `stakeTree.set(seat, 0)`, which remaps every subsequent interval. `setDutyUnits` only refuses `units < dutyReserved`, so an unseated moderator could zero its duty after its seed's blockhash was public and steer the rest of the panel; `requestExit(free)` is the same lever through `usable`. With `k` identities that is a choice among subsets of a public-seed draw for gas plus one epoch of eligibility. Fixed by recording the epoch of each self-directed reduction and denying such a moderator its seat WITHOUT removing its leaf — it excludes itself and remaps nothing. The seatability read is unchanged, so P0-2 holds; a freeze still excludes, since it is imposed rather than chosen. **The prose was the other half of the defect**: the design comment at the check was accurate, the conclusion drawn from it was not, and it had been copied into two documents. Both corrected. |
| P0-3c closed two levers, not the property (H-03A/H-03B) | `<P0-3d>` | P0-3c suppressed the tree write for VOLUNTARY reductions. Two classes survived: the exhaustion asymmetry (seated-to-capacity removed its leaf, a holder that had cut was never seated and so never removed — two trees, third parties move) and the whole UPWARD family across `realizeSeats` batches, where `setDutyUnits` up, `activate`, `thaw` and `claim` on another case each raise a live seatability input with the seed and batch 1's seats already public. The fix is one sentence — **`drawPanel` performs no writes to `stakeTree`** — after which the tree is immutable for a whole epoch and the freeze lever closes too, rather than being carved out as a residual. `voluntaryCutEpoch` deleted as superseded (K-4 reasoning). `ATTEMPTS_PER_SEAT` 2 → 6, measured against a pre-committed bar; free in every dense case. Persisted offer-based exclusion was built and measured head-to-head and rejected on evidence: identical fill everywhere, +0.6M to +3.2M gas. Both size constants re-derived and both stand — the batch got cheaper. |
| Governor governance transfer | `017ae9e` | One-step and accepting `address(0)`, on the contract holding the whole ruleset authority — and `Moderation.governor` is immutable, so a mistyped or zero nominee could not be recovered from. Now propose / accept / cancel with a zero check, matching both registries. |

Two documentation defects were fixed alongside: P1-1's description (below) and the
`uncontested` definition, which `README.md` §3.8 and `specs/state-machine.md` §2
each stated differently from §8.1 and from the implementation.

## Deviations from the prescription, and why

**1. P0-2 bypass 3 (partial commit) closed structurally, not by penalty.**
The order says "partial commit stays possible, unfulfilled assignments still get
penalised and released." Once a seat is only issued when its collateral can be
escrowed, every assigned seat is backed and `commitVote` can always commit all of
them — partial commit becomes unreachable through the draw. Adding a penalty path
that can never fire would have been dead code asserting a property the escrow
already guarantees.

*Amended 2026-07 (`M2.6-P0-2b`).* This deviation originally ended "the
`unbackedSeats` mechanism remains as defence in depth. Widen seats can still
exceed backing; that is P1-1." **Both halves were wrong.** Widen seats go through
`drawPanel` and are escrowed like any other seat, so `unbackedSeats` was
unreachable in production — reachable only through `__injectWidenSeats`, the test
harness the claim was derived from. It is deleted, and the invariant that makes it
unreachable is asserted instead
(`test_every_drawn_seat_is_backed_by_its_own_escrow_at_commit`). P1-1 is re-scoped
above to what it actually is.

**2. P0-3 rejected the checkpointed sortition tree the order prescribes.**
"Each case pins an epoch root" requires a checkpointable sum tree. Measured
(`aadeb48`): descent costs 2.29x the live tree and is flat in history depth, so it
would have FIT the ceiling — an earlier estimate that it would not was wrong and
is corrected in that commit. What rules it out is the P0-2 interaction: `drawPanel`
shrinks weight and drops exhausted moderators mid-draw, and a pinned historical
root cannot see either, so a checkpointed draw would re-seat a moderator past its
escrowed capacity. Recovering that means in-memory exclusion during descent — i.e.
rejection sampling — which changes the draw distribution and reintroduces the
unbounded-attempts problem H-07 was built to avoid. Frozen-window epochs give the
same property with no snapshot storage.

**3. The structural split kept ruleset STORAGE in `Moderation`.**
The M2.5 note names governance as the seam. Authoring moved; storage did not.
`_cp()` reads the pinned ruleset on every phase transition, so moving `rulesets`
behind a call would turn a hot-path `SLOAD` into a cross-contract call returning a
nineteen-field struct — more bytes at the call sites than the split saved, and a
great deal of gas. The governor validates and pushes the result into `Moderation`'s
storage. One bound (`riskPerSeat <= stakeReg.riskPerSeat()`) is re-checked on
arrival, because it is the only validation failure that is a solvency problem
rather than a liveness one.

**4. MAX_PANEL was raised, not just clamped — and the binding constraint moved
twice.** 512 -> 48 (measured per-seat draw cost) -> 128 (after P1-2 and P0-7
batched every panel-scaled loop). It is now bound by `MAX_TOTAL_DRAWS`, the
aggregate-reachability check, and not by any single transaction.
`ProtocolLimits.MAX_PANEL` leads with which loop sets the bound, because after two
moves that is the fact worth knowing. `GasBounds` reads the constant directly, so
raising it again without re-measuring fails the suite.

## Residuals — known, deliberate, and open

These are named because they were found and reasoned about, not because they were
missed. None is a P0.

- **Intra-case capacity depletion (P2).** An observer can consume a specific
  moderator's pledged capacity by drawing it into another case first, changing
  whether that address is *accepted* rather than whether it is *drawn*. Batching
  the seat draw (P1-2) makes this reachable within one case's draw as well as
  between cases. It costs the attacker a real fee and a random panel of its own,
  and the seed and eligible set remain unmanipulable.
- **The one-shot `claim(caseId)` requires batching at depth-3 / 86 seats.**
  4,699,258 gas at milestone start, 8,019,298 now — past the 8M budget. The budget
  was not raised; the test asserts the BATCHED path, which is the guarantee H-04
  exists to provide. The convenience overload still works for smaller cases.
- **P1-1: widen seats are inert, and a widen reopens the commit window.**
  Re-scoped above. The earlier text here ("uncollateralized ... the one place
  where a seat can still exist without backing") was **wrong**: widen seats go
  through `drawPanel` and carry escrow. Severity **P1** for both halves — nothing
  is minted or lost, but (b) makes the H-10 no-show penalty evadable, which is a
  weakening of a stated defence rather than an accounting error.
- **`forge build --sizes` exits non-zero on `ModerationHarness`** (test-only,
  never deployed, pre-existing at `b09ce31`). A CI size gate must assert on the
  deployed contracts, not on this command's exit code.
- **P0-6b's abandonment check is round-level, not tranche-level (P2).** A round
  abandoned *after* a widen re-opened its draw releases its first tranche without
  penalty too, even though that tranche did have a commit window and did no-show.
  Deliberate: the conservative direction is never penalising someone who was not
  asked, and separating the tranches needs the same per-seat window provenance
  P1-1(b) needs. The two should be fixed together.
- **`IndexRegistry`'s obligation counter trusts the logic to close what it opens
  (P2).** Same shape as the stake registry's, and it fails **safe**: a logic that
  leaks an open case blocks *its own* revocation, it cannot strand anything else,
  and no other logic's obligations are reachable. Not a solvency property.

## Knowingly open, carried forward with severity

Named here so a re-auditor does not read them as misses. None is being fixed in
this pass.

**Read item 10 first.** It is the only entry here that is a live defect on shipped
code rather than a gap, an inefficiency or a design question, and it is the one a
re-auditor should check before anything else in this table.

| # | Item | Severity | Why not P0 |
|---|---|---|---|
| K-1 | **Keeper economics: unpaid work, and work decoupled from progress.** *(Two findings, merged — one gap.)* **(a)** Batched settlement (H-04), batched seat drawing (P1-2) and batched VOID disposal (P0-7) all pay the claim bounty to whoever sends the **last** batch. Every earlier batch is unpaid gas, so only the terminal one is incentivised and a large case can sit part-settled. **(b)** M2.6-P0-3b added a second unpaid path, and it is worse in kind: a `realizeSeats` poke that finds the epoch unsettled spends itself draining and **advances no case at all** — it seats nobody, moves no phase, and cannot become the terminal batch that earns the bounty. A full 128-item batch measures 1.83M gas over a 1000-leaf tree (~840k at the suite's fixture scale). The fix that removed the keeper REQUIREMENT therefore left keeper-shaped work with no reward attached to it. | **P1** | Permissionless, and several parties hold a direct claim on completion — the submitter's refund, winning appeal contributors' payouts, and every seat-holder's committed stake are all released by it. An efficiency and latency problem, not a stuck-funds one. (b) is additionally self-healing: the drain is permissionless, anyone can call `advanceEpoch` directly, and the epoch completes the moment somebody does. A pro-rata bounty split across batches addresses (a); (b) needs the drain to be attributable in the first place, since it is tied to no case today. |
| K-2 | **Retry economics (P1-4).** A REJECT clears the content reservation, so identical content is resubmittable at the base fee — cheaper than the ≥2× pot appeal, with a fresh panel and a fresh probabilistic draw. `N` retries succeed with `1−(1−p)^N`. | **P1** | Every attempt pays a real fee to real moderators, so it is not free; and the escalation it evades (appeal) exists for disputes, not for resubmission. Needs review history persisted in the **registry** so a migration does not reset the counter — which is why it is registry work, not logic work. |
| K-3 | **Settlement-order dependence, and per-batch freeze expiry.** `_disposeSeat` computes `until` as `block.timestamp + s.freezeDur` at the moment its batch runs, and `_voidStep` recomputes `freezeUntil` per batch. Two seat-holders of the same round therefore thaw at different times purely by which batch disposed them. The reward channel has the same shape: `distributed` accumulates across batches and the final claimer absorbs the pro-rata dust. | **P1** for the freeze, **P2** for the dust | The freeze duration itself (`s.freezeDur`) is computed once at `_settleInit` from state frozen at reveal, so nobody can *lengthen* a freeze by choosing the batching — only shift its start by however long settlement takes, which is bounded against a 7-day base. The dust is bounded by one wei per claimant and is a documented consequence of pull-based payout (C-01). Fix: snapshot one `settleStartedAt` in `SettleState` and derive every `until` from it. |
| **10** | **Reward structure reads a different seat set than the outcome draw.** `realizeOutcome:926` draws from `_cur(c)`; `_settleInit:389` sums every round. The mismatch makes `E[reward]` depend on the vote. **(a)** Appeal panels are paid to overturn: where the deciding round splits evenly — the pivotal case, and the one where freeze risk is symmetric so the reward gap is the whole payoff gap — a depth-1 committer earns `1 + b/f` times as much for flipping as for upholding, ~83% at the worked fixture, reachable on every appealed case with no attacker. Lopsided rounds recover honesty via the freeze term. **(b)** Suppressing turnout enriches the survivors: per-seat payout is `D / revealedSeats`, and an `underQuorum` adjudication pays the whole distributable to as little as one seat. Full analysis, derivation and the neutraliser are in "Item 10" above. | **High** | The only entry in this table that is a live defect on shipped code rather than a gap or an inefficiency, and it sits on the protocol's core claim. Not fixed in this pass only because its neutraliser must be calibrated against post-2b code — 2b's scoping shrinks `winnersSeats`, which makes (b) larger. **Ordering: 2b, then item 10.** |
| K-5 | **`setTrack` is the residual of P0-5's scoping.** `StakeRegistry.setTrack(moderator, newTrack)` (`:571`) takes no `caseRef` and performs an **absolute write**, so every other write to moderator state names the case it belongs to and this one does not. `onlyLogic` blocks a revoked logic and nothing more, and during a handover both logics are authorized by design (trust model #3) — so logic B can overwrite any moderator's track at will while A is still settling. No test covers this and none can be written against the current signature; the only `setTrack` call in `Registries.t.sol` (`:984`) is incidental inside an epoch test. | **High** | Not a fund drain: track is not stake, and `setTrack` cannot move, freeze or credit a wei. The harm is **reputation corruption and freezing-power manipulation** — track drives the §6.4 freeze curve, so a corrupted track lengthens or shortens the penalties an honest moderator can impose and suffer, and it is the protocol's only accumulated-standing signal (design principle 4). **Why it is not fixed here:** `setTrack` is on the production path via `_touchTrack`, so deletion is not available the way it was for `penalizeNoShow`; scoping it raises an open design question — whether track is per-logic or global, since a global track is the whole point of the registry outliving the game, but a per-case handle implies per-version semantics; and it does not fit the 469 bytes left in `Moderation`. It belongs with the split. |

K-1, K-3 and K-5 all land in `Moderation` (K-5 via `_touchTrack`, which is the
only caller of `setTrack`), and it does not have room for them — see "Size
position" below. A second structural split is a precondition for that
work, not an optimisation to consider afterwards.

**Closed in this pass rather than carried:**

- The governor's one-step `transferGovernance` accepting `address(0)` — fixed in
  `M2.6-L-2` as propose / accept / cancel with a zero check, matching both
  registries.
- **K-4, `penalizeNoShow`, reclassified from P1 to P0 and deleted** (`4864d80`).
  It was filed P1 on the strength of "no production caller". That is the argument
  that failed for `settleDuty`'s own double-release — an unscoped write to pooled
  `dutyBonded`, reachable by any authorized logic through a live selector, is the
  class P0-5a exists to make unrepresentable, and a selector nothing calls today is
  still a selector. Deleted rather than scoped, because a `caseRef` version would
  be dead code with a live selector.

## Item 2b — commit-time widen and the stall round (post-close, in build)

Full design in review correspondence; this records what is **ruled** so the next
reader is not dependent on it.

### Build split: 3a (prerequisites) and 3b (mechanism)

Commit 3 as first specified was ten mechanisms at once — the shape the one-per-commit
rule exists to prevent. Split:

**3a — landed.** Four changes that are behaviour-identical on today's code, plus the
boundary guard for hazard 1. Landing the reward scoping while it is provably inert is
safer than landing it beside the mechanism that first arms it.

**3b — landed, then fixed.** A blocker found in review: `settleVoid` disposed only
the last round, so a multi-round VOID stranded every earlier round's committed stake.
See "The VOID strand" below.

**3b — landed.** Commit-time widen with the REVEAL -> DRAW edge deleted, stall rounds
on the shared per-depth counter, findings (ii)/(iii)/(iv), the tests, the re-derived
figures. Part 1 and the stall round stay together: separating them is the H-10
regression.

#### The VOID strand — a blocker 3b introduced, and the class around it

`settleVoid` read `c.rounds[c.rounds.length - 1]` and iterated that round alone,
where the FINALIZED path has always run `while (round < nRounds)`. Pre-2b a depth-0
VOID followed exactly one round, so "the last round" and "every round" were the same
set. 3b makes a depth hold up to four, each able to carry committers who never
revealed — the commit-and-vanish case the budget exists to price.

Every round but the last was **stranded**: stake left in `committed`, so not
withdrawable, not thawable, not draw-eligible; `_settle` accepts only
VOID_SETTLING/FINALIZED/SETTLING, so `Phase.VOID` has no transition left that could
reach it; and `logicCommitted` never reaching zero means `canRevoke` is false
forever — reopening the permanent strand P0-5b closed. **Conservation balanced
throughout**, which is why the invariant campaign did not see it.

The property, stated so one round cannot satisfy it again: *on a terminal
transition, every round the case opened has its committed stake and its duty escrow
discharged.* `settleVoid` now walks rounds on the same two-cursor shape
`_disposeBatch` uses, and `_void` resets both cursors.

**And it was a class of six, not one.** Every `rounds[depth]` site was swept:

| site | fix |
|---|---|
| `reclaimBond`, `claimAppealPayout` | resolve DEPTH -> adjudicating round via `c.adjRoundAt` |
| `seatsOf`, `seatHolderAt`, `bondInfo`, `bondContribOf` | parameter renamed `roundIndex` |

The money paths keep taking a **depth** in the ABI and resolve it internally, because
a bond only ever attaches to the round that adjudicated (`contributeAppealBond`
writes `c.rounds[c.adjRound]`) — a banked round can never hold one, so nothing
becomes unreachable and no caller has to discover anything. The four views genuinely
address a **round**, so they say so; a parameter name is not part of the selector, so
no caller breaks. **Discovery for callers that were passing a depth:
`adjudicatingRoundAt(caseId, depth)`, plus `roundCount(caseId)` as the bound.**

#### The figures, re-derived against the shipped ruleset

| | pre-2b | post-2b |
|---|---|---|
| worst-case case duration | 61 days | **61 days** |
| reachable seat draws (default ruleset) | 344 | **344** |
| `MAX_TOTAL_DRAWS` term | `(1 + maxWiden) x target` | **unchanged** |
| rounds per case | <= 4 | <= 16 |

All three hold because the counter is **shared**. A depth affords `1 + maxWiden`
attempts however they are mixed, and each costs one target's worth of seats and at
most one DRAW+COMMIT+REVEAL of wall clock. A separate stall budget would have
multiplied the two and taken 61 days to 157 and 344 seats to 1,376.

The duration bar is asserted from the live ruleset
(`test_worst_case_duration_is_not_raised_by_stall_rounds`), not from constants copied
into a test. Rounds per case rising 4 -> 16 is the one real new cost: settlement's
per-round overhead and `_noRejectEver` both scale with it, while total SEATS do not.

#### Item 7, measured and derived

The seat half is measured: a case that stalls once puts a whole round beyond reward
(5 of 10 seats at the shipped depth-0 panel). The rate half is not a protocol
quantity — it is driven by the per-seat reveal-failure rate `phi`, which nothing here
fixes. With panel 5 and `minReveals` 3, a round stalls when 3 or more of 5 seats fail
to reveal:

| `phi` | stall rate | seats in banked rounds |
|---|---|---|
| 0.05 | 0.12% | 0.12% |
| 0.10 | 0.86% | 0.86% |
| 0.15 | 2.7% | 2.66% |
| **0.19** | 5.05% | **5.05%** |
| 0.30 | 16.3% | 16.25% |

**The pre-committed 5% bar is crossed at `phi` ~ 0.19 under the independence
assumption.** Two corrections to how that was first reported, both of which make the
residual more serious than "holds with a wide margin" suggested.

**1. Independence is load-bearing, and it is the optimistic case.** The table above
is a binomial: each seat fails to reveal independently. Real reveal failures are
CORRELATED — a client release, an RPC outage, a gas spike, a shared hosting provider
take a whole panel together, and panels are drawn from a moderator set with no
reason to be independent in any of those. At the same marginal `phi`, correlation
banks far more often:

| `phi` | independent | perfectly correlated |
|---|---|---|
| 0.05 | 0.12% | **5.00%** |
| 0.10 | 0.86% | 9.99% |
| 0.19 | 5.05% | 18.89% |

Perfect correlation reaches the bar at `phi = 0.05`, not 0.19 — a **forty-fold**
difference at ordinary failure rates. The truth lies between and nothing in the
protocol pushes it toward the left column. **The table is an upper bound on how well
this behaves, not an estimate of it.**

**2. 5% is not an edge case; it is the price.** It is the ex-ante probability that
any given seat lands downside-only, which is exactly what a moderator prices when
deciding how much duty to pledge. That makes it a **disincentive to pledge**, not a
tail risk — and pledged capacity is what the whole seat-draw depends on.

**Re-priced against item 8's final numbers.** A banked seat pays nothing if its
holder reveals coherently and costs `s.freezeDur` if it reveals incoherently or
withholds. Item 8 raised the withhold branch from `failedRevealFreeze` (1 day) to
`s.freezeDur` (**7 to 28 days** at the shipped ruleset), so the term this residual is
multiplied by grew 7x to 28x in the same milestone that created the residual. At
`beta = 5%` and `P(not coherent) ~ 0.5`, a pledged seat carries `0.05 x 0.5 x 7-28
days` of expected dead-weight illiquidity — with no reachable upside on those seats
at all, since the reward denominator excludes them.

Stated as the asymmetry: **reward income scales by `(1 - beta)`; freeze exposure does
not scale at all.** The two items are coupled in the direction that compounds.

**Ruling: filed, not built.** The measurement's real finding is that **the model is
the question** — forty-fold between the two columns, and the correlation structure is
not measurable before deployment. Three reasons the credit does not get built now:

- Calibrating an economic mechanism against an unknown parameter is how `MAX_PANEL`
  reached 512.
- Item 10 already owns the per-round allocation machinery a credit needs, so a credit
  built now gets built twice.
- Nothing is deployed, so there is no live harm accruing while it waits.

**Revisit trigger: the banked-round rate**, not `phi` under correlated failure. That
formulation was two unknowns, neither directly observable — a marginal failure rate
and a correlation structure. The banked-round rate is the single quantity both feed
into, it is **countable on chain** (rounds opened at a depth versus rounds that
adjudicated, per case), and it collapses the pair into something an operator can
actually watch. Revisit when it approaches 5%.



#### 3a, and the exact sense in which each part is a no-op

| change | why identical today |
|---|---|
| `caseRef` keyed on round index | Every `_openRound` call site gives `rounds.length - 1 == depth`: three at depth 0 with the array empty, one at `fromDepth + 1` after `fromDepth + 1` pushes. |
| `computeCommit` keyed on round index | Same identity; `revealVote` passes `rounds.length - 1` where it passed `c.depth`. |
| reward scoping to the adjudicating round | Every round that revealed anything reaches `_armOutcome`. The only rounds excluded are `_failAppealRound`'s, whose precondition is ZERO reveals — so they contribute zero to `winnersSeats` and `meanTrackNum`, and no seat in them can reach the reward branch. |
| `minReveals` bound | Ruleset 0 is `minReveals = 3` against `min(5, 11, 23, 47) = 5`. |

**`meanTrackNum` is gated alongside `winnersSeats`, and had to be.** It is the
numerator of a mean whose denominator is `winnersSeats`; scoping one without the
other leaves a ratio that is not a mean of anything and can exceed every individual
track. The cross-set property excepted at item 10 is that both sum across DEPTHS
while the outcome is drawn from one round — a different statement, untouched here.

#### Where "no-op" needs a qualifier, stated rather than glossed

The `minReveals` bound is a no-op on **behaviour** — ruleset 0 satisfies it and no
shipped path changes — but it is deliberately **not** a no-op on **what governance
may propose**, since narrowing that is the entire point. One existing test proposed
`minReveals = 9` as an arbitrary placeholder for a cancellation test; it now
validates at 5. The value was incidental to what that test asserts.

#### The two test-side changes, and why neither is an assertion change

The split's standard was an unmoved suite. This is not quite that, and the exceptions
are named rather than absorbed:

1. `ModerationHarness.__injectRound` now stamps `adjudicated = true`. The injector's
   contract is that it "mirrors exactly what those items' real code paths do", and a
   real round in a FINALIZED case has been through `_armOutcome`. Without the stamp
   the differential vectors settle with `winnersSeats == 0` — the harness diverging
   from production, not production changing.
2. The `minReveals = 9` placeholder above.

No assertion, fixture shape or expected value changed. Suite 223 -> **224**; the one
addition is the hazard-1 guard.

### P′, in three clauses — and P′-c is OPEN

- **P′-a (disclosure).** Every commitment counted in a tally is fixed before any
  vote counted in that tally is disclosed. **Closed** by the commit-time widen: the
  REVEAL -> DRAW edge at `Moderation.sol:1270` is deleted, and it was the only
  backward edge (`:748`, `:1241`, `:1270` enumerated and verified).
- **P′-b (coherence).** No commitment is made knowing a disclosed quantity that
  affects whether it will be judged coherent. **Holds**, because the final outcome
  is drawn from the committer's own round (`realizeOutcome:926`, `_cur(c)`).
- **P′-c (payout neutrality).** No disclosed quantity makes one vote more profitable
  than another. **OPEN.**

> **P′-c is not closed, and the record must not say it is.** 2b's scoping closes the
> **same-depth** instance — banked rounds leave `winnersSeats`, so a post-stall
> committer sees `b_v = 0`. The **cross-depth** instance survives untouched: a
> depth-1 committer still reads depth 0's tally in its denominator. That is item 10
> instance (a), and it is the larger of the two.
>
> Declaring P′-c closed on the strength of its same-depth instance would be the
> third knowing repeat of this milestone's own lesson — *a true statement one level
> away from the property you need is not a proof of it.* It is recorded open.

### Reward scoping

`winnersSeats` counts, per depth, only the round that **adjudicated** at that depth.
Non-adjudicating (banked) rounds are excluded; earlier depths stay in.

### `minReveals` bound

```
minReveals  <=  min over d in 0..maxDepth of runtimeTarget(d)
```

**Justification (replaces an earlier, weaker one).** The first derivation offered
was "quorum must be reachable on a single un-widened panel." That is true but does
not *imply* the bound — reachability-with-widening is also true and is weaker, so
the argument does not discriminate between them.

The reason is that **full quorum must be achievable without the failure path.**
Above the un-widened target, even perfect participation on a full panel leaves
`revealedSeats < minReveals`, so every round at that depth must widen to reach
quorum, every decision there is marked `underQuorum`, and by H-09 no such decision
can ever reach the supersafe view — at *any* participation rate. The parameter would
silently disable a product guarantee rather than merely tighten a quorum.

Reuses commit 2's `_runtimeTarget`, so it composes with the P1-3 clamping fix, and
it **replaces** the reachability check rather than adding a knob (it is strictly
tighter). Collaterally it guarantees a banked tally is smaller than the panel that
follows it.

### The freeze applies to banked rounds

**Reason (replaces an earlier, wrong one).** The first argument given was that a
penalty-free banked round lets a withholder stall at zero cost. That does not hold:
excluding banked revealers from the *incoherence* freeze leaves a withholder's cost
untouched, since a withholder takes the `Vote.None` branch.

The reason that does hold: **a penalty-free banked round makes revealing free, and
revealing is what selects which round adjudicates.** An attacker reveals in every
round at zero risk, and pays only in the one where its vote happens to land — a free
option over which round decides. The conclusion is unchanged; the argument for it is.

### Two hazards the implementation must clear

**Hazard 1 — apply the scoping at BOTH sites, or settlement reverts permanently.**
Excluding banked rounds from `_settleInit`'s `winnersSeats` while `_disposeSeat`
still pays `talliedSeats[a] / winnersSeats` on every round it walks leaves banked
revealers paying against a shrunken denominator, so `s.distributed` exceeds
`s.distributable`. `_settleFinish` (`Settlement.sol:489`) then computes
`s.bounty + (s.distributable - s.distributed)` and **underflows**.

That is a revert, not an overpayment: `claim` reverts, the case is stuck in SETTLING
forever, and every seat-holder's committed stake is locked permanently. Same failure
class as item 4.

**Test consequence, which is the part that is easy to get wrong.** A conservation
assertion *after* a successful settle cannot reach this — settlement never succeeds.
The test must assert at the boundary: drive a multi-round case with a banked round
containing coherent revealers, assert `claim` **completes** (phase reaches SETTLED,
not wrapped in `expectRevert`), and assert `distributed <= distributable` at the
final disposal step.

**Landed in 3a** as
`test_only_adjudicating_rounds_feed_a_payoff_and_settlement_never_overshoots`,
labelled a guard in its own body. Its fixture is a case whose appeal round never
adjudicates (`_failAppealRound`), settled one seat at a time with the boundary
checked between batches — `_settleFinish` runs in the same call as the last
`_disposeBatch`, so an overshoot is invisible after a settlement that completed. It
also pins that the gate SELECTS: `winnersSeats` equals depth 0's winning seats alone,
with `__adjudicated` asserted true for round 0 and false for round 1. A banked round
carrying coherent revealers is not constructible until 3b, so that stronger fixture
lands with the mechanism.

**Hazard 2 — the banked seat is pure downside, and it needs a number.**
`_disposeBatch` walks every round and `_disposeSeat` judges against
`c.finalOutcome`, so a banked round's seat earns nothing (post-scoping) and is still
frozen if incoherent.

The auditor's "sit out the early rounds" response is not available: P0-2 blocks
un-pledging while reserved, and item 8 made non-revealing cost the same freeze, so
revealing weakly dominates once seated. The real effect is on the **expected return
to pledging**, which is item 8's existing coupling. The arithmetic:

```
E[rounds at a depth]  =  (1 - s^4) / (1 - s)          s = P(a round stalls)
fraction of seats in banked rounds  =  1 - (1 - s) / (1 - s^4)   ~=  s   (small s)
```

| stall rate `s` | seats landing in banked rounds |
|---|---|
| 0.05 | 5.0% |
| 0.10 | 10.0% |
| 0.20 | 19.9% |

A banked seat's expected value is `-P(incoherent) x C` — freeze risk with no upside
— so a pledged unit's **reward income scales by `(1 - s)` while its freeze exposure
is unchanged**. The net effect is a reduction of `s x (reward per seat)`.

`s` is **not yet measured**. Bar pre-committed before measuring: **if `s > 5%` at
the dense fixture, a participation credit becomes item 10's business** (it needs the
per-round allocation item 10 must build anyway); at or below 5% it stays a recorded
residual against item 8's calibration.

### Deferral conditions for item 10, accepted

1. Its severity is recorded in the resolution record **now**, not at scheduling time.
2. It reaches the standing recommendation as a live reason that recommendation
   still holds.
3. **2b leaves the incentive purely cross-depth, so item 10's fix cannot borrow
   2b's shape.** 2b excludes non-adjudicating rounds *within* a depth; item 10 must
   reconcile aggregates *across* depths, where every round adjudicated. Different
   problem, different mechanism.

## Item 5 — five fixtures that read as coverage and were not (post-close)

A fixture that cannot discriminate is worse than no fixture: it occupies the slot a
real test would take and reports green while the property it names goes unchecked.
Five, from the cold audit's sweep. Each was fixed to discriminate, or deleted with
the reason; **every repair below was mutation-tested** — the guarded code was broken
and the fixture confirmed to fail.

| fixture | defect | disposition |
|---|---|---|
| `test_widen_cannot_loop_unboundedly` | no DRAW branch, so `else break` fired on the FIRST widen | **rewritten** against 2b's commit-time trigger |
| `test_settling_one_case_cannot_drain_another_cases_escrow` | passed `CASE_A` to all four calls | **fixed**, and the assertions strengthened |
| `test_reauthorization_does_not_inherit_old_handles` | drained before revoking, so the revert was over-determined | **renamed**, one assertion deleted |
| `test_max_panel_completes_in_bounded_batches` | drove the default 5-seat panel, never read `L.MAX_PANEL` | **fixed** to drive the cap |
| P0-3c's `frozen` disjunct in `drawPanel` | untested | **new test** |

### The two that needed more than a repair

**`test_widen_cannot_loop_unboundedly` was vacuous in the worst way — it exited
before the thing it names could happen.** The loop had no DRAW branch, so the `else
break` fired the moment the first widen sent the round back to DRAW: one iteration,
`widenCount == 1`, and `assertLe(1, MAX_WIDEN)` passes whatever the contract does. A
widen that looped forever would have passed it too.

Rewritten rather than repaired, because 2b moved the trigger: the widen now fires at
close-of-COMMIT and spends the SHARED per-depth counter that stall rounds also draw
on, so the bound to assert is that counter rather than one round's `widenCount`. It
now drives every phase including DRAW, asserts the bound at **every step** (an
overrun that corrected itself before the loop exited would otherwise be invisible),
and asserts the budget was **fully spent** — so it cannot pass by never approaching
the bound.

**`test_settling_one_case_cannot_drain_another_cases_escrow` needed two fixes, and
the second was only visible under mutation.** Passing `CASE_A` to both draws made
"two cases" one obligation seated twice. But repairing that alone still did not
discriminate: with symmetric one-unit settlements, a per-case obligation and one
merged pool produce identical numbers, and the fixture passed against a registry
bounding by the pooled totals. Over-asking is the only shape where the property is
observable — case A now settles **two** units against an obligation holding one, and
B's unit and escrow must both survive. Under the pooled-bound mutation that
underflows, which is the defect this test is named for.

### The one that is unreachable by construction

**`test_reauthorization_does_not_inherit_old_handles`** closed by expecting
`NotYourObligation` on an old `caseRef`, presented as proof that old handles are
unreachable. It proved nothing: the fixture must RELEASE before revoking, because
`revokeLogic` requires `canRevoke` and `canRevoke` requires a full drain — so the
obligation was already empty, and `NotYourObligation` is what an empty obligation
returns whether or not the namespace rotated.

**The stronger property cannot be tested, and that is the finding rather than a gap
to fill.** A surviving old handle cannot exist across a revocation: P0-5b's drain
gate guarantees every obligation is closed before `revokeLogic` succeeds. No fixture
can discriminate on it, and one that appeared to would be reading an empty slot.
Renamed to `test_reauthorization_rotates_the_handle_namespace`, which is the
observable part, plus an assertion that the NEW namespace is live — so the rotation
is shown to have preserved function, not merely broken the old one. The case where
orphaning IS reachable is P0-5d's live-logic test.

### The disjunct that looked dead and is not

`drawPanel` denies a seat on `block.timestamp < m.frozenUntil`, and that clause had
no test. It is easy to read as dead — `_eligibleWeight` returns 0 for a frozen
moderator, so a frozen address should not be in the tree to draw.

It is live, and P0-3 is the reason: `freeze` calls `_syncTree`, which **stages** the
weight change to the next epoch boundary. A moderator frozen mid-epoch keeps its tree
weight for the rest of that epoch and can still be drawn — the disjunct is the only
thing stopping it taking a seat it can no longer back. The new fixture asserts the
tree still carries the weight while the live weight is already zero, or the denial
would be equally explained by an empty tree, and it fails when the disjunct is
removed.

## Item 8 — freeze economics, priced (post-close)

**The defect.** Withholding a reveal took `failedRevealFreeze`; revealing
incoherently took `s.freezeDur = freezeBase × power`. At the shipped ruleset that is
1 day against 7–28. The reward term **cancels** — both rungs forfeit it — so the
duration gap was the entire price difference, and a moderator who suspected it was
about to be on the losing side could pay a seventh to a twenty-eighth of the penalty
by going quiet. Withholding was the cheapest way to be wrong.

**Shape taken: delete the withhold-specific duration.** A non-revealer and an
incoherent revealer now reach the same line in `_disposeSeat`. The parity is
**structural** — there is no inequality to validate, no second duration to keep in
step with the first, and no cross-parameter invariant. `k = 1`: any multiplier would
reintroduce exactly what collapsing the branch avoids. `failedRevealFreeze` is
deleted from `Params`, from the constructor and from `_validateParams`, so a ruleset
now sets **one** freeze duration. Same family as `penalizeNoShow` (P0-5c),
`voluntaryCutEpoch` (P0-3d) and `unbackedSeats` — a governance parameter that
nothing reads is still proposable, validated, and implies it does something.

**The VOID rung.** A VOID never runs `_settleInit`, so there is no winning side, no
mean track and no `s.freezeDur` — it is zero, and using it would mean no freeze at
all. It takes **`freezeBase`, unamplified**, and that is not a third number invented
for the path: `FreezeMath.freezeDuration(0, …)` returns `baseSeconds` exactly,
because power at a zero mean track is 1. A VOID therefore prices non-participation at
the power-1 end of the range the adjudicated path can produce, which is the honest
reading — the protocol learned nothing about who was right, so it applies the base
rather than guessing an amplification.

**The no-show rung, priced in the same commit.** Pricing withhold alone would only
move a rational actor to the cheaper rung and change nothing. `_settleDuty` charged
ONE `riskPerSeat` regardless of seats held, so a moderator drawn onto *k* seats paid
1/*k* per seat for ignoring all *k* — the gradient ran backwards for exactly the
actor the rung exists to price. It is now `seats × riskPerSeat` for `s.freezeDur`.
P0-2 makes the bound structural rather than a cap: escrow **is** `seats ×
riskPerSeat`, so the registry's own clamp already sits at that value and the penalty
cannot overshoot or reach another case's collateral.

The property is monotonicity — non-participation is not cheaper than participation,
and the rung that also avoids committing is not the cheapest of all. It is asserted
as parity rather than as a number, because a number goes stale the moment governance
moves and the parity is the property.

### Honest downtime, as a number

This is a real cost to honest operators and it is not small. An operator whose node
is down across one reveal window previously lost eligibility for **1 day**. It now
loses eligibility for **7 days at minimum, and up to 28** at the top of the freezing
curve (`freezeBase` 7 days, `freezeCap` 4). That is a 7× to 28× increase in the
penalty for a power cut, and it is the same penalty a deliberate withholder pays,
because the chain cannot tell them apart. Anyone calibrating `freezeBase` is
calibrating that, not just the attack.

### The feedback loop with item 2b, which runs both ways

Harsher non-reveal penalties thin the operator pool. A thinner pool produces more
participation shortfalls. More shortfalls produce more stall rounds. More stall
rounds enlarge item 2b's banked-tally residual — the option that is decisive on the
final round of the budget at the quorum margin. And in the other direction, 2b's
residual is acceptable **only because it is priceable**, and this item is the price.

The two items are therefore coupled in both directions and the calibration is chosen
against both, not against item 8 alone. Raising `freezeBase` to deter withholding
makes 2b's residual worse; lowering it to protect honest operators makes withholding
cheap again. There is no setting that optimises one without moving the other.

### Known and excluded: recoverable reveals

Same category as hiding reveals — named so a re-auditor does not read them as
misses, not because they were overlooked:

- **Escrowed salts** — a voter deposits its salt with a third party or a contract
  that can reveal on its behalf if it goes dark.
- **Threshold decryption** — commitments encrypted to a committee that opens them at
  the reveal deadline, so a vanished voter's vote is still counted.
- **Third-party reveal** — anyone holding a valid `(vote, salt)` pair being able to
  submit it for the committer.

Each would make withholding structurally impossible rather than merely expensive,
which is a strictly stronger property than the one this item buys. All three replace
the commit-reveal scheme with a different cryptographic construction and a different
liveness assumption (a committee, or a counterparty), and that is a protocol
redesign, not a calibration. Excluded on scope, deliberately, and recorded here so
the choice is visible.

### Residual, merged here from item 2b: the unrewarded revealer

**P1.** A moderator that reveals coherently and on time in a round that does not
adjudicate is **paid nothing**, while a moderator that fails to reveal in that same
round **is** frozen. Punished if wrong, unpaid if right.

Originally carried as a probabilistic residual — under a case-wide `winnersSeats` a
banked round's revealers were still in the denominator, so they might be paid. Item
2b's §4 scoping ends that: `winnersSeats` counts only the round that adjudicated at
each depth, so within a depth the non-payment is **definite**, not possible. Restated
here in those terms rather than left reading as a maybe.

**The freeze deliberately still applies to banked rounds.** The symmetry argument —
if a round does not count for reward it should not count for penalty — loses to a
concrete security consequence: a banked round with no freeze is a *free* round. An
attacker seated in round 1 could withhold at zero cost, force the stall, and be
re-drawn into round 2 with its stake untouched. That is P0-6c's amnesty hole one
door over, and item 8's unified freeze only makes revealing weakly dominant if the
freeze applies wherever the seat existed.

So the bargain, stated accurately: **a banked round's seat is a duty obligation, not
a claim on the pot.** Serving it avoids a freeze; it does not earn a share, because
the share belongs to the round that adjudicated. The asymmetry is real and is not
dressed up. Pricing it needs a participation credit carved from the distributable,
which requires the per-round allocation **item 10** already has to build — so the
instrument belongs there, not here.

### Not folded in

The reward-tally scoping question that item 2b raises — `Settlement`'s reward is
`distributable × talliedSeats[a] / winnersSeats`, and `winnersSeats` accumulates
across **every** round in `_settleInit` — is a 2b question, not an item-8 one. It is
recorded against 2b's revision. Item 8 changes what non-participation costs; it does
not change how the reward is divided.

## Item 10 — reward structure reads a different seat set than the outcome draw

**Severity: High. Live on shipped code. Two instances, one defect.** Found while
revising item 2b's reward scoping; neither instance is introduced by 2b and neither
is fixed by it.

### The condition, stated once

A voter's expected **reward** is

```
E[reward | vote v]  =  P(v wins) x D x s / winnersSeats(v)
                    =  (f_v / T) x D x s / (b_v + f_v)
                    =  (D.s / T) x f_v / (b_v + f_v)
```

where `T` is the deciding round's revealed seats, `f_v` that round's seats on side
*v* including the voter's own `s`, and `b_v` any OTHER seats the denominator counts.

`P(v wins)` reads the seat set `realizeOutcome:926` draws from — `_cur(c)`, one
round. The denominator reads the seat set `_settleInit:389` sums — every round. When
those are the same set, `f_v` cancels and `E = D.s / T`, **invariant in the vote**:
the reward is a participation payment and the freeze is the Schelling incentive.
When they differ, the residue `f_v / (b_v + f_v)` is the distortion, and it is
strictly decreasing in `b_v`.

> **The invariant: every aggregate that feeds a payoff must read the same seat set
> the outcome draw reads.** Everything below is that condition failing.

### But reward is not the payoff. The freeze term is the other half

**Correction to an earlier draft of this entry, which claimed the distortion is a
"dominant strategy with no exception".** That is false, and falsifiable in two
lines. The full payoff is

```
E[payoff | v]  =  (D.s / T) x f_v / (b_v + f_v)   -   (1 - f_v / T) x C
                  \________ reward ________/          \____ freeze ____/
```

with `C` the cost of one `s.freezeDur` freeze on `s` seats. **Both** terms increase
in `f_v` — the reward through `P(v wins)`, the freeze through the same probability.
Only the reward term sees `b_v`. So the contrarian branch buys reward at the price
of freeze risk, and when that price is high the honest vote wins:

> `b_A = 1`, `b_R = 0`, deciding round 10A/0R plus the committer's one seat.
> Vote A: `f_A = 11`, reward `D/12`, freeze exposure **0**.
> Vote R: `f_R = 1`, reward `D/11`, freeze exposure **10/11**.
> The flip buys `D/132` and costs `(10/11) x C`. Honest wins for any `C > D/120`.

**Where the finding actually holds, stated exactly.** The freeze terms cancel when
`f_A = f_R` — an evenly split deciding round. There, flipping to the side carrying
fewer prior seats pays

```
E_contrarian / E_crowd  =  (b_A + f) / (b_R + f)  =  1 + b_A / f      (one-sided prior)
```

at **identical** freeze risk. As the round becomes lopsided the freeze differential
grows linearly in `|f_A - f_R|` while the reward gap stays bounded, and honesty
recovers.

That is not a weakening in the cases that matter. A round splits evenly exactly
when a single vote moves the outcome draw most, so **the distortion is strongest
precisely where votes are pivotal and washes out where they are not.** A defect
that bites only on the decisive cases is worse than one that biases everything a
little, not better.

### The second cross-set aggregate, and why it is excepted

`meanTrackNum` (`:440`, `:443`) accumulates the winning side's track across **all**
rounds and is divided by case-wide `winnersSeats` at `:479` to set `s.freezeDur`.
Same structural shape as `winnersSeats`, on the freeze axis rather than the reward
axis: a non-adjudicating round's revealers move the penalty applied to the deciding
round's losers.

**Excepted deliberately, on magnitude and on the absence of a beneficiary:**

- **No one is paid.** A longer freeze transfers nothing (invariant 2). The reward
  distortion can be monetised; this one can only be used to grief, and the griefer
  must itself be coherent to enter the mean at all.
- **It is a mean, not a sum.** Extra seats pull the mean toward their own track
  rather than scaling it, so the lever is bounded by how far one track sits from
  the average.
- **The curve saturates.** `power = 1 + (cap-1)(1 - e^(-mean/sat))`, so
  `dpower/dmean = (cap-1).e^(-mean/sat)/sat`. At the shipped ruleset (`cap = 4`,
  `sat = 60`, `base = 7 days`) that is at most `0.05` per unit of mean track, i.e.
  **~0.35 days per unit** — and shifting the mean by one unit against ten winning
  seats needs a seat sitting ten track above it. One high-track seat in a banked
  round is worth roughly **5% of a 7-day freeze**.

Recorded as an exception rather than omitted, because the invariant above quantifies
over *every* aggregate feeding a payoff and an unstated exception is how the next
instance hides.

### Instance (a) — appeal panels are paid to overturn

Depth 0 tallies 5A/0R, outcome Approve, appeal filed. Depth 1 seats eleven; the
other ten split 5A/5R; a one-seat committer:

| vote | E[reward] |
|---|---|
| Approve (upholding) | `(D/11) x 6/11` = **0.0496 D** |
| Reject (overturning) | `(D/11) x 6/6` = **0.0909 D** |

**Flipping pays 83% more at identical freeze risk.** This fixture is the symmetric
case — `f_A = f_R = 6`, so both branches carry the same `5/11` chance of being
frozen and the freeze term cancels exactly. What is left is the reward ratio
`(b_A + f) / (b_R + f) = 1 + 5/6 = 1.83`, which is where the 83% comes from: it is
derived, not measured off one fixture.

The advantage is **net**, not gross, only because the round splits evenly. Lopsided
rounds recover honesty — see "But reward is not the payoff" above, and the
counterexample there. An evenly split round is also the one where a single vote
moves the outcome draw most, so this is the pivotal case rather than a corner of it.

The disclosed quantity is a full depth-0 panel, and depth-0 tallies are public
through `roundInfo` and the depth-0 outcome itself.

Reachable on **every appealed case, with no attacker**, on the code as shipped.

### Instance (b) — suppressing turnout enriches the survivors

Per-seat payout is `D / T`, so it rises as turnout falls. `_closeReveal:1280` marks
`underQuorum` and arms the outcome whenever reveals are nonzero after the retry cap,
so a one-seat under-quorum adjudication takes `D x 1/1` — **the entire
distributable**. Two revealed of a five-seat panel pays `0.5 D` per seat against
`0.2 D` at full turnout.

Same root cause: the denominator shrinks with turnout while the pot does not.

### Why one item

Fixing either alone leaves the other reading the mismatched seat set, and the
neutraliser for (b) requires the per-round allocation that fixing (a) forces. They
are the same defect at two scales.

### The neutraliser, derived

```
distributable  x  revealedSeats / commitTarget(depth)      per adjudicating round
```

giving per-seat payout `D / commitTarget(depth)` — **constant, independent of
turnout**. This is the unique scaling with that property; `revealedSeats /
minReveals`, the first form considered, still leaves a 2.5x advantage at the shipped
depth-0 ruleset.

Remainder destination: **refund to the submitter.** They paid for a full panel's
adjudication and received a partial one, so the unpaid share returns. That is a
principled answer rather than an arbitrary one, which matters because every other
destination (bounty, burn, carry-forward) invents a policy to dispose of money the
protocol did not earn.

### Sizing constraint: item 10 must be built against POST-2b code

Item 2b's §4 scoping shrinks `winnersSeats` to adjudicating rounds only. That
**raises** per-seat payout, so 2b makes instance (b) larger, not smaller. The
neutraliser still composes — `D / commitTarget(depth)`, constant, applied per
adjudicating round — but its calibration must be measured against a denominator that
exists after 2b lands. Sizing it against today's case-wide `winnersSeats` would
calibrate against a quantity 2b removes.

Ordering follows: **2b first, then item 10.**

### A pattern worth naming

Item 10 is not the first place this milestone where the audit named a real defect
and the wrong failure mode. Substantiated from this record:

- **K-4 / `penalizeNoShow`** — filed P1 as an unused function ("no production
  caller"). The actual mode was an unscoped write to *pooled* `dutyBonded`, able to
  freeze collateral posted for a different case's live seat.
- **MAX_PANEL** — filed as a calibration note ("not evidence-based"). The actual
  mode was permanent unfinalizability of every case opened under a ruleset H-11 pins
  per case.
- **Item 4 / token identity** — named as "silently makes the registry insolvent in
  one asset while accumulating another", an accounting mismatch. The actual mode is
  a **finalizability break**: `reward()` pulls the registry's token from a contract
  that does not hold it, `claim` reverts, and seat-holders' committed stake is
  locked permanently — presenting intermittently, because VOIDs still drain.
- **Item 10 itself** — named as follow-the-crowd, "a later committer computes its
  exact share by joining the winning side". The actual direction is **contrarian**,
  the direction is contrarian rather than crowd-following, it is decisive rather
  than an estimate wherever the deciding round splits evenly, and it is live in
  appeals with no 2b involved. (The first correction of this entry then *over*-shot
  in the other direction, claiming a dominant strategy with no exception — see the
  freeze-term counterexample above. Recorded because over-correcting a finding is
  the same failure as under-stating it.)

The recurrence is the point: in each case the named mode was plausible enough to set
the severity, and the real mode was worse. Severity assigned from a finding's
*description* rather than from tracing its call path has been wrong every time it
has been checked here.

## Size position — RESOLVED by the second structural split

> **Superseded 2026-07.** Everything below was written when `Moderation` had 439
> bytes free and described the split as a precondition. **The split has landed.**
> Settlement — initialisation, the per-seat disposal loop, the finish and its index
> effects — moved into `src/lib/Settlement.sol`, a DELEGATECALLed library.
>
> `Moderation` **24,137 -> 19,964 B, free 439 -> 4,612**. `Settlement` is 5,596 B
> deployed separately. Suite unchanged at 218 tests / 18 suites; the only test-side
> edits are one identifier in `ModerationHarness` (`openPotsTotal` is now a getter
> over a grouped `Money` struct, layout-identical) and one harness call repointed at
> the registry after `_deleteEntry` moved.
>
> The seam was chosen by measurement, not by size alone: settlement is both the
> largest candidate (5,688 B stubbed) and the furthest from the round state machine,
> which is where the widen restructure has to fit. Appeals (2,369 B) was rejected
> because `_failAppealRound` is reached from `_closeReveal` and
> `resolveStalledDraw` — moving it would put a cross-boundary call *inside* the
> machine the split exists to make room in. Submission (3,012 B) was rejected
> because `submit` writes case storage and calls `_openRound`.
>
> **Correction (split follow-up).** VOID disposal (913 B) was rejected on that same
> structural ground and the reason was **wrong**: it said `_voidStep` is reached
> from `_closeReveal`. It is not. `_closeReveal` and `resolveStalledDraw` call
> `_void`, the O(1) phase flip; `_voidStep` is reached only through `claim` ->
> `_settle`, already across the boundary. It has since moved
> (`Settlement.settleVoid`), which also deleted the three duplicates leaving it
> behind had cost — `_settleDuty`, `_freezeSlice` and `_clearDedup` each existed in
> two copies, a penalty rule stated twice being the divergence this milestone keeps
> finding. `Moderation` 19,964 -> **19,203 B** (free 4,612 -> **5,373**);
> `Settlement` 5,596 -> 6,645 B. Suite unchanged at 218 tests / 18 suites, with no
> test-side edits at all.
>
> One measured lesson worth keeping: an intermediate shape that moved only the
> disposal loop and left `_settleInit`/`_settleFinish` behind saved **298 bytes net**
> — three call sites' worth of storage-pointer marshalling cost back almost
> everything the move freed. Collapsing to a single entry point is what turned that
> into 4,173.
>
> K-1, K-3 and K-5 now fit. The reasoning below is kept as the record of why the
> split was taken and what was weighed.

## Size position — the original analysis (kept for the record)

`Moderation` is at **24,137 bytes, 439 free** against the EIP-170 limit of 24,576.
It gained **841 bytes across this batch** (23,296 at the `m2.6-close` tag).

**State the self-reference plainly, because it is one.** The margin is cited above
as a reason K-5 and others are deferred — and the margin is what it is *because of
the fixes in this batch*. `1,280 -> 439` was spent on P0-5b's index obligations,
P0-3b's drain-and-return, P0-6b/P0-6c's amnesty conditions and P0-5d's gate. So
"there is no room for K-5" is not an independent constraint discovered in the
environment; it is a consequence of choices made here, and a different order of
work would have produced a different answer. It is still the right call — a live
strand and a protocol-wide draw halt outrank an unscoped reputation write — but the
reasoning is circular unless it is written down, and an auditor is entitled to see
it rather than infer it.

That margin is the binding constraint on everything above, and it is not enough:

- **K-1 (keeper per-batch payment)** touches every batched path — the disposal
  loop, `_settleFinish`, VOID disposal and `realizeSeats` — and needs per-batch
  accrual state plus a payout split. Since the split follow-up, only `realizeSeats`
  is still in `Moderation`; the rest is in `Settlement`.
- **K-3 (one settlement reference time)** needs a `settleStartedAt` in
  `SettleState` and every `until` derived from it, across `_disposeSeat` and the
  VOID batch. Since the split follow-up moved VOID disposal, all of those sites are
  in `Settlement` — this one no longer costs `Moderation` anything.
- **K-5 (`setTrack` scoping)** changes a registry signature, so every call site
  moves too — and `_touchTrack` is the sole caller, in `Moderation`. It also has a
  design question in front of it (per-logic or global track), which is a reason to
  take it deliberately alongside the split rather than squeeze it in.

None of the three fits in 439 bytes, and byte-scrounging has already been done twice this
milestone (the second time it bought 233 B, at which point "attempt first and see"
stopped being a test). **A second structural split is a precondition for the P1
work, not a fallback.** The plan is to take it deliberately rather than discover
the cliff mid-item.

The seam is not yet chosen. The candidates, in the order they look plausible:

1. **Settlement** (`_settleInit` / `_settleStep` / `_disposeSeat` / `_settleFinish`
   / `claimAppealPayout`) into a settlement module. It is the largest cold-ish
   blob left, it is where both K-1 and K-3 land, and it already communicates
   through `SettleState` — a defined interface rather than an arbitrary cut.
   Against it: it touches nearly all of `Case`, so the storage would have to stay
   in `Moderation` and be read across the boundary, which is what ruled out moving
   ruleset storage in the first split.
2. **Appeals** (`contributeAppealBond` / `appealFloor` / `claimAppealPayout` /
   `_failAppealRound`). Smaller and more self-contained, with money that is
   already tracked separately (`totalPendingBond`, `totalPendingPayout`). Buys
   less.
3. **Submission entry points** (`submit` / `submitRemoval` / `submitLegacyRemoval`
   / `_openRemoval`). Cold, and the validation is bulky — but they write case
   storage on creation, so the same cross-boundary problem applies in its worst
   form.

Whichever is taken, the rule the first split established holds: `Moderation` is
the EIP-170-bound side, so wide return types and cold validation belong elsewhere,
and hot-path storage stays put.

## Still open (P1/P2, none blocking)

P1-1 (**re-scoped**: inert widen seats, and the reopened commit window — NOT
"widen escrow", which was a misreading of a test harness; **P0-6c's over-penalised
widen tranche is filed here too**, since separating tranches needs the same
per-seat window provenance and should be built once), P1-3 (validator runtime
state space — partly done via the MAX_PANEL and freeze bounds), P1-4 (retry
economics, = K-2), P1-6 (`balance >= liabilities`), P1-7 (widen tranche deadlines
— shares a mechanism with P1-1(b), fix together), P1-8 (one penalty reference
time, = K-3), plus K-1 (keeper per-batch payment) and K-5 (`setTrack` is not
obligation-scoped — the residual of P0-5, severity High), and the P2 list.

**Item 10 is not in that category and this heading does not cover it.** It is a
live defect on shipped code at severity High — appeal panels paid to overturn
wherever the deciding round splits evenly, plus turnout suppression enriching the
survivors — and it is
deferred only because its fix must be calibrated against post-2b code. See "Item 10"
above.

These go to the external reviewer as known-open rather than being worked in
another internal round. K-4 was the exception and is closed, because it was a P0
misfiled as a P1.

**Item 10 is a live reason this recommendation still holds.** It was found by an
internal review pass, on shipped code, on the protocol's core claim — and it had
been read past by two prior audits, each of which named a real defect under a
failure mode that set the severity too low (see the pattern list in "Item 10").
A finding of that shape and severity surviving this long is the argument for the
external review, not against it.

**Two items landed in this milestone that move the same cost in the same direction,
and a re-auditor should find that stated rather than reconstruct it.** Item 8 priced
non-participation by raising the withheld-reveal freeze from `failedRevealFreeze`
(1 day) to `s.freezeDur` (7 to 28 days). Item 2b's stall round then created a class
of seat — the banked seat — that carries that freeze with **no reachable reward**,
because the reward denominator excludes non-adjudicating rounds.

So: *the term item 7's residual is multiplied by grew 7x to 28x in the same milestone
that created the residual.* Neither item is wrong on its own and neither review
would have caught it alone, because the compounding lives between them. Reward income
scales by `(1 - beta)` where `beta` is the banked-round rate; freeze exposure does
not scale at all. Whoever calibrates `freezeBase` is setting both, and the two pull
in the same direction on a moderator's willingness to pledge duty — which is the
capacity the seat draw depends on.

Filed at item 7, with the banked-round rate as the trigger to revisit.

**P1-5 (quorum counts seats) is CLOSED.** It was already implemented — H-09's
`_fullQuorum` counts independent revealers, not seats — but the only test used one
address holding one seat, so the fix could be reverted with the suite green.
`M2.6-P0-2b` adds the discriminating test. The product decision it asked for is
recorded in `specs/state-machine.md` §8.1, which is now the single normative
statement of both `uncontested` and `fullQuorum`; `README.md` §3.8 and §2's `Entry`
comment defer to it instead of contradicting it.

## Standing recommendation

Unchanged in substance: no deployment with material funds, and the index is not
presented as reliable safe-search certification, until an independent re-audit of
the four-contract architecture passes **against the `m2.6-close` tag**. The last
code change is `51af155`; everything after it is documentation. A tag is used
rather than a hash because a commit cannot contain its own hash, so no pointer
written inside the history can name the commit it lives in. What has
changed is that the P0 set is now closed and the trust-model documentation matches
the code — `StakeRegistry`'s header should be re-read as part of that review, since
its "what this does NOT guarantee" section was written before P0-5 landed.
