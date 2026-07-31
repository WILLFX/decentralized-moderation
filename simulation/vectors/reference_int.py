"""Integer reference for the M2 settlement payout arithmetic (spec §6, WO-1 order).

This mirrors ``claim()`` in ``contracts/src/Moderation.sol`` exactly — same order,
same floor divisions, same dust-to-bounty sweep — so the Foundry differential test
(``test/Differential.t.sol``) can assert bit-exact agreement between the Solidity
implementation and this independent reimplementation (work order D10).

It covers the *payout* arithmetic (rewards, refunds, bonuses, claim bounty, and the
committed→free/frozen disposition). Freeze *durations* depend on solady's expWad and
are checked separately with a tolerance (``FreezeMath.t.sol``); they are not part of
these vectors.

Reveal codes: 0 = None (committed, failed to reveal), 1 = Approve, 2 = Reject.
Outcome codes: 1 = Approve, 2 = Reject.
"""

WAD = 10**18
CLAIM_BOUNTY_FRAC = WAD // 100   # 1%   (contract default)
BONUS_FRAC = WAD // 10           # 10%  (contract default)


def coherent(reveal_code: int, final_outcome: int) -> bool:
    return (reveal_code == 1 and final_outcome == 1) or (reveal_code == 2 and final_outcome == 2)


def settle(case: dict) -> dict:
    """Return {free, frozen, payout, claimBounty} for a fully-specified case.

    free/frozen are keyed by voter index; payout by contributor index. free[v] is
    the voter's total free balance after settlement (returned committed stake plus
    any reward); frozen[v] is their frozen stake.
    """
    pot = case["pot"]
    fo = case["finalOutcome"]
    rounds = case["rounds"]

    # M2.6-item-10. `winners_seats` survives ONLY as the denominator of the
    # mean-track that drives the freeze curve; it is no longer the reward divisor.
    # Scoping one half of a mean without the other leaves a ratio that is not a mean
    # of anything, so the pair stays paired.
    winners_seats = 0
    for r in rounds:
        for (_vi, seats, _camt, rc) in r["seats"]:
            if rc != 0 and coherent(rc, fo):
                winners_seats += seats

    # Per-round revealed seats (side-agnostic: a vote moves between the two side
    # counters and never the sum) and capacity sought. The injector records one
    # unit of capacity per injected seat, mirroring `_openRound`'s `r.target`.
    revealed = [sum(seats for (_v, seats, _c, rc) in r["seats"] if rc != 0) for r in rounds]
    capacity = [sum(seats for (_v, seats, _c, _rc) in r["seats"]) for r in rounds]
    win_d = [
        sum(seats for (_v, seats, _c, rc) in r["seats"] if rc != 0 and coherent(rc, fo))
        for r in rounds
    ]
    sum_capacity = sum(capacity)
    # The last round is the one whose tally drew the outcome.
    adj_round = len(rounds) - 1

    # winning-appeal refunds
    refunds = 0
    winning_contrib_tot = 0
    for r in rounds:
        if r["bondInPot"] and r["appealForCode"] == fo:
            b = sum(a for (_ci, a) in r["bondContribs"])
            refunds += b
            winning_contrib_tot += b

    residual = pot - refunds
    bounty = residual * CLAIM_BOUNTY_FRAC // WAD
    bonus_pool = 0 if winning_contrib_tot == 0 else residual * BONUS_FRAC // WAD
    distributable = residual - bounty - bonus_pool

    # M2.6-item-10: allocate per round, then divide by a DEPTH-DEPENDENT divisor.
    #
    # Winning seats where the outcome is drawn (the cancellation is the neutrality),
    # revealed seats at a superseded depth (side-agnostic, so no factor lands on top
    # of the belief ratio). No single divisor is neutral at both.
    pool = [0] * len(rounds)
    divisor = [0] * len(rounds)
    payable = 0
    for d in range(len(rounds)):
        pool[d] = 0 if sum_capacity == 0 else distributable * revealed[d] // sum_capacity
        divisor[d] = win_d[d] if d == adj_round else revealed[d]
        if divisor[d] != 0:
            payable += pool[d] * win_d[d] // divisor[d]
    # What no adjudicating depth earned returns to the case's fee payer.
    submitter_refund = distributable - payable

    # rewards + committed disposition
    distributed = 0
    free: dict[int, int] = {}
    frozen: dict[int, int] = {}
    for d, r in enumerate(rounds):
        for (vi, seats, camt, rc) in r["seats"]:
            if rc == 0:
                frozen[vi] = frozen.get(vi, 0) + camt          # failed reveal -> frozen
            elif coherent(rc, fo):
                reward = 0 if divisor[d] == 0 else pool[d] * seats // divisor[d]
                distributed += reward
                free[vi] = free.get(vi, 0) + camt + reward     # stake back + reward
            else:
                frozen[vi] = frozen.get(vi, 0) + camt          # incoherent -> frozen

    # winning-appeal payouts: refund own capital + bonus pro-rata
    bonus_paid = 0
    payout: dict[int, int] = {}
    for r in rounds:
        if r["bondInPot"] and r["appealForCode"] == fo:
            for (ci, amt) in r["bondContribs"]:
                bonus = 0 if winning_contrib_tot == 0 else bonus_pool * amt // winning_contrib_tot
                payout[ci] = payout.get(ci, 0) + amt + bonus
                bonus_paid += bonus

    # C-01: winning-appeal refunds+bonuses are pulled per contributor
    # (claimAppealPayout), not credited in an unbounded settlement loop. Only the
    # reward-channel dust is swept into the claim bounty; the bonus-channel dust
    # stays in the pull pool and is absorbed by the final claimer, so the claim
    # bounty no longer includes ``bonus_pool - bonus_paid``. ``payout`` here is the
    # pristine (pre-pull) per-contributor amount the on-chain view reports.
    _ = bonus_paid  # retained for clarity; not swept to the bounty
    # M2.6-item-10: the keeper's residue is bounded by ROUNDING — at most one wei
    # per paid seat-holder, independent of the size of the pot. It reads `payable`,
    # not `distributable`: the unclaimed allocation never enters the reward channel,
    # so it cannot be swept here. Left in `distributable`, the empty-winning-side
    # case hands the WHOLE allocation to whoever sends the last batch.
    claim_bounty = bounty + (payable - distributed)
    return {
        "free": free,
        "frozen": frozen,
        "payout": payout,
        "claimBounty": claim_bounty,
        "submitterRefund": submitter_refund,
    }
