# Gas budgets (M2 / M2.5)

Budgets the Foundry suite asserts against (D9 of `specs/m2-work-order.md`).
"Actual" columns are re-measured after the M2.5 port, which moved stake custody
and the index into separate contracts — every settlement path now pays for
cross-contract calls, and rewards additionally pay for a token transfer.

## Block gas limit headroom

**Gnosis Chain block gas limit: ~17,000,000** (working value).

> Verification note: public Gnosis RPC endpoints (`rpc.gnosischain.com`,
> `rpc.gnosis.gateway.fm`, `gnosis.drpc.org`) are unreachable through this
> environment's egress proxy, so this figure could not be confirmed live. It is
> the documented Gnosis block gas limit and has historically only risen; the
> exact live limit must be re-confirmed at M4 deployment. Every budget below is
> sized so the design holds under any limit ≥ 12M.

## Contract size — EIP-170

The suite and the deployment now use the **same pipeline**: `via_ir = true` is the
default profile. On a contract custodying stake, testing bytecode that can never
be deployed is not a tradeoff worth taking — and the legacy pipeline is
undeployable here regardless.

| Contract | Legacy pipeline | `via_ir` (default: shipped **and** tested) | EIP-170 limit |
|---|---|---|---|
| `Moderation` (pre-M2.5-port) | 29,769 B — **5,193 over** | — | 24,576 B |
| `Moderation` (post-port) | 25,986 B — **1,410 over** | **23,392 B — 1,184 under** ✓ | 24,576 B |
| `StakeRegistry` | 9,337 B ✓ | 8,717 B ✓ | 24,576 B |
| `IndexRegistry` | 4,593 B ✓ | 3,690 B ✓ | 24,576 B |

The port shrank `Moderation` by **3,783 B (−12.7%)** on the legacy pipeline; the
IR pipeline takes it the rest of the way under the limit.

### M2.6 headroom, measured per item (`forge build --sizes`, default profile)

The remediation items all add code to `Moderation`, so the margin is tracked as it
is spent. This is the binding constraint of the milestone, not a footnote.

| After | `Moderation` | margin | `StakeRegistry` | `IndexRegistry` |
|---|---|---|---|---|
| M2.5 merge (`b09ce31`) | 23,795 B | 781 B | 8,977 B | 4,287 B |
| P0-4 + P0-1a | 23,795 B | 781 B | 8,977 B | 4,287 B |
| **P0-1b** (registry-owned dedup) | **24,082 B** | **494 B** | 8,977 B | 4,893 B |
| **size pass** (drop 2 broken views) | **23,438 B** | **1,138 B** | 8,977 B | 4,893 B |
| **P0-1c** (legacy removal path) | **24,259 B** | **317 B** | 8,977 B | 5,288 B |
| **P0-2** (duty escrow) | **24,343 B** | **233 B** | 9,951 B | 5,288 B |
| **structural split** (governor out) | **22,298 B** | **2,278 B** | 9,951 B | 5,288 B |
| **P0-3** (eligibility epochs) | **21,908 B** | **2,668 B** | 11,142 B | 5,288 B |
| **P0-5a** (obligation handles) | **22,006 B** | **2,570 B** | 12,326 B | 5,288 B |
| **P0-5b** (retirement lifecycle) | **22,435 B** | **2,141 B** | 12,876 B | 5,511 B |
| **P1-2** (batched seat draw) | **22,569 B** | **2,007 B** | 12,876 B | 5,511 B |

(The split also adds `RulesetGovernor`: 3,993 B, 20,583 B of margin.)

P0-1b cost `Moderation` **+287 B**: moving dedup into the registry replaces two
storage operations with two cross-contract calls, and calldata encoding is bigger
than `SLOAD`/`SSTORE`. Three shapes were measured before settling:

| shape | `Moderation` | note |
|---|---|---|
| pre-check `isContentReserved` + reverting `reserveContent` | 24,270 B | two calls per topic |
| single `tryReserveContent`, `DuplicateSubmission` kept | 24,163 B | one call, bool return |
| + `reservationCaseId` single-word view for `dedupOwner` | **24,082 B** | shipped |

The last step is the general rule for the rest of the milestone: **when a boundary
crossing costs `Moderation` bytes, put the wide return type on the registry side.**
`IndexRegistry` has 19,288 B of margin, `StakeRegistry` 14,625 B; `Moderation` has
a few hundred. P0-2 is the clearest case so far: the duty-escrow bucket cost
`StakeRegistry` +974 B and `Moderation` only +84 B, because the state and its
transitions belong on the custody side and the logic contract only names them.

### The size pass (M2.6), and what is left to cut

P0-1c overran EIP-170 by 309 B, so the reduction pass the M2.5 port deferred was
done then rather than at the end. Two forwarding views were removed — both
already listed as defects in the work order's P2 section, so this deleted broken
API rather than useful API:

| removed | saved | why it was wrong, not just costly |
|---|---|---|
| `supersafeEntries(bytes32)` | ~440 B | called the registry with the whole topic length; the preserved M2 signature was not operationally safe at scale |
| `dedupOwner(bytes32)` | ~205 B | a bare caseId cannot distinguish "unreserved" from "owned by case 0", and since P0-1b cannot name the owning logic either |

Both reads are still available, better, from `IndexRegistry`:
`supersafeEntries(topic, minAge, cursor, limit)` and `contentReservation(key)`.
Reads there are permissionless and survive a logic upgrade, which is where a
front end should have been pointed anyway.

The structural split that follows is what actually bought the milestone its
headroom back; this pass only got P0-1c through the door.

> **`forge build --sizes` exits non-zero on `ModerationHarness`** (26,783 B). That
> is the test-only subclass with the storage injectors, it is never deployed, and
> `forge test` does not enforce EIP-170. Pre-existing, not a regression — but a CI
> size gate (work order P2) must assert on the *deployed* contracts specifically
> rather than on the command's exit code, or it will fail on the harness forever.

### The one-shot claim now requires batching (M2.6-P0-5)

`test_worst_case_claim_under_hard_ceiling` measured 4,699,258 at the start of the
milestone and **8,019,298** after P0-2, P0-3 and P0-5 — past the 8M budget. The
budget was NOT raised. The test now asserts the **batched** path
(`claim(caseId, maxSteps)`), which is the settlement guarantee H-04 exists to
provide and which fits comfortably; the one-shot convenience is recorded as
requiring batching for this configuration, exactly as the 344-seat case already
did.

Same root cause as MAX_PANEL's lost margin: three items each added a per-seat or
per-obligation storage write. Both point at the same fix (P1-2).

### P1-2: the seat draw is batched, and the binding constraint moved

`realizeSeats` attempted a whole commit target in one transaction, so `MAX_PANEL`
was nothing more than the block limit divided by the per-seat cost — and that cost
rose three times in M2.6 (P0-2 escrow, P0-3 staged weight, P0-5 obligation handle),
taking a cap-sized panel from 74% to 90% of the ceiling. Two separate findings had
already named batching as the precondition; it was done before P0-6/7/8 so those
would not be shaped around a constraint it removes.

Same template as batched settlement: bounded steps behind a cursor. `seatDrawCount`
IS the cursor — it counts every attempt the registry has made for the round, so
successive batches consume disjoint segments of one deterministic sequence.

| | before | after |
|---|---|---|
| unit that must fit a transaction | whole panel, 7,239,700 (90%) | one batch of 24, **3,690,617 (46%)** |

The 80% margin assertion is restored, against the batch.

**What binds `MAX_PANEL` now is `_void`, so it has NOT been raised.** `_void` still
loops the whole `seatHolders` array with no cursor, and runs INSIDE `closeReveal`
— exceeding the limit reverts the transition and strands the case in an expired
REVEAL. Per-holder disposal is ~140,000 gas, flat:

| holders | gas |
|---|---|
| 24 | 3,515,321 |
| 48 | 6,761,469 |
| 96 | 13,253,772 |

Break-even ~57 holders; 48 sits at 85%. Raising the cap now would recreate the
unfinalizable-case class on the VOID path instead of the draw path. **Raising it is
gated on P0-7**, after which no unbatched loop scaling with panel size remains.

### Test-code rule this forces

`via_ir` means solc hoists `TIMESTAMP` and `NUMBER` — correctly, since both are
invariant within a transaction. `vm.warp` and `vm.roll` are cheatcodes it cannot
see, so **test code must never read `block.timestamp` / `block.number` directly**;
use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`, which are external
staticcalls and cannot be folded. Reading them directly does not fail loudly — it
silently returns a stale value and mis-sequences the test. Switching the pipeline
cost ~20 tests exactly this way. The rule is stated at the top of
`test/base/StackDeployer.sol`, which every suite inherits.

> **DONE (M2.6): structural split of `Moderation`.** Ruleset authoring moved to
> `RulesetGovernor`; see "The split" below. `Moderation` 24,343 -> 22,298 B.
>
> The historical note this replaced said 1,184 B of headroom was thin — roughly
> one moderate feature — and that a logic contract which was 5,193 B over EIP-170
> before the M2.5 port, and fit only by virtue of an optimizer pipeline, was
> telling us it still wanted splitting. That was right, and it took three items to
> come due. Recorded in `specs/m2_5-port-work-order.md`.

### The split (M2.6): authoring vs enforcement

The seam is not "governance code" as a bucket — it is a real boundary:

- **Authoring** is cold. A multisig proposes a ruleset, waits out a timelock,
  executes; it runs a handful of times in the protocol's life. All the validation
  lives here, and `_validateParams` was the largest cold blob in the system.
- **Enforcement** is hot. Every case reads its pinned ruleset on every phase
  transition, through `Moderation._cp()`.

**Ruleset STORAGE deliberately did not move.** Putting `rulesets` behind a call
would turn `_cp()` — on every hot path — into a cross-contract call returning a
nineteen-field struct, costing more at the call sites than the split saved, plus
a great deal of gas. The governor validates, then pushes the authored result into
`Moderation`'s storage via `applyRuleset`.

| | before | after |
|---|---|---|
| `Moderation` | 24,343 B (233 margin) | **22,298 B (2,278 margin)** |
| `RulesetGovernor` | — | 3,993 B (20,583 margin) |

Two things the split had to get right:

1. **The caps could not be duplicated.** `MAX_RULE_DEPTH` and friends were
   `internal constant` on `Moderation`, invisible to the governor. Copying them
   would have created exactly the failure this milestone keeps finding — a safety
   bound stated twice and silently diverging. They live in
   `lib/ProtocolLimits.sol`; `internal constant` in a library is inlined, so it
   costs nothing on either side.
2. **Validation moving out weakens the boundary, so one check stayed.** Full
   validation is the governor's, but `applyRuleset` re-checks
   `riskPerSeat <= stakeReg.riskPerSeat()` on arrival. That is the only validation
   failure which is a *solvency* problem rather than a liveness one: everything
   else can brick a case, but this one seats panels on collateral that cannot
   cover them. A governor bug cannot reintroduce it.

`Moderation.governor` is immutable, so the split adds no trust surface: the
governor holds exactly what the `governance` address held before. The multisig
still rotates, via `RulesetGovernor.transferGovernance`.

### P0-3 as shipped: frozen-window epochs

Draw-eligible weight changes only at epoch boundaries (`epochBlocks = 256`), and a
seed is armed so its whole window fits inside one epoch. Within an epoch the
eligible set is constant, so there is nothing to grind and nothing to re-arm on.

Two costs, both measured:

- **The 47-seat draw goes 5.41M -> 5.95M** (+540k). Each seated moderator's
  deferred weight update is one array push. The dedupe flag `_stage` uses would
  have made it 7.01M; the draw path uses `_stageSeated`, which omits it because
  the drain recomputes from live state and a duplicate entry is idempotent. A
  griefer cannot exploit the missing flag — repeating a seat is not free.
- **`Moderation` SHRANK by 390 B** (22,298 -> 21,908). The re-arm branch and
  `eligVersionAtArm` were deleted outright, and epoch-fitted arming is smaller
  than the counter comparison it replaced. `StakeRegistry` grew 1,191 B, which is
  the right side for it.

### MAX_PANEL, set from the measured curve (M2.6)

`MAX_PANEL` was 512. `_validateParams` would therefore accept a ruleset whose
`realizeSeats` cannot fit in a block — and H-11 pins a ruleset per case at submit,
so every case opened under it is permanently unfinalizable with no path forward.
No attacker required: a plausible parameter choice does it. Filed initially as a
P1 note; it is a P0.

Per-seat draw cost is flat across panel size (1,000-moderator tree,
`test/spike/PanelCurve.t.sol`):

| seats | gas | per seat |
|---|---|---|
| 47 | 5,784,708 | 123,078 |
| 56 | 6,992,608 | 124,868 |
| 64 | 7,825,247 | 122,269 |
| 80 | 9,618,974 | 120,237 |
| 96 | 11,712,334 | 122,003 |
| 128 | 15,767,829 | 123,186 |

Cost is dominated by per-seat storage writes (P0-2's escrow, P0-3's staged weight
update), not tree descent, so it barely moves as the moderator set grows. Against
the 8M ceiling the break-even is ~65 seats, and 64 already sits at 98% of it.

**MAX_PANEL = 48**: 7,239,700 gas measured at the cap after P0-5 (6,073,895 before
it — the per-case obligation slot added ~24k/seat). Originally — 76% of the 8M ceiling and
~35% of the Gnosis block limit. At the old 512 the same draw costs **55,231,377
gas** — 3× the Gnosis block limit.

**P0-5 spent the margin.** The per-seat draw cost has now risen three times in this
milestone — P0-2's escrow, P0-3's staged weight update, P0-5's obligation slot —
taking a cap-sized panel from 74% to 90% of the ceiling. The cap was NOT lowered to
restore the margin, because the shipped ruleset's deepest target is 47 and dropping
below it would change the appeal ladder's statistics: a product decision, not a
side effect a storage-layout change should make. The constraint moved instead:

> **No further per-seat storage write may land before cursor-based seat drawing
> (P1-2).** One more slot per seat (~+24k) puts a 48-seat panel at ~8.4M, over the
> ceiling — and H-11 pins the ruleset per case, so every case opened under an
> accepted-but-unexecutable ruleset is stranded. P1-2 was the precondition for
> RAISING the cap; it is now the precondition for keeping it.

`GasBounds.test_max_panel_draw_fits_the_ceiling` reads the constant directly, so
raising it without re-measuring fails the suite.

> **Raising MAX_PANEL requires cursor-based seat drawing (P1-2) to land first.**
> `realizeSeats` attempts a whole commit target in one transaction, so until that
> is batched the cap simply IS the ceiling divided by the per-seat cost. No larger
> value can be made safe by validation alone. This converts P1-2 from an
> optimisation into the named precondition for ever raising the cap.

> **The 47-seat draw is now ~5.95M against an 8M hard ceiling.** P0-2 and P0-3
> each added per-seat storage writes, and `realizeSeats` still attempts a whole
> commit target in one transaction. `MAX_PANEL` is configured at 512 and the
> largest thing ever measured is 47. Cursor-based seat drawing (work order P1-2)
> is no longer an optimisation — it is what has to land before any panel target
> materially above ~60 can be accepted by the validator.

### P0-3 spike: what a checkpointed sortition tree actually costs

The work order prescribes "each case pins an epoch root at arm time; all draws
for that seed use that immutable root", which requires a checkpointed sum tree.
Measured rather than estimated (`test/spike/`, throwaway — delete once P0-3
lands), 47 seats over 1,000 moderators, k=4:

| history depth | checkpointed descent | live descent | ratio |
|---|---|---|---|
| 50 epochs | 1,095,830 | 473,402 | 2.31× |
| 1,000 epochs | 1,122,031 | 488,225 | 2.29× |

Two results, and the second is the one that matters:

1. **The cost is flat in history depth.** 50 epochs and 1,000 epochs differ by
   2%. The binary search is not what you pay for — the extra SLOADs for array
   length and slot are. So checkpointing does not degrade as the protocol ages.
2. **It fits the ceiling.** Tree descent is only ~488k of the 5.41M `realizeSeats`
   measurement — most of that figure is P0-2's escrow writes and duty accounting,
   not the draw. Checkpointing adds ~634k, landing around 6.0–6.5M, under the 8M
   hard ceiling. An earlier estimate of "2-3× on 5.41M, therefore over the
   ceiling" was wrong: it scaled the whole measurement by the ratio of one
   component.

**What actually rules it out is P0-2, not gas.** `drawPanel` shrinks a
moderator's weight as its capacity is consumed, and drops exhausted moderators
out of the tree for the rest of the draw (`stakeTree.set(seat, 0)`). Both are
mid-draw mutations that a pinned historical root cannot see, so a checkpointed
draw would re-draw a moderator past its escrowed capacity. Recovering that means
excluding in memory during descent — i.e. rejection sampling — which changes the
draw distribution and reintroduces the unbounded-attempts problem H-07 was
designed around.

The frozen-window alternative keeps the live tree as the root and leaves
`drawPanel` exactly as it is.

### What is left to cut, if a later item needs it

1. `submissionExists` / `entryCount` / `entryAt` forwarders — the registry serves
   all three.
2. Settlement coordination (`_settle*`, the batch cursor) into its own contract.
   Harder than governance was: it touches case storage on the hot path, so it
   would need the same "state stays, logic moves" care, or a bigger rethink.

## Budgets and measured actuals (re-measured under `via_ir`)

| Path | Budget | Kind | Pre-port (legacy) | Post-port (`via_ir`, shipped) | Test |
|---|---|---|---|---|---|
| `claim(caseId, maxSteps)` — one settlement batch (H-04) | **8,000,000** | **hard ceiling** | ~3,377,000 | **3,682,048** ✓ (9 batches of 40) | `test_maximal_case_settles_in_bounded_batches` |
| one-shot `claim()` — MAX_DEPTH, all reveal, 5 topics, 3 winning appeals (86 seats) | 8,000,000 | soft | ~3,579,000 | **4,699,258** ✓ | `test_worst_case_claim_under_hard_ceiling` |
| one-shot `claim()` — REACHABLE worst case (344 seats, mostly failed reveals) | — | measured | ~30,290,000 | ~29,558,000 (**must batch**) | `test_maximal_case_oneshot_gas_measurement` |
| `claim()` with 2 vs 2000 appeal contributors | — | **flat (C-01)** | 357,354 / 357,354 | **390,930 / 390,936** ✓ (6 gas apart) | `test_claim_gas_independent_of_appeal_contributors` |
| index entry deletion, topic of 8 vs 2000 | — | **flat (H-03)** | — | **68,474 / 68,474** ✓ | `test_index_deletion_gas_independent_of_topic_size` |
| seat-draw poke — 47-seat panel over 1000 moderators | 5,000,000 | soft | ~4,352,000 | **4,391,862** | `test_measure_draw_poke_1000_mods` |
| `submit` (5 topics) | 650,000 | soft | ~517,000 | 588,210 | `test_measure_common_path_gas` |
| `commitVote` | 200,000 | soft | ~173,000 | 184,643 | `test_measure_common_path_gas` |
| `revealVote` | 150,000 | soft | ~113,000 | 116,303 | `test_measure_common_path_gas` |
| `contributeAppealBond` | 160,000 | soft | ~126,000 | 78,781 | `test_measure_common_path_gas` |

### What the port cost

Settlement got materially heavier, as expected: every seat disposition is now
one or two external calls into `StakeRegistry` (`release`/`freeze`, plus a token
`transfer` + `reward` for a coherent voter) instead of a local storage write.

- Batched settlement: **+9.0%** per batch (3.38M → 3.68M). Still 46% of the 8M
  ceiling, and the batch count is unchanged at 9.
- One-shot 86-seat claim: **+31.3%** (3.58M → 4.70M). The reward channel is the
  bulk of it — a coherent voter costs a cross-contract transfer plus a credit.
- Claim gas stays flat in appeal-contributor count to within **6 gas** across a
  1000x change in contributor count (exactly equal pre-port; the IR pipeline
  leaves a negligible difference in the pot arithmetic). C-01 holds.
- Common paths: within noise except `submit` (+13%, the index write path now
  crosses a contract boundary) and `contributeAppealBond` (−37%, pot money never
  touches the registry and the function lost the staking-path warm slots).

**Hard ceiling result — PASS.** The load-bearing property (Invariant 8: no
stranded pots) holds: worst-case settlement fits in bounded batches at 3.68M gas,
well under both the 8M single-transaction ceiling and the ~17M block limit.

### Correction: the seat-draw row was never actually measured

The previous revision of this file recorded ~2,778,000 for the 47-seat draw
against a 3,500,000 soft budget. That number was real when written, but the H-07
duty pool landed afterwards and made the fixture vacuous: the 1000 moderators in
`test_measure_draw_poke_1000_mods` staked and activated but never *pledged duty*,
so their draw-eligible weight was zero, the tree was empty, and the draw returned
immediately. The assertion had been passing on **~5,000 gas** ever since.

The fixture now pledges capacity. A genuine 47-seat draw over 1000 pledged
moderators costs **~4.39M** (~4.35M before the port, so the cross-contract call
is only ~1% of it) — it never met the 3.5M budget, which is corrected to 5M here.
It clears the 8M single-transaction ceiling with room to spare, and only the
rarest depth-3 round pays it; depth-0 (5 seats) is far cheaper.

> Measurement note (unchanged). Measuring settlement against freshly-*inserted*
> voters (never in the tree) overstates it badly: in a real case the panel is
> *drawn from* the sortition tree, so settlement performs cheap warm **updates**,
> not cold leaf inserts. The figures above pre-stake and activate the voters so
> the measurement reflects real update cost. The gap is a caution for any future
> path that would settle voters not already in the tree.

Soft budgets are adjusted to measured reality per work order D9 and are
documented, not load-bearing. Full per-test gas is in `contracts/.gas-snapshot`.
