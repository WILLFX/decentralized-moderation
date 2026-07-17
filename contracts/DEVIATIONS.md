# M2 implementation deviations from `specs/state-machine.md`

Dated 2026-07-16. Every place the Solidity implementation departs from, refines, or
pins something the spec left open. Each entry: **what**, **why**, and **threat-model
impact**. The spec remains the structural source of truth; these are implementation
resolutions, not new mechanism.

---

### D-1. Randomness: `blockhash` snapshot with re-arm (spec §7)

**What.** The spec reads `block.prevrandao` "of the snapshot block, realized by the
first tx after it." The EVM cannot read a *past* block's `prevrandao`, so each round
instead snapshots `blockhash(snapshotBlock)` where `snapshotBlock = block.number +
SEED_LAG`. If nobody realizes the seed within the 256-block `blockhash` window, the
snapshot is **re-armed** to a fresh future block.

**Why.** `blockhash` is the only in-EVM way to bind randomness to a specific past
block. Re-arming keeps the mechanism live if the realize-poke is late.

**Threat model.** Unchanged from the spec's accepted MVP assumption: a proposer can
influence the snapshot block within its slot; per-case leverage is small and a biased
listing stays re-litigable. The two-seed discipline is preserved exactly — `seatSeed`
is armed at round open, `outcomeSeed` only after the reveal window closes, so a voter
cannot withhold a reveal to steer a draw whose seed does not yet exist. Re-arming does
not widen the window (each arm is a fresh independent snapshot).

### D-2. Explicit `activate()` / `thaw()` pokes (spec §3)

**What.** The spec describes activation and freeze-release as "lazy: realized at next
draw / on next interaction." The implementation uses an **eager sortition sum tree**
that must always hold exactly the draw-eligible weight, so lazy realization is not
possible — `activate(addr)` and `thaw(addr)` are explicit, **permissionless** pokes.

**Why.** The tree is the draw structure; its weights must be current at draw time. A
keeper (or the moderator) pokes activation once the delay elapses and thaw once a
freeze expires.

**Threat model.** Permissionless and monotone-beneficial to the target (activation
only adds eligibility once earned; thaw only releases already-expired freezes), so
there is no griefing surface. A moderator who never pokes simply stays out of the tree
— their loss, no one else's gain.

### D-3. `RISK_PER_SEAT` — new §1 parameter (spec §3)

**What.** The spec left the per-case at-risk amount "TBD by simulation." Pinned to a
new working parameter `RISK_PER_SEAT = MIN_STAKE` (10 xBZZ). `commitVote` locks
`RISK_PER_SEAT × seatsWon` from free → committed.

**Why.** Commit locking needs a concrete number; `MIN_STAKE` is a natural floor and
keeps a multi-seat voter's exposure proportional to its panel presence.

**Threat model / open.** Uncalibrated — the M1 simulation did not model per-case
locking. It bounds a voter's per-case downside and should be swept in a future M1 pass
against griefing (locking too little) vs. participation cost (locking too much).

### D-4. Activation clock on top-ups (spec §3, unspecified)

**What.** New stake enters a `pending` bucket and becomes draw-eligible only after
`ACTIVATION_DELAY` + an `activate` poke. A top-up re-arms the delay for the pending
bucket **only**; already-activated stake stays eligible.

**Why.** Prevents just-in-time staking from gaming a specific draw, without punishing
established moderators who add stake (their existing eligible weight is untouched).

**Threat model.** Closes the "stake right before the target case's draw" vector. A
top-up cannot be rushed into a pending draw.

### D-5. Appeals: exact-floor cap, unmet-floor reclaim, no appeal-round VOID (spec §5.3/§5.4)

**What.**
- Contributions to a flip-bond are **capped exactly at the floor**; the contributor
  that reaches it takes a partial fill and only the accepted amount is pulled.
- A bond that never reaches its floor (no round opened) is **reclaimable pull-style**
  once the case is terminal (`reclaimBond`). A bond that *did* floor joined the pot and
  is settled in `claim()` (refund + bonus if the appeal won, forfeit if it lost).
- An appeal round (depth > 0) that gets **zero participation** after `MAX_WIDEN` does
  **not VOID the case**; the appeal fails and the prior round's outcome stands
  (FINALIZED). Only a depth-0 round VOIDs (no prior outcome exists).

**Why.** The spec is silent on partial/unmet bonds and on an unparticipated appeal
round. Capping avoids over-collecting; pull-reclaim avoids stranding unmet funds;
finalize-to-prior avoids discarding a fully-adjudicated case because a *frivolous*
appeal drew an empty panel (and keeps `_void` simple: depth-0-only, no bond
unwinding).

**Threat model.** A frivolous appellant cannot force a VOID (which would erase a valid
outcome); they lose their bond and the prior outcome holds. Unmet contributions are
always recoverable, so a failed bond-raise costs only gas.

### D-6. Dust swept to the claim bounty (spec §6.2)

**What.** Every pro-rata division in settlement rounds **down**, and the accumulated
remainder (reward dust + bonus dust) is added to the **claim bounty** paid to the
settling caller.

**Why.** Makes funds conservation (invariant 11) an **exact integer equality**
(`fee + Σbonds == Σrefunds + claimBounty + Σbonuses + Σrewards`), never a tolerance.

**Threat model.** The claimant earns at most a few wei of dust beyond the nominal
bounty — economically irrelevant, and it is the same party the protocol already pays
to finalize. No new incentive.

**C-01 refinement.** The *bonus-channel* dust is no longer swept into the claim
bounty. Bonuses (and their refunds) are now pulled per contributor
(`claimAppealPayout`, see D-7), and computing the exact bonus dust at settlement
would require iterating the contributor set — the very unboundedness C-01 removes.
Instead the whole bonus pool is booked as pending at settlement and the **final
appeal-claimer absorbs the pro-rata dust** (a running `apBonusPoolLeft /
apContribTotLeft` pair drains to zero exactly). Conservation stays an exact
equality, and the dust stays *retrievable* rather than stranded — the point the
senior audit pressed (conservation ≠ retrievability). Reward-channel dust still
sweeps to the bounty as above.

### D-7. Reward vs. payout channels (spec §6.2, implementation choice)

**What.** Voter rewards and returned committed stake are credited to the moderator's
`free` balance (an internal pull — they withdraw via the normal exit path). Appeal
refunds + bonuses to contributors are pulled per contribution via
`claimAppealPayout(caseId, depth)`.

**Why.** Avoids looping token transfers to arbitrary addresses inside `claim()` — a
reverting recipient contract could otherwise brick settlement (DoS). Everything is a
pull.

**Threat model.** Removes a settlement-DoS vector. No recipient can block another's
payout or the case's settlement.

**C-01 update.** The original design credited each contributor eagerly into a
`pendingPayout` mapping *inside* `claim()`, which still iterated the whole
contributor list — an attacker funding a winning bond from thousands of addresses
could push that loop past the block gas limit and **permanently strand the pot and
all committed stake** (conservation held; retrievability did not). Settlement no
longer touches the contributor set at all: it records only two case-level running
totals (`apBonusPoolLeft`, `apContribTotLeft`), and each contributor pulls its
refund+bonus later via `claimAppealPayout`, O(1) and independent of contributor
count (measured: identical 232,714 gas for 2 vs. 2,000 contributors). The
`pendingPayout` mapping / `claimPayout` are removed.

### D-8. Seat draw over the live tree (spec §7)

**What.** The spec draws "over the moderator set as it existed before the round
opened." The implementation draws from the **live** tree at `realizeSeats` (and at each
widen), not a snapshot of the tree at round open.

**Why.** Snapshotting the entire tree per round is prohibitively expensive on-chain.
Within a single `realizeSeats` all seats are drawn from one consistent tree state; a
widen draws from the then-current tree (which excludes voters who have since committed
to this case — desirable).

**Threat model.** Minor. Between round-open and a widen, a moderator could stake and
activate to enter the pool — but `ACTIVATION_DELAY` (7 days) far exceeds the intra-case
timescale, so no realistic just-in-time entry exists. Documented as a residual, not a
live vector.

### D-9. `TopicCreated` emits the topic key, not the string (spec §8.4)

**What.** The spec's `TopicCreated(string)` is emitted as `TopicCreated(bytes32
topicKey)` on the first index write under a topic.

**Why.** Topic keys are `keccak(normalize(topic))` where `normalize` includes NFC —
infeasible on-chain. The contract only ever holds the hash; the client maintains the
key→label mapping for autocomplete.

**Threat model.** None (event-only, for UI). The dedup/index semantics are unchanged.

### D-10. Track decay is once per unique participant per case (spec §6.5)

**What.** Track updates iterate the **unique** set of committers across all rounds, so
a moderator on several rounds of one (disputed) case decays exactly once.

**Why.** Spec-faithful ("everyone else's track only decays" — singular per case) and
required for the differential test to match the integer reference exactly.

**Threat model.** None; it is the intended semantics, made precise.

### D-11. Governance changes the whole `Params` struct behind a timelock (spec §9.9)

**What.** Governance proposes a full replacement `Params` (plus the depth arrays),
validated for solvency/liveness sanity, executed after `timelockDelay`. Guidelines are
appended (never mutated) through the same timelock.

**Why.** A whole-struct swap is simpler and safer to validate atomically than
per-field setters; core transitions have no mutation path at all (they are code), so
only the §1 numerics and guidelines history are mutable — exactly the governance bound
of invariant 9. Withdrawals have no admin gate anywhere (§9.5).

**Threat model.** Governance cannot touch mechanism, cannot pause withdrawals, and
cannot rewrite guidelines history — only append. The timelock gives moderators warning
to exit before any parameter change takes effect.

### D-12. Widen re-draw onto an already-revealed voter is inert (spec §5.3, F2)

**What.** A widen draws additional seats from the live tree and can land them on a
voter that has already committed and revealed this round. The extra seats bump
`Round.seats[voter]` but **not** `Round.talliedSeats[voter]` (frozen at reveal), and
settlement (rewards, winners' seats, mean-track) reads `talliedSeats`. So the
re-drawn seats are drawn but **uncounted**.

**Why.** The voter's reward and mean-track weight must reflect what they were tallied
for, not seats they never re-committed to. The alternative — excluding
already-committed voters from the widen draw — is rejection sampling with unbounded
gas.

**Threat model.** Closes a reward-siphon: without this, a high-stake early revealer in
an under-participating (widened) round would collect extra reward-lottery weight per
widen at its co-winners' expense, and skew the freeze-power mean-track input. The
phantom seats now change nothing.

### D-13. Batched settlement with a persistent cursor (spec §6, H-04)

**What.** `claim()` no longer settles a whole case in one transaction. Settlement
computes its aggregates once in O(rounds) — winners' seats, mean-track, refunds
are read from per-round, per-side accumulators frozen at reveal — then disposes
seat-holders through a `(round, idx)` cursor. `claim(caseId)` settles unbounded in
one call (fine for any realistic case); `claim(caseId, maxSteps)` settles in
bounded batches. The case moves FINALIZED → SETTLING → SETTLED; in-flight pot value
sits in `totalSettling` (0 outside an active settlement) so conservation is exact
at every intermediate state. Track decay is deduplicated in O(1) via a per-case
`trackDecayed` map, replacing the old O(participants²) scan.

**Why.** The documented "86-voter worst case" was not the reachable worst case. With
`MAX_WIDEN = 3` each depth can draw 4× its target, so a maximal case reaches
20+44+92+188 = 344 committed seats. One-shot settlement of that case costs ~30.3M
gas — over any real block limit — which would leave the pot and all committed stake
permanently stranded (Invariant 8 violated). Batching makes settlement's per-call
gas bounded (measured max batch ~3.7M) and independent of case size.

**Threat model.** Closes the finalizability failure behind H-04 (an adversary
widening every depth and mostly failing to reveal could push settlement past the
block limit). The mean-track accumulators are snapshotted at reveal, so freeze
durations no longer depend on the order in which finalized cases are claimed
(folds in audit M-03). The batch finisher receives the whole claim bounty; a
proportional split across batchers is a possible future refinement (in practice one
keeper settles all batches).

---

## Accepted liveness edges (M2; no code change — flagged for M4)

### L-1. A DRAW over an empty sortition tree has no timeout

If every activated moderator has exited/frozen, a case sitting in DRAW cannot
realize seats (`realizeSeats` reverts `NoEligibleModerators`), and there is no
timeout that VOIDs it — the fee stays in the pot until someone stakes, activates,
and the poke succeeds. Accepted for M2 (a live network always has an eligible set).
The obvious M4 remedy if it ever matters is a DRAW-age → VOID (refund) path, the
same shape as the reveal-phase VOID.

### L-2. ~~Removal `targetCaseId` is not validated at submit~~ — RETRACTED (fixed, H-01)

**Struck by the senior audit (H-01).** The original claim — that a lazily-resolved
removal target is a "harmless no-op" — was wrong. Because `_removeTarget` resolved
`cases[targetCaseId]` at *claim* time and IDs are sequential, a removal could name a
*future* case ID, finalize while unclaimed, and then delete whatever case later took
that ID (a blank-cheque deletion); the caller-supplied payload was also ignored at
settlement (display/act mismatch).

**Fixed (M2.5-P0-a → P0-c).** REMOVAL now goes through `submitRemoval(targetCaseId,
fee)`, which requires the target to be a **settled, approved, currently-indexed
SUBMISSION** and derives content/metadata/topics from it (fee scales with the
target's real topic count). Each SUBMISSION carries an `isIndexed` generation
signal (true on write, false on delete); `_removeTarget` no-ops if the target is no
longer indexed, so two concurrent removals resolve cleanly and a removal can only
ever delete the exact entries it was approved against. The generic `submit` now
rejects `REMOVAL` (`BadKind`).
