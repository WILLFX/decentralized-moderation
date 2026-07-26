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

**Tests.** Post-selection `setDutyUnits(0)`, post-selection `requestExit(all free)`,
commit-one-of-ten, and cross-case consumption of the same backing all leave the
penalty payable and applied; bonded collateral cannot be withdrawn, reduced, or
double-spent.

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

**Tests.** Every weight-changing path (`activate`, `thaw`, `setDutyUnits` up/down,
`requestExit`, `release`, `reward`, `releaseDuty`) cannot alter a draw whose entropy
is already public; repeated no-op `setDutyUnits` cannot delay a draw.

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

**Tests.** Cross-logic release/freeze/releaseDuty/setTrack all revert; `canRevoke` is
false until counters hit zero; a retiring logic rejects submissions but still settles;
a revoked logic refuses fees rather than trapping them; desynchronized registry
authorization is unreachable.

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
13. Deployment with a token that differs from `stakeReg.token()` (P1-2).
14. Deployment authorized in one registry but not the other (P1-2).
15. A ruleset that passes validation but exceeds `MAX_TOTAL_DRAWS` at runtime through
    target clamping (P1-3).
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

**Post-close.** An independent verification pass against that tag found three
blocking regressions in items this record marked closed, plus three fixes with no
discriminating test coverage. They are recorded in their own section below and are
fixed on top; the `m2.6-close` tag is deliberately NOT moved, because it is the
commit the audit ran against and moving it would invalidate that verification.
Current state: **199 tests, 16 suites**, green at every commit, `Moderation`
24,107 B (469 free).

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
already claimed closed, and each of the first three was a live blocker.

| Item | Commit | The regression, and what closed it |
|---|---|---|
| P0-5b was built on ONE registry | `3d3710f` | `StakeRegistry.revokeLogic` required `canRevoke`; `IndexRegistry.revokeLogic` required nothing. Governance could revoke index-side with a case in SETTLING; `_settleFinish` writes entries AND releases stake in the same call, so from that moment every `claim()` reverted `NotLogic`, the case never finished, its stake obligations never closed, and `StakeRegistry.canRevoke` never flipped. The stake-side gate did not prevent the strand — it guaranteed the deadlock was permanent. `IndexRegistry` now has `logicOpenCases` / `canRevoke` / `LogicStillHasObligations`, opened per case at submit and closed at SETTLED or VOID. The unit is the **case**, not the content reservation: removals take no reservation yet still delete at settlement, and an approved submission's reservation outlives its case by design. |
| P0-3's drain rolled back its own work | `bf003b3` | `drawPanel` drained `DRAIN_BUDGET` staged items and then reverted `EpochNotSettled` if that was not enough — unwinding the drain with the revert. Every draw redid the same first 64 items and discarded them again, so any epoch staging more than one budget halted **every draw in the protocol** until an external `advanceEpoch` call, whose progress survives only because it does not revert. Ordinary traffic reaches it: `_stageSeated` skips the dedupe flag by design, so one 48-seat panel plus normal joining passes 64 inside a 256-block epoch. Not closed by raising the budget — that moves the cliff. A settled epoch is now a precondition of `drawPanel`, which does no rollback-able work before checking it, and `realizeSeats` drains `EPOCH_DRAIN_STEPS = 128` and RETURNS, so repeated pokes recover with no keeper. |
| P0-6 covered one of its two paths | `0dae983` | `resolveStalledDraw` at depth 0 VOIDs and `_voidStep` checks `c.drawAbandoned`. At depth > 0 it calls `_failAppealRound`, so the case FINALIZES and drains through `_settleStep` — which did not check it, and froze one seat's stake per moderator seated in an appeal round whose draw was abandoned, for missing a commit window that never opened. |
| Three fixes had no discriminating test | `a02573d` | `_fullQuorum`'s independent-revealer check (the fixture used one address with one seat, so `revealedCount` and `revealedSeats` were indistinguishable), `_armSeed` on the widen path (only `_openRound`'s call was covered), and `unbackedSeats` — which P0-2 **did** make unreachable, so it is deleted rather than kept, with the reachability argument and an invariant test in its place. Also fixes `_supersafe`, which read the suite-level registry rather than the one the passed-in harness writes to, so both H-09 `length == 0` assertions held vacuously. |
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

Named here so a re-auditor does not read them as misses. None is a P0; none is
being fixed in this pass.

| # | Item | Severity | Why not P0 |
|---|---|---|---|
| K-1 | **Keeper per-batch payment.** Batched settlement (H-04), batched seat drawing (P1-2) and batched VOID disposal (P0-7) all pay the claim bounty to whoever sends the **last** batch. Every earlier batch is unpaid gas, so only the terminal one is incentivised and a large case can sit part-settled. | **P1** | Permissionless, and several parties hold a direct claim on completion — the submitter's refund, winning appeal contributors' payouts, and every seat-holder's committed stake are all released by it. It is an efficiency and latency problem, not a stuck-funds one. A pro-rata bounty split across batches is the obvious fix and is a pure economics change. |
| K-2 | **Retry economics (P1-4).** A REJECT clears the content reservation, so identical content is resubmittable at the base fee — cheaper than the ≥2× pot appeal, with a fresh panel and a fresh probabilistic draw. `N` retries succeed with `1−(1−p)^N`. | **P1** | Every attempt pays a real fee to real moderators, so it is not free; and the escalation it evades (appeal) exists for disputes, not for resubmission. Needs review history persisted in the **registry** so a migration does not reset the counter — which is why it is registry work, not logic work. |
| K-3 | **Settlement-order dependence, and per-batch freeze expiry.** `_disposeSeat` computes `until` as `block.timestamp + s.freezeDur` at the moment its batch runs, and `_voidStep` recomputes `freezeUntil` per batch. Two seat-holders of the same round therefore thaw at different times purely by which batch disposed them. The reward channel has the same shape: `distributed` accumulates across batches and the final claimer absorbs the pro-rata dust. | **P1** for the freeze, **P2** for the dust | The freeze duration itself (`s.freezeDur`) is computed once at `_settleInit` from state frozen at reveal, so nobody can *lengthen* a freeze by choosing the batching — only shift its start by however long settlement takes, which is bounded against a 7-day base. The dust is bounded by one wei per claimant and is a documented consequence of pull-based payout (C-01). Fix: snapshot one `settleStartedAt` in `SettleState` and derive every `until` from it. |
| K-4 | **`penalizeNoShow` is live on the registry but unreachable from `Moderation`.** Superseded by `settleDuty` (P0-2/P0-5), which is atomic and obligation-scoped. It still reduces the **pooled** `m.dutyBonded` without scoping, so an authorized logic that called it could reach another case's escrow — the exact class P0-5 closed elsewhere. | **P1** | No production caller; only the registry's own tests reach it. It should be deleted or given a `caseRef` in the next registry change. Listed rather than removed now because the registry is the permanent contract and removing a public function is a deployed-ABI change. |

**Closed in this pass rather than carried:** the governor's one-step
`transferGovernance` accepting `address(0)` — fixed in `M2.6-L-2` as propose /
accept / cancel with a zero check, matching both registries.

## Still open (P1/P2, none blocking)

P1-1 (**re-scoped**: inert widen seats, and the reopened commit window — NOT
"widen escrow", which was a misreading of a test harness), P1-3 (validator runtime
state space — partly done via the MAX_PANEL and freeze bounds), P1-4 (retry
economics, = K-2), P1-6 (`balance >= liabilities`), P1-7 (widen tranche deadlines
— shares a mechanism with P1-1(b), fix together), P1-8 (one penalty reference
time, = K-3), plus K-1 (keeper per-batch payment) and K-4 (`penalizeNoShow`), and
the P2 list.

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
