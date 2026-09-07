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

**Threat model.** ~~Minor~~ — **the original "minor" rating was wrong (senior audit
H-05).** `ACTIVATION_DELAY` bounds the *age* of the stake, not *when the holder
decides to activate it*: an attacker could keep matured stake unactivated, wait for
the seat seed's blockhash to become public, simulate panels under different
activation subsets, and activate the favourable one in the same transaction as the
draw poke. Widen was worse — its seed was `keccak(oldSeed, widenCount)`, containing
no new entropy, so a voter could compute the widened panel before deciding whether
to withhold a reveal and trigger it.

**Fixed (M2.5).** Two changes make the eligible set effectively frozen before the
entropy that draws from it is known:
1. **Eligibility-add version gate.** `activate()`/`thaw()` bump a global
   `eligibilityAddVersion`. A round records it when its seat seed is armed; if it
   differs at `realizeSeats`, the seed is **re-armed** to a fresh future block
   instead of drawing. Adding weight against a known blockhash therefore destroys
   exactly the seed the attacker was trying to exploit.
2. **Fresh entropy per widen.** A widen no longer derives a seed; it re-arms a new
   snapshot block and returns the round to `DRAW`, so each widen's panel is drawn
   from entropy that did not exist when anyone chose to withhold a reveal.

*Residual as recorded in M2.5 (accepted, one-directional gate).* **Both the gate
and this residual are superseded — see below.**

**Superseded (M2.6-P0-3, then P0-3c, then P0-3d).** The `eligibilityAddVersion`
gate above was deleted: it was griefable in one direction (`setDutyUnits(sameValue)`
bumped it with no change, re-arming every pending case for gas) and blind in the
other (`release`, `reward` and duty release all grew the drawable set without
bumping it). It was replaced by fixed-cadence eligibility epochs — weight changes
staged in epoch `e` take effect at the start of `e+1` — and then twice more, because
freezing the tree between epochs turned out not to be the property:

- **P0-3c (H-03A).** The tree was constant; the *seatable set* was not. `drawPanel`
  removed a rejected address from the tree to save attempts, which remapped every
  later interval, so a post-seed `setDutyUnits(0)` or `requestExit` steered the
  panel. P0-3c suppressed that write for voluntary reductions.
- **P0-3d (H-03A + H-03B).** That closed two levers, not the property: the
  exhaustion asymmetry survived downward, and the whole upward family survived
  across `realizeSeats` batches. **The draw now performs no writes to the sortition
  tree at all**, so the tree is immutable for a whole epoch and the address mapping
  is fixed before the seed is public.

**Sampling, stated honestly.** §5.2 specifies stake-weighted sampling **with
replacement**. Removing the exclusion makes the *offer* distribution exactly that —
each attempt samples the full epoch-start tree independently — where the old
exclusion was an undocumented drift toward sampling *without* replacement. The
*seat* distribution is still not §5.2's rule, because a live escrow check rejects
offers a moderator cannot back, and capacity depletion makes those rejections
correlated with how much a holder has already been seated. **More faithful, not
compliant.** Closing the remaining gap requires seating without a live collateral
check, which is exactly what P0-2 forbids.

*Residual (accepted, documented): cut-point mobility.* All divergence a post-seed
action can cause is confined to the tail of the panel. An actor that makes itself
seatable displaces the last accepted third party; one that makes itself unseatable
extends the run and adds a tail position. It can never substitute one third party
for another in the middle. Priced by stake share rather than by identity count — an
actor cannot choose *where* in the walk it appears, only whether to convert an
appearance into a seat — and every seat it takes costs escrow plus commit/reveal or
the no-show penalty.

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

**H-11 update.** Parameter changes no longer affect *in-flight* cases. Executing a
proposal seals a new immutable **ruleset version**; every case pins the version live
at submit (`Case.rulesVersion`) and reads all its consensus parameters from that
pinned ruleset, so a mid-case change can never move an open case's bond floor,
windows, freeze curve, quorum, etc. Pending exits likewise snapshot their cooldown
end and min-stake decision at request time (`exitClaimableAt`), so governance can
neither extend nor invalidate an exit already requested. Governance is additionally
bounded by immutable protocol **caps** (`MAX_RULE_DEPTH/WIDEN/PANEL/TOPICS/WINDOW/
FREEZE/BOND_MULT/SEED_LAG/TOTAL_DRAWS`) plus cross-field checks (e.g. minReveals
reachable within the widened depth-0 panel, total reachable draws ≤ the tested
settlement bound), so it cannot configure an unsettleable case or an overflowing
freeze — even by accident. `supersafeAge` and the fee floor stay live (display /
submit-time only, not consensus).

### D-12. Widen re-draw onto an already-revealed voter is inert (spec §5.3, F2)

**What.** A widen draws additional seats from the live tree and can land them on a
voter that has already committed and revealed this round. The extra seats bump
`Round.seats[voter]` but **not** `Round.talliedSeats[voter]` (frozen at reveal), and
settlement (rewards, winners' seats, mean-track) reads `talliedSeats`. So the
re-drawn seats are drawn but **uncounted**.

**Why.** The voter's reward and mean-track weight must reflect what they were tallied
for, not seats they never re-committed to.

*Corrected M2.6-P0-3d.* This entry used to reject the alternative — excluding
already-committed voters from the widen draw — as "rejection sampling with unbounded
gas". The first half is now the shipped design and the second half was the real
objection: the draw DOES reject offers it cannot seat, and what makes that safe is
that rejection is bounded (`ATTEMPTS_PER_SEAT × count`) and does not write the tree.
An exclusion-based version would be bounded too; what rules it out is that removing
an address remaps every later interval of the draw, which is H-03A. Recorded because
the original wording would send a reader looking for a gas problem that is not the
reason.

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

---

### D-16. A zero `timelockDelay` is accepted at construction (M2.6-F4)

**The property, stated so the acceptance is legible.** *Governance cannot change a
ruleset, a guidelines version, or the authorized logic contract without a delay
during which moderators can see it coming and act.* That is what the three
`timelockDelay` values are for.

**It is not enforced.** All three are `immutable` and unchecked in their
constructors — `RulesetGovernor.sol:101`, `StakeRegistry.sol:519`,
`IndexRegistry.sol:185`, one write each, the constructor, confirmed by enumeration.
A deployer may pass zero, and then every proposal is immediately executable. The
external audit raised this against the governor; the same hole is in both permanent
registries, where it gates the logic repoint — the protocol's trust root — and so
matters more there than where it was found.

**Why it is accepted rather than fixed with a floor.** A floor here is a governance
opinion compiled into an immutable, and it lands in the two contracts specifically
designed to be permanent. Getting the number wrong in `StakeRegistry` is not a
redeploy — it is migrating every staker, which is the single thing this architecture
exists to avoid; getting it wrong in `RulesetGovernor` costs a new `Moderation` too,
because `Moderation.governor` is immutable on the other side. The cost of a wrong
floor is highest exactly where the timelock matters most, and there is no number that
is obviously right for every future deployment (a testnet, a bootstrap period and a
mature mainnet want different ones).

**What holds instead. Three things, in decreasing strength:**

1. **Exit is never gated by logic** (trust model #2), and it is the load-bearing
   protection. A moderator's escape is `requestExit`/`withdraw` against the registry's
   immutable `exitCooldown`, which no timelock and no logic contract can extend or
   block. The timelock provides NOTICE; the cooldown provides ESCAPE. A zero timelock
   costs the notice and leaves the escape intact.
2. **H-11 pins the ruleset per case.** An instantly-executed parameter change cannot
   touch a case already open, so a zero-timelock ruleset change reaches only cases
   submitted after it.
3. **`Deploy.verify` refuses a zero timelock** on all three contracts, reading the
   values off the deployed stack rather than the config. This is the deliberate home
   for the policy: unlike an immutable it can be revised without migrating anyone.
   Pinned by `test_verify_rejects_a_zero_timelock`, because an acceptance whose only
   protection is a script is worth exactly as much as the script is tested.

**What does NOT protect it:** nothing in the contracts themselves. A stack deployed
without running `verify` has no in-contract floor at all, and the operator's published
parameters are the only remaining signal. That is the honest statement of the residual
and it is why the acceptance is recorded rather than assumed.

## M2.5 port: consequences of the storage/logic split

### D-11. Stake and index custody left `Moderation`

`Moderation` no longer holds moderator stake or index entries. Stake lives in
`StakeRegistry`, approvals in `IndexRegistry`, and this contract is the
replaceable *game* that governance repoints them at.

Consequences worth knowing:

- **Moderators call the registry directly** for `stake`, `activate`,
  `requestExit`, `withdraw`, `thaw` and `setDutyUnits`. Those entry points are
  gone from `Moderation` and were not replaced with forwarders — deliberately.
  Forwarding would put the game back in the custody path, and trust model #2
  requires that exit is never gated by logic.
- **Index reads kept their M2 ABI.** `entryCount`, `entryAt` and
  `supersafeEntries` remain on `Moderation` as thin forwarders so existing
  clients keep working. `supersafeEntries(bytes32)` is unpaginated, as in M2; a
  front end serving a large topic should read the registry's paginated
  `supersafeEntries(topic, minAge, cursor, limit)` (M-04) instead.
- **Conservation is a pair of identities**, not one:
  `balanceOf(Moderation) == openPotsTotal + totalPendingBond + totalPendingPayout
  + totalSettling` and `balanceOf(StakeRegistry) == stakeBuckets()`. Both are
  asserted in the unit suites, the differential replay and the invariant
  campaign. A reward transferred without being credited (or credited without
  being transferred) breaks exactly one side, which is the point.

### D-12. MIN_STAKE / ACTIVATION_DELAY / EXIT_COOLDOWN removed from `Params`

These three govern the custody path, which is the registry's, and they are set at
`StakeRegistry`'s construction. They were left in `Moderation.Params` by the
initial split, where nothing read them — governance could have proposed and
executed a new `exitCooldown` through the timelock and changed nothing at all.
They are removed rather than mirrored, so the parameter surface cannot lie about
what it controls. Changing them now requires deploying a new registry, which is a
migration, not a parameter change — appropriate for numbers that bound
withdrawals.

### D-13. `riskPerSeat` is duplicated across both contracts — deliberately, and bounded

`riskPerSeat` exists in *both* `StakeRegistry` and `Moderation.Params`. This is
not redundancy to be collapsed: they are two different quantities that happen to
share a name and, by default, a value.

| | `StakeRegistry.riskPerSeat` | `Moderation.Params.riskPerSeat` |
|---|---|---|
| Means | what one pledged **duty unit** is worth | what a case **locks per seat** |
| Layer | staking (custody) | consensus |
| Mutability | **`immutable`** — set at construction, no setter | governable, and **pinned per case** by ruleset version (H-11) |
| Used by | draw eligibility: capacity = unpledged units × this | `commitVote` collateral, no-show penalty |

Collapsing them is not available. Reading `stakeReg.riskPerSeat()` at commit time
would break H-11's guarantee that an open case's consensus parameters are fixed
at submit; making the registry's value governable would make draw eligibility
retroactively mutable, which is worse.

**Only one direction of divergence is harmful:** a case locking *more* than the
duty unit reserved for it. A panel would then be seated on collateral that cannot
cover its own seats. That state is now **unrepresentable**:

- `Moderation._validateParams` rejects any ruleset with
  `riskPerSeat > stakeReg.riskPerSeat()` (`RiskPerSeatExceedsDutyUnit`). This is
  why `_validateParams` is `view` rather than `pure`.
- The constructor applies the same bound to ruleset 0, which never passes through
  `_validateParams` — so a deployment cannot be born misconfigured either.
- The registry's value is `immutable`, which is what makes those checks
  trustworthy: a mutable duty unit could be lowered *after* a ruleset had been
  validated against it, re-opening the hole from the other side.

The other direction (locking **less** than a duty unit) is benign and remains
allowed: seats are over-collateralized relative to eligibility, which costs a
moderator nothing it did not already pledge.

Changing the duty unit therefore requires deploying a new registry — a migration,
which moderators can exit ahead of during the timelock (trust model #2) — rather
than a parameter change. That is the correct weight for a number that bounds
what stake can be locked.

Tests: `test_ruleset_locking_more_than_a_duty_unit_is_rejected`,
`test_registry_duty_unit_is_immutable`.

### D-14. `nSeats` counts seats seated, not seats sought

`drawPanel` seats only where collateral exists, so a panel can come back short of
the commit target when pledged duty capacity is scarce (H-07) — something the
monolith could not do. `Round.nSeats` now counts what was actually seated. The
`RoundOpened` event carries seats *sought*; `SeatsDrawn` and `Widened` carry seats
*seated*. Short panels are a liveness path, not an error: the round opens COMMIT
with whatever it seated, and under-participation falls through to the existing
widen and VOID handling.

---

# v3 implementation deviations from `specs/state-machine-v3.md`

M2.7, `contracts/src/v3/Moderation.sol`. The `D3-` prefix marks the v3 port; the
`D-` entries above are M2/M2.5/M2.6 against the v1 spec and are untouched.

Every entry: **what**, **why**, **threat-model impact**. The state machine remains
the source of truth; these are implementation resolutions, not new mechanism. Where
§4 was silent or self-contradicting, the entry says so and the question is carried
into the M2.7 report rather than settled here.

### D3-1. `IIndexRegistry` is declared by `Moderation`, not imported

**What.** `IndexRegistry` has not been ported to v3 (§Scope classifies it "survives
with edits" and it is not in this order's scope), so `Moderation` declares the
minimum surface §8 requires of it:
`writeEntry(bytes32 claimKey, bytes32 topicKey, uint8 status, uint8 plurality)`.

**Why.** §8.1 obliges the terminal transition to write the index, and §4.8 obliges
`NO_RANDOMNESS` to retain the published plurality *beside* the `UNRESOLVED` status.
Neither is expressible through a single status byte, so the interface carries both.

**Threat model.** None on its own — the mock in the suite counts writes so I15 can
be checked by count and order rather than by final state. The real risk is that the
v3 `IndexRegistry` is written to a different shape later; the interface is one
declaration and the port must reconcile it.

### D3-2. `Case` carries seven fields §4.1 does not list

**What.** `claimKey`, `contentHash`, `metaHash`, `submitter`, `topicCount`, plus
`drawBounty` and `claimBounty`.

**Why.** §4.1's struct ends with the comment *"content, metadata, topics,
ruleset/guidelines versions: as v2"*, which is where the first five come from. The
two bounty fields are not covered by that clause: §4.8's value-flow block says a
terminal *"retains finalizationBounty"*, which presupposes the case holds one, and
§1 splits the fee into five components of which §4.1 stores only two (`pot`,
`challengeReserve`). Recomputing a bounty from `pot` is not exact under integer
division, so the two amounts are stored.

**Threat model.** Storage only. Each bounty is paid at most once and zeroed, so a
re-review's second draw cannot re-pay a bounty the first already spent.

### D3-3. Refunds and shares are pulled, never pushed

**What.** A terminal transition credits `refundOwed[caseId]`; the submitter (or
anyone, on their behalf) calls `withdrawRefund`. Moderator payment already runs
through `claim(c, m)`.

**Why.** §4.8 says a terminal refunds the pot and reserve but does not say by what
mechanism. Pushing a transfer inside the transition lets a submitter contract whose
`receive` reverts brick the terminal for everyone — including the index write §8.1
requires and every moderator's discharge path. §5.5 already chose pull for
settlement; this is the same choice for the same reason.

**Threat model.** Strictly reduces surface. The failure it prevents is a submitter
who is a contract, which is not an exotic case.

### D3-4. `LATE_WIDEN_AT` is scaled from `commitBlocks`, not converted separately

**What.** §3.3's widening boundary is computed as
`roundOpen + commitBlocks · LATE_WIDEN_AT / COMMIT_WINDOW`.

**Why.** §3.3 compares `t` against `roundOpen + LATE_WIDEN_AT`, and `t` is a block
height while §1 gives `LATE_WIDEN_AT` in minutes — a comparison spanning two units,
which I31 forbids. §4.1 declares exactly three converted window fields and §7.2's
formula names three conversions, so adding a fourth field would depart from both.
Scaling the already-converted block count keeps one conversion per case and adds no
field. Both operands come from the same pinned parameter block (I27).

**Ruling: adopted** (remediation order, "also adopted"). §3.3 will record the
scaling. No code change.

**Threat model.** None. The ratio is exact in the intended configuration
(720/1200 of 240 blocks = 144) and rounds down otherwise, which shortens the
un-widened period rather than extending it.

### D3-5. `share` is recomputed, not stored

**What.** `shareOf(caseId)` derives `share` on each call from `pot`,
`challengeReserve`, `reveals0`, the pooled tally and `verdict`.

**Why.** §8.1 says `share` is *fixed* at the terminal transition; §4.1 declares no
field for it. Every input is immutable after the terminal, so recomputation is
fixed in the sense §8.1 means, and it is `O(1)`.

**Threat model.** None. A stored field and a recomputation from immutable inputs are
observationally identical; the recomputation cannot drift because nothing it reads
can change.

### D3-6. Test-fixture parameter values are fixtures, not proposals

**What.** `Moderation.t.sol` sets `BOND_MIN`, `CHALLENGE_BOND`, `GAS_ALLOWANCE`
(through `LAMBDA` and `REVEAL_BOND`), `MATURATION`, `RETRY_COOLDOWN`,
`SUPER_QUORUM` and the bounty/reserve/maintenance split to concrete numbers.

**Why.** §1 and §10 leave all of them open and the work order forbids picking
values. A case cannot run without numbers, so they live in the test and nowhere
else: the contract holds no default, and `applyParams` accepts any block that
satisfies the one bound below.

**Threat model.** None, provided nothing reads these as recommendations. They are
chosen to make paths reachable in a suite, not to be safe.

### D3-7. `BLOCK_TIME`'s bound is enforced; its value is not

**What.** `applyParams` rejects any block where
`ceil(COMMIT_WINDOW / BLOCK_TIME) > SEED_LAG + BLOCKHASH_HORIZON`.

**Why.** §3.1 and §10 derive `commitBlocks ≤ 258`, so `BLOCK_TIME ≥ 4.651 s` with
18 blocks of margin at 5 s. §3.1 says `RulesetGovernor` must validate it. That
contract is not ported, and an unvalidated block does not fail loudly — it
re-points the tail of every commit window at a seed that has expired — so the check
is enforced here as well. It must be duplicated in `RulesetGovernor` when that is
written, not moved.

**Threat model.** Closes the failure §7.2 measured on the old `blockAt()` schedule,
where fast blocks were fatal and slow blocks benign.

### D3-8. `reopen` requires prior claims to be settled

**What.** `reopen` reverts with `ClaimsOutstanding` unless every vote claim the case
created has been discharged.

**Why.** §8.5 states that prior voters *"are already settled; not re-judged, not
re-paid"* as a fact. It is not one: §5.5 pulls settlement per moderator and it *may
never complete*. Without this check a moderator who committed under the first
opening and never claimed is stranded between two terminals, and no rule in §4 or §8
says which terminal judges them. Requiring what §8.5 assumes turns a silent
ambiguity into a precondition anyone can clear, since `claim(c, m)` is
permissionless.

**Ruling: confirmed** (remediation order §3). The reading is adopted and §8.5 will
be amended to state the precondition rather than assume it. No code change.

**Threat model.** A re-review can be delayed by an unsettled claim. Because
settlement is permissionless and self-funded, whoever wants the re-review can settle
the stragglers first, so this is a liveness cost of one transaction per straggler
rather than a block — and not a griefing vector, since anyone can clear it.

### D3-9. A re-opened case draws from stored entropy and has no expiry

**What.** When `outcomeEntropy` is already set, `draw` finalizes from it
immediately, without consulting `outcomeSeedBlock` or `BLOCKHASH_HORIZON`.

**Why.** §8.5 requires a re-review to return an identical verdict on an unchanged
tally, and §4.5 stores one word precisely so `u` re-derives *"for the life of the
claim"* after `blockhash` has expired. §8.5 does not say what schedule a reopened
case's draw follows. Re-arming a fresh outcome seed would make `NO_RANDOMNESS`
reachable a second time on a claim that already holds its randomness, which
contradicts "one randomness per claim"; reading the stored word cannot expire.

**Ruling: recorded** (remediation order, "also adopted"). The timing gap is
acknowledged and no change is made pending a §3.5b/§8.5 amendment.

**Threat model.** Removes a terminal that should not be reachable. It also means a
reopened case has no `DRAW` waiting window, so finalization is immediate at reveal
close — a timing difference between a first opening and a re-review, which §3.5b's
uniform-latency argument does not cover.

### D3-10. Maintenance accrues in `Moderation`, separately from the registry's

**What.** The fee's maintenance component, the §5.3 division remainder, and bounties
nobody earned accumulate in `Moderation.maintenanceAccrued`. Debits accumulate in
`StakeRegistry.maintenanceReserve`.

**Why.** §5.1 sends every debit to "the maintenance reserve" and the registry holds
it; §1's fee split and §5.3's remainder are held by `Moderation` and the registry
boundary has no call to deposit them. No section says whether the two are one pool.

**Ruling: confirmed as a real gap, and out of scope here** (remediation order §4).
The target is one pool with a timelocked governance exit, which requires changing
`StakeRegistry` — frozen — so it goes in a separate order against both contracts.
No forwarding path is added here.

**Threat model.** Neither pool has an exit. Nothing can be drawn from either, so no
value is at risk today; what is at risk is that a later sweep is written against one
pool and misses the other.

### D3-11. `DRAW_BOUNTY` is refunded where the draw is unreachable — **REVERSED**

**Ruling: reversed** (M2.7 remediation order §1, spec corrected at `6489bfd`). The
objection this entry raised was upheld and the implementation it described was
wrong. This entry records both.

**What it was.** On `NO_TURNOUT` and `NO_REVEALS` the unpaid `DRAW_BOUNTY` was
folded into `maintenanceAccrued` along with the claim bounty.

**What it is now.** `_settleBounties` refunds whatever `DRAW_BOUNTY` remains and
retains `CLAIM_BOUNTY`. §4.8 now states the rule that decides it:

> A bounty is refunded where the transition it pays for cannot occur, and paid
> where that transition was performed.

`_payBounty` zeroes the draw bounty at the moment it is paid, so *refund whatever
remains* is that rule with no per-reason branch: `NO_TURNOUT` and `NO_REVEALS` never
reach `DRAW` so the whole bounty returns, and `NO_RANDOMNESS` already paid it to
whoever poked the expiry so nothing remains.

**Why the original reading was wrong.** Retaining it charged the submitter for a
transition that cannot happen, on a row §4.8 itself calls unsteerable and refunds in
full — the same shape §4.8 rejects for the non-reveal debit, where the requirement
is *a reveal phase that opened* rather than *a terminal state*.

**`CLAIM_BOUNTY` is deliberately unchanged.** The same argument applies to it, since
every terminal transition is permissionless and somebody paid gas to poke it. §10
now carries that as an open question: it is a fee-schedule change rather than a
contradiction, and the two must not ride together. `M47` mutates the code into
refunding it, and the suite kills that — the retention is pinned, not incidental.

**Threat model.** Strictly returns value to the party §4.8 says is not levied.
Conservation is unchanged: the bounty moves between two of this contract's own
sinks, never out of it except through `withdrawRefund` to the recorded submitter.

**Tests.** `test_valueConservation_noTurnoutRefundsPotReserveAndDrawBounty`,
`..._noRevealsCarriesThePotAndRefundsTheDrawBounty`,
`..._noRandomnessPaysTheDrawBountyToThePoker`, and the finalized-case assertion that
both bounties reach the poker.

### D3-12. `NO_REVEALS` carries the pot — **CONFIRMED**, and §4.8 was corrected

**Ruling: confirmed** (remediation order §2). The implementation was right and the
spec was wrong; `6489bfd` corrects §4.8's value-flow block. No code change.

**What.** On `NO_REVEALS` the pot moves to `carriedPot[claimKey]` and only the
challenge reserve — and now the draw bounty, per D3-11 — is refunded.

**Why.** §8.4's table retries `NO_REVEALS` *"after the cooldown, pot carried
forward, no fresh fee"*; §4.8's block said *"every reason → refund pot +
challengeReserve IN FULL"*. A refunded pot cannot be carried, so the two could not
both be followed. §8.4 is the specific rule and it wins.

**Why it was a contradiction and not a wording choice.** The two are not
economically equivalent: §4.8 also retains the finalization bounty and maintenance,
so refund-and-resubmit costs the submitter both on every cycle while carrying costs
nothing. Under §4.8c — where one identity now suffices to force `NO_REVEALS` — a
censor would levy his victim on each attempt, the exact outcome §8.4's row exists to
prevent when it says *"the submitter did not cause it, so not levied either."*

**Threat model.** As implemented, the censorship path costs the censor a
`REVEAL_BOND` per attempt and costs the submitter only time. Under the withdrawn
reading it would also have cost the submitter two fee components per cycle.

### D3-13. `Moderation` holds the governor role directly

**What.** `applyParams` is `onlyGovernor`, with a plain `setGovernor`.

**Why.** `RulesetGovernor` is not ported. §4.1 requires versioned parameter blocks
pinned per case (I27) and something must publish them. The propose/execute timelock
pattern lives in the governor, not here, so this is a seat for it rather than a
replacement.

**Threat model.** Until `RulesetGovernor` v3 exists, parameter changes have no
timelock at this contract. Pinning still holds — a change cannot affect a live case
(I27) — so the exposure is limited to cases submitted after the change. It must be
replaced by the governor before any deployment, and the standing constraint already
forbids one.


### D3-14. The maintenance exit — what §5.6.1 left open

**Ruling context.** M2.8 implements §5.6.1 as specified. Three details it does not
state, resolved here and reported rather than assumed.

**The withdrawal names its recipient at propose, not at execute.** §5.6.1 writes
`proposeMaintenanceWithdrawal(to, amount)` and `executeMaintenanceWithdrawal()` with
no arguments, so `to` is pinned by the proposal and the timelock covers the
recipient as well as the amount. That is the safer reading — a recipient swappable
at execute would put the destination outside the delay — but §5.6.1 does not say so.

**`executeMaintenanceWithdrawal` takes no argument, so it cannot re-name its
proposal.** Condemnation names its logic again at execute specifically so a pending
proposal cannot be swapped underneath the timelock (`M23`). The withdrawal has only
one pending slot and a fresh propose overwrites it, exactly as `proposeCaps` does,
so the same hazard exists in the same form for all three. It is not new here and is
not fixed here; it is the existing idiom the order said to follow.

**A deposit of zero reverts.** §5.6.1 does not say. `AmountZero` matches every other
zero-amount path in the registry (`postBond`, `reward`), and a permissionless no-op
that emits an event is worth refusing.

**What is deliberately absent.** No forwarding path from `Moderation` at each
terminal (§5.6.1 says lazy), no capability bit for the deposit (§5.6.1 says none),
and no change to `CLAIM_BOUNTY`'s retention — this order moves the pool, it does not
re-decide what enters it. `M47` still pins the retention.

**Threat model.** The exit is the highest-risk surface either contract has: a
governance-controlled withdrawal from a contract holding user funds. It is bounded
by one comparison, `amount <= maintenanceReserve`, checked against live state at
execute. Everything else about the mechanism is the timelock idiom the registry
already had.
