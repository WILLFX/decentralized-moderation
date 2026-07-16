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

    # winners' seats (coherent revealers, all rounds)
    winners_seats = 0
    for r in rounds:
        for (_vi, seats, _camt, rc) in r["seats"]:
            if rc != 0 and coherent(rc, fo):
                winners_seats += seats

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

    # rewards + committed disposition
    distributed = 0
    free: dict[int, int] = {}
    frozen: dict[int, int] = {}
    for r in rounds:
        for (vi, seats, camt, rc) in r["seats"]:
            if rc == 0:
                frozen[vi] = frozen.get(vi, 0) + camt          # failed reveal -> frozen
            elif coherent(rc, fo):
                reward = 0 if winners_seats == 0 else distributable * seats // winners_seats
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

    claim_bounty = bounty + (distributable - distributed) + (bonus_pool - bonus_paid)
    return {"free": free, "frozen": frozen, "payout": payout, "claimBounty": claim_bounty}
