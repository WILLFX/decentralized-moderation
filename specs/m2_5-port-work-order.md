# M2.5 Port Work Order — wire `Moderation.sol` onto the registries

**Scope:** the ONLY remaining M2.5 item. Everything else (all 17 audit findings) is
fixed, tested and pushed on `claude/determined-curie-nkf71s` — see the resolution
table in `m2_5-remediation-work-order.md`.

**Why this is its own session.** This edit moves *where the money lives*: token
custody for stake shifts from `Moderation` to `StakeRegistry`, and rewards become a
transfer + credit across a contract boundary. A subtle error here is a fund-loss bug
in the very code we are remediating. It is a mechanical call-site rewrite — but it
needs full attention and an unhurried verification pass, not a tail-end push.

**Start state.** `forge test` = **132 green**, 15 suites. Do not begin until you
have reproduced that number.

---

## What already exists (do not redesign)

`StakeRegistry` is a **complete drop-in** for the monolith's staking section. It
already owns everything the port needs:

| Need | Registry API |
|---|---|
| deposit / activate / exit / withdraw / thaw | `stake`, `activate`, `requestExit`, `withdraw`, `thaw` (moderator-facing, never gated by logic) |
| duty pool (H-07) | `setDutyUnits`, `dutyOf`, capacity-capped `_eligibleWeight` |
| panel draw + reservation | `drawPanel(count, seed, offset) → (address[] seats, uint256 attempts)` — reserves one unit per seat, excludes exhausted capacity, restores weights, attempts bounded at 2×count |
| release capacity at case end | `releaseDuty(moderator, units)` |
| no-show penalty (H-07/H-10) | `penalizeNoShow(moderator, amount, until)` |
| commit lock / settle | `lock`, `release`, `freeze` |
| reward credit | `reward(moderator, amount)` — **caller must transfer the tokens first** |
| track (M-03) | `setTrack`, `trackOf` |
| H-05 gate | `eligibilityAddVersion` |
| views | `moderatorInfo`, `totalStakeOf`, `eligibleWeightOf`, `totalEligibleWeight`, `stakeBuckets` |

`IndexRegistry` likewise owns: `writeEntry`, `deleteEntry`, `isIndexed`,
`entryCount`, `entryAt`, `entries` (paginated), `supersafeEntries(topic, minAge,
cursor, limit)`.

Both carry the trust model already proven by 19 tests in `test/Registries.t.sol`:
timelocked repoint, exit independent of logic, handover window, governance cannot
touch funds.

---

## The port

### Step 1 — constructor wiring

`Moderation` takes `StakeRegistry` and `IndexRegistry` addresses (immutable). Deploy
order in tests/scripts: registries first, then `Moderation`, then
`proposeLogic(moderation)` + `executeLogic()` on **both** registries after the
timelock.

### Step 2 — delete the monolith's staking state and forward

Remove from `Moderation`: `Moderator` struct, `moderators` mapping, `stakeTree`,
`totalFreeStake/totalCommittedStake/totalFrozenStake`, `eligibilityAddVersion`, and
the staking entry points (`stake`/`activate`/`requestExit`/`withdraw`/`thaw`/
`setDutyUnits`) — moderators call the registry directly for those. Rewrite the
internal helpers as registry calls:

| Monolith internal | Becomes |
|---|---|
| `_lockStake(a, amt)` | `stakeReg.lock(a, amt)` |
| `_freezeSlice(a, amt, until)` | `stakeReg.freeze(a, amt, until)` |
| `_penalizeNoShow(c, a, seats)` | `stakeReg.penalizeNoShow(a, _cp(c).riskPerSeat, block.timestamp + _cp(c).failedRevealFreeze)` |
| `_releaseDuty(a, seats)` | `stakeReg.releaseDuty(a, seats)` |
| `_drawSeats(r, count, seed, offset)` | `stakeReg.drawPanel(...)` then record `r.seats/seatHolders` from the returned array |
| `_syncTree` / `_eligibleWeight` / `_eligibleFreeOf` | delete (registry-internal) |
| `moderators[a].track` reads/writes | `stakeReg.trackOf(a)` / `stakeReg.setTrack(a, v)` |
| `eligibilityAddVersion` | `stakeReg.eligibilityAddVersion()` |

**Note `_drawSeats` may now seat fewer than requested** (capacity-limited). Set
`r.nSeats` to what was actually seated, and let the existing widen path handle
under-participation. Keep `r.seatDrawCount += attempts` so widen offsets stay
disjoint.

### Step 3 — index calls

`_writeEntries` → `indexReg.writeEntry(topicKey, c.id, contentHash, metaHash,
uncontested, fullQuorum)` per topic. `_deleteEntry` → `indexReg.deleteEntry`.
`entryCount`/`entryAt`/`supersafeEntries` on `Moderation` become thin forwarders (or
are dropped and clients read the registry directly — prefer forwarders so the M2 ABI
keeps working). `Case.isIndexed` (H-01) can stay on the case, or be derived from
`indexReg.isIndexed(topic, caseId)`; **keep the case flag** — it is the removal
generation signal and must not depend on topic iteration.

### Step 4 — money flow (the dangerous part)

- **Fees and appeal bonds** stay in `Moderation` (they are pot money, not stake).
- **Committed stake** already lives in `StakeRegistry` — `lock`/`release`/`freeze`
  are pure bookkeeping there, no transfer.
- **Rewards** are the crossing point. In `_disposeSeat`, replace the
  `m.free += reward` credit with:
  ```solidity
  address(token).safeTransfer(address(stakeReg), reward);
  stakeReg.reward(a, reward);
  ```
  in that order. Never call `reward()` without having moved the tokens.
- **Claim bounty, appeal refunds/bonuses, VOID refunds** keep transferring straight
  from `Moderation` to the recipient — unchanged.

### Step 5 — conservation invariant now spans two contracts

`_assertConservation` becomes:

```
bzz.balanceOf(moderation)  == openPotsTotal + totalPendingBond + totalPendingPayout + totalSettling
bzz.balanceOf(stakeRegistry) == stakeReg.stakeBuckets()
```

Both must hold. Update `test/base/ModerationTestBase.sol`, `Differential.t.sol`, and
the invariant handler/checker.

---

## Sequencing (one commit each, suite green at every step)

1. `port-1`: constructor wiring + registry deploy in test base; registries authorized. No behaviour change yet.
2. `port-2`: staking helpers → registry calls (`lock`/`freeze`/`release`/`track`).
3. `port-3`: draw path → `drawPanel`, incl. duty release/penalty at settle + void.
4. `port-4`: index path → `IndexRegistry`.
5. `port-5`: reward money flow + two-contract conservation in all suites.
6. `port-6`: delete the dead staking/index state from `Moderation`; `forge build --sizes`.

## Verification before calling it done — non-negotiable

- [ ] `forge test` green, and **no test count regression** (132 baseline).
- [ ] Two-contract conservation asserted in: unit suites, `Differential.t.sol`
      (52 vectors bit-exact), and the invariant campaign.
- [ ] Invariant campaign re-run with the handler driving registry staking.
- [ ] `test_maximal_case_settles_in_bounded_batches` still passes (batches under 8M)
      **with the cross-contract calls added** — reward transfers make it heavier;
      re-measure and update `GAS_BUDGETS.md`.
- [ ] `test_claim_gas_independent_of_appeal_contributors` still shows flat gas.
- [ ] A live end-to-end migration test: run a case to settlement under logic A,
      repoint both registries to logic B, verify stake + index intact and a new case
      settles under B.
- [ ] `forge build --sizes` — `Moderation` should shrink materially; record it.

## Traps (each one already bit us this milestone)

1. **`vm.prank` is consumed by an external call in the argument list.** Compute
   `mod.computeCommit(...)`, `getParams()`, `minFee()` into a local BEFORE pranking.
2. **Stack-too-deep** in `_settleInit` — cache `Params storage p = _cp(c)` once
   rather than repeating `_cp(c).x`; adding registry locals will re-trip it.
3. **`indexed` is a reserved word** — the case flag is `isIndexed`.
4. **Widen returns the round to `DRAW`** (H-05 fresh entropy). Any drive loop must
   handle `DRAW` mid-round, and guards need ~24 iterations.
5. **Order matters on rewards**: transfer, then credit. Reversing it breaks
   conservation between the two asserts.
