# M2 Post-Audit Fix Work Order

**From:** Fable 5 (M2 re-audit, 2026-07-16)
**To:** Opus 4.8
**Scope:** Findings from the adversarial audit of the M2 execution (commits
`c14949a..d0f4942`). The milestone's structural guarantees verified clean:
solvent payout order independently re-derived against spec §6.2/WO-1 (refunds ⊆
pot, so non-negativity is structural, not clamped); track-update semantics match
`protocol.py`; two-seed discipline correct; conservation exact on my own re-run
(86/86). The findings below are the gaps. Same rules as always: one item per
commit (`M2-F<N>: ...`), suite green at every commit, push when done.

---

## F1 (medium) — VOID escapes the §6.3 failed-reveal freeze

`_void` releases every committer's stake via `_releaseRound` with **no freeze**
(`Moderation.sol:1032` — the comment "brief-freeze refinement: M2-5" refers to a
refinement that never landed; M2-5 fixed only the FINALIZED path).

A case VOIDs only when there were **zero reveals** after MAX_WIDEN — so every
committer in a voided round is, by definition, a commit-and-vanish actor: exactly
who the §6.3 brief freeze exists to deter. A coordinated panel (or a many-seat
whale) can commit-and-vanish repeatedly at **zero cost** (full stake back, no
freeze), each time delaying the submission by days and costing the submitter the
VOID bounty haircut. The deterrent is absent precisely in the coordinated case it
was designed for.

**Fix.** In `_void`, apply the failed-reveal treatment instead of a plain release:
for each seat-holder with `committedAmt > 0` (all of whom have `reveals == None`
by construction), move the slice committed→frozen with
`frozenUntil = max(current, now + failedRevealFreeze)` and zero their tree weight
(reuse `_freezeSlice`). Do NOT reuse `_releaseRound` here; keep `_releaseRound`
only if another caller still needs it (if none does, delete it).

**Test.** Drive a full commit-no-reveal VOID (the existing
`test_void_on_total_underparticipation...` never has commits — add a variant where
seat-holders commit but never reveal): assert every committer ends frozen for the
brief duration, excluded from the tree, and conservation holds. Assert the
existing no-commit VOID still releases nothing wrongly (nothing was locked).

## F2 (low-medium) — widen re-draw inflates a revealed voter's settlement weight

`revealVote` tallies `s = r.seats[msg.sender]` **at reveal time**
(`Moderation.sol:557`), but a later widen re-draws from the live tree and can
land additional seats on an already-committed/revealed voter
(`_drawSeats` increments `r.seats[V]`; the voter retains residual tree weight —
`_eligibleWeight` only subtracts the lock). Settlement (`_aggregate` and
`_settleRounds`) then reads the **post-widen** `r.seats[a]`. Result: reward
weight and mean-track weight exceed both the tallied weight and the locked risk
for such voters. Conservation holds (pro-rata dilutes others), but rewards are
misallocated and the §6.4 mean-track input is skewed; an early-revealing voter in
an under-participating round gets free extra reward-lottery weight per widen.

**Fix.** Record the seat count actually tallied: add
`mapping(address => uint256) talliedSeats` to `Round`; set
`r.talliedSeats[msg.sender] = s` in `revealVote`. Use `talliedSeats` (not
`seats`) everywhere in settlement: `_aggregate` (winnersSeats, meanTrack num/den)
and `_settleRounds` (reward numerator). Widen-added seats on an already-revealed
voter become inert (drawn but uncounted) — document that as the rule in
DEVIATIONS.md (new D-12): the alternative (skipping them in the draw) is
rejection sampling with unbounded gas.

**Test.** Construct the scenario end-to-end: small pool sized so a voter V is
near-certain to be re-drawn on widen (e.g. 2 moderators, V with dominant stake);
V commits+reveals in cycle 1 with k seats; force a widen; complete the round;
settle; assert V's reward equals the k-seat pro-rata share, not the inflated one.
Also update the differential reference/vectors only if you changed any arithmetic
they cover (you shouldn't need to — injection sets seats and reveals atomically;
set talliedSeats in `__injectSeat` to keep vectors bit-exact).

## F3 (low) — `contributeAppealBond` floor math can panic after a governance change

`room = floor - r.bond` (`Moderation.sol:634`) underflows (0.8 panic, not a clean
revert) if `floor` drops below the already-aggregated `r.bond` — reachable
because a parameter proposal queued *before* a case opened can execute mid-window
(timelock 7d vs window 3–4d) with a lower `bondMultiplier`.

**Fix.** `if (floor <= r.bond) revert AppealAlreadyFull();` before the
subtraction. One unit test with a mid-window parameter change.

## F4 (docs) — GAS_BUDGETS.md dropped rows the work order said to record

D9's table had budgets for `reveal`, `contributeAppealBond`, and the 47-seat
draw poke over 1000 moderators; the M2-9 actuals table silently dropped them.
The draw-poke matters most (it was the 2M budget). Measure all three (the
M2-2 single-draw gas of ~15.4k × 47 implies the poke is comfortably under
budget — verify with a real `realizeSeats` over a 1000-moderator tree) and
restore the rows with actuals.

## F5 (cosmetic) — dead `hRequestExit` in `ModerationHandler`

The unpranked variant is not in the invariant selector set and calls
`requestExit` as the handler itself. Delete it.

## F6 (note only — no code) — two accepted liveness edges, document in DEVIATIONS.md

- A case in DRAW with an empty sortition tree (everyone exited) has no timeout
  path; the fee sits until someone stakes+activates. Accepted for M2; note it as
  an ops consideration for M4 (a DRAW-timeout→VOID path is the obvious remedy if
  it ever matters).
- Removal cases don't validate `targetCaseId` at submit; a bogus target settles
  as a clean no-op per spec §10. Intentional; say so.

---

Order: F1, F2, F3 (code, each with tests), then F4, F5, F6 (docs/cleanup, can be
one commit). Update `contracts/DEVIATIONS.md` where noted. Full suite green at
every step; push after the last item.
