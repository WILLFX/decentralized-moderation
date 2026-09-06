# M2.8 Work Order — the maintenance exit

**Base:** `main` @ `d013048`.
**Branch:** **`claude/determined-curie-nkf71s`** — same branch, continue on it.
**Normative:** `specs/state-machine-v3.md` §5.6 and §5.6.1 @ `d013048`.

**This order unfreezes `StakeRegistry.sol`.** It is the first change to that
contract since `b4dcaf8`, and the freeze existed to protect its 25/25 mutation run
and its standing as the one externally-auditable artifact. §5 below is how that
standing is re-established rather than spent.

---

## 1. What this fixes, and why it is the only P0 on §10's list

Value accrues in **two** maintenance pools and **neither has a withdrawal.**

```
registry pool    <- every debit (§5.1, §5.2, §4.6): d, REVEAL_BOND,
                    CHALLENGE_BOND. Grows through `debit` alone
Moderation pool  <- the fee's maintenance component (§1), §5.3's remainder,
                    and CLAIM_BOUNTY retained on UNRESOLVED (§4.8)
```

You found this and were right not to invent a fix inside a `Moderation` order. The
spec had already assumed one pool in twelve places without saying where it was —
which is why neither suite could catch it: **"there is no exit" is not a failing
assertion.**

§5.6 decides the target; §5.6.1 states the mechanism. Implement that, not a
variant.

## 2. `StakeRegistry` — two additions

### 2.1 `depositMaintenance(uint256 amount)` — permissionless

Pull `amount` with `transferFrom`, **then** `maintenanceReserve += amount`.

**No capability bit.** `MAY_CREATE` and `MAY_DISCHARGE` gate obligations on a
moderator's bond; a deposit creates none. Do not add a third bit.

**The pull is not optional and is not a style choice.** `balanceBuckets()` is
`totalStake + totalBond + maintenanceReserve` and `solvent()` compares it to the
real balance (I21). Incrementing the counter without moving value makes the
registry insolvent by exactly `amount`, through a permissionless function. The
permissionlessness and the pull are one decision.

### 2.2 The timelocked exit

Follow the shape `proposeCaps` / `cancelCaps` / `executeCaps` already uses —
`PendingX` struct, `eta = block.timestamp + timelockDelay`, `onlyGovernance` on all
three. Do not invent a second timelock idiom in a contract that has one.

```
proposeMaintenanceWithdrawal(address to, uint256 amount)
cancelMaintenanceWithdrawal()
executeMaintenanceWithdrawal()
```

**`amount <= maintenanceReserve` is checked at EXECUTE, against live state** — a
proposal is not a lock on the reserve.

> **This is the assertion the whole change turns on:**
> **a maintenance withdrawal can never reduce `totalStake + totalBond`.**
>
> Governance may take protocol revenue. It may not take a moderator's stake or
> bond. The cap at `maintenanceReserve` is the only thing enforcing that. Test it
> directly, and test it with the reserve at zero, with `amount` exactly equal to
> the reserve, and with a withdrawal proposed while the reserve is large and
> executed after it has been drained by an earlier one.

Solvency is preserved by construction — the withdrawal lowers the balance and
`maintenanceReserve` by the same amount — but assert `solvent()` before and after
anyway.

## 3. `Moderation` — one addition

`sweepMaintenance()`, permissionless: forward `maintenanceAccrued` through
`depositMaintenance` and zero the local accumulator.

**Lazy, not per-terminal.** Forwarding at each terminal puts a token transfer on
the hot path of every case that ends, and `submit` is already the largest call in
the system at 435k. Nothing reads the reserve between sweeps.

Permissionless is safe for the same reason the deposit is: the call moves value in
exactly one direction, and a griefer who calls it repeatedly pays gas to do the
protocol's housekeeping. A sweep with nothing accrued must be a no-op, not a
revert.

## 4. Not in scope

- **`CLAIM_BOUNTY` on `UNRESOLVED`.** Still §10's open question. Your M47 pins the
  current retention; leave it pinned. This order moves the pool, it does not
  re-decide what enters it.
- Any other change to `StakeRegistry`. The unfreeze is for §2.1 and §2.2 and
  nothing else. If you find a defect while in there, **report it** — the same rule
  as before, and it has paid out seven times now.
- Setting `timelockDelay`. It is an existing constructor parameter; do not change
  its value or its provenance.

## 5. The mutation baseline — how the freeze is repaid

`StakeRegistry`'s standing rests on 25 mutations applied and 25 killed at
`b4dcaf8`. Adding two functions does not invalidate that run, but it does leave it
**incomplete**, and an incomplete baseline is worse than an absent one because it
reads as coverage.

Required:

1. **Re-run the existing 25 against the changed source.** Any that no longer apply
   because their anchor moved must be re-anchored, not dropped — say which, and
   why, for each.
2. **New mutations for both additions.** At minimum: the deposit incrementing
   without pulling; the deposit pulling without incrementing; the cap checked at
   propose instead of execute; the cap removed entirely; the cap widened to
   `balanceBuckets()`; the timelock comparison inverted; the sweep failing to zero
   the accumulator; the sweep zeroing without forwarding.
3. **Report the combined figure**, not two separate ones. `StakeRegistry`'s number
   after this order is the number an auditor will be handed.

Survivors are reported and analysed as before — your split of eight into four gaps
and four equivalent mutants is the standard, and a bare count is not.

## 6. Acceptance

1. `forge test` green across all three v3 suites; say the count.
2. **The withdrawal-cap assertion of §2.2, tested in the four configurations named
   there.**
3. `solvent()` asserted across deposit, sweep, propose, cancel and execute.
4. Value conservation extended end-to-end: a fee paid into `Moderation` and a debit
   taken in the registry both reach **one** reserve and can both leave it.
5. Combined mutation figure per §5.
6. Sizes for **both** contracts against EIP-170, with the same solc invocation.
   `StakeRegistry` was 9,058 B with 15,518 B spare, so §2 should be comfortable —
   say the new number.
7. `GAS_BUDGETS.md` for the three new calls; `DEVIATIONS.md` for anything §5.6.1
   left open.

## 7. Deliverable

One commit on **`claude/determined-curie-nkf71s`**, and in the report:

- combined mutation results for `StakeRegistry`, with the re-anchoring named
- both contract sizes
- confirmation that **no path exists from a maintenance withdrawal to
  `totalStake + totalBond`**, in whatever form you find most convincing
- anything §5.6.1 could not answer

**On the standing constraint:** this closes §10's only P0. It does not change the
constraint itself — no deployment with material funds and no safe-search
certification until an independent re-audit passes against a named commit — but it
is the last thing I know of that would have made that audit premature.
