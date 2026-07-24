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

### Test-code rule this forces

`via_ir` means solc hoists `TIMESTAMP` and `NUMBER` — correctly, since both are
invariant within a transaction. `vm.warp` and `vm.roll` are cheatcodes it cannot
see, so **test code must never read `block.timestamp` / `block.number` directly**;
use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`, which are external
staticcalls and cannot be folded. Reading them directly does not fail loudly — it
silently returns a stale value and mis-sequences the test. Switching the pipeline
cost ~20 tests exactly this way. The rule is stated at the top of
`test/base/StackDeployer.sol`, which every suite inherits.

> **Open follow-up (not done in this pass): size-reduction pass on `Moderation`.**
> 1,184 B of headroom is thin — roughly one moderate feature. And a logic contract
> that was 5,193 B over EIP-170 before this port, and fits now only by virtue of an
> optimizer pipeline, is telling us it still wants splitting: `Moderation` is
> still the case lifecycle, appeals, settlement AND governance in one contract.
> Recorded in `specs/m2_5-port-work-order.md`.

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
