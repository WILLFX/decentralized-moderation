"""Invariant and sanity tests for the protocol engine.

Runnable two ways:
    python -m pytest tests/            # if pytest is available
    python tests/test_protocol.py      # standalone, no dependencies

The tests assert the load-bearing design properties from the README and
``specs/state-machine.md``: stake-proportional outcomes, no internal stake
transfer (principle 2), approximate identity-split neutrality of the draw, a
bounded/monotone freeze multiplier, and the index ``uncontested`` semantics.
"""

from __future__ import annotations

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from moderation_sim.params import Params
from moderation_sim.protocol import (
    Case, Moderator, Outcome, _draw_outcome, freezing_power, run_case,
)
from moderation_sim import scenarios as sc
from moderation_sim.agents import attacker_for, honest


def test_draw_outcome_is_stake_proportional():
    rng = random.Random(0)
    n = 40000
    approve_w, reject_w = 2.0, 1.0
    approvals = sum(1 for _ in range(n)
                    if _draw_outcome(approve_w, reject_w, rng) == Outcome.APPROVE)
    p_hat = approvals / n
    assert abs(p_hat - 2.0 / 3.0) < 0.01, p_hat


def test_draw_outcome_unanimous_is_deterministic():
    rng = random.Random(1)
    assert all(_draw_outcome(5.0, 0.0, rng) == Outcome.APPROVE for _ in range(100))
    assert all(_draw_outcome(0.0, 5.0, rng) == Outcome.REJECT for _ in range(100))


def test_no_internal_stake_transfer():
    """Principle 2: a case never moves stake *principal* between moderators.

    Rewards accrue to a separate ``earnings`` ledger; ``stake`` is untouched by
    voting/settlement in the model.
    """
    rng = random.Random(2)
    pop = sc.build_population(rng, attacker_total_stake=2000.0,
                              attacker_target=Outcome.APPROVE)
    before = {m.id: m.stake for m in pop}
    for _ in range(50):
        case = Case(kind="submission", honest_label=Outcome.REJECT, difficulty=0.0)
        case.attacker_target = Outcome.APPROVE
        run_case(pop, Params(), case, rng)
    after = {m.id: m.stake for m in pop}
    assert before == after


def test_freezing_power_bounded_and_monotone():
    p = Params()
    assert freezing_power(0.0, p) == 1.0
    prev = 1.0
    for t in (1, 5, 10, 50, 200, 10_000):
        val = freezing_power(float(t), p)
        assert val >= prev - 1e-9
        assert val <= p.freeze_cap + 1e-9
        prev = val
    assert freezing_power(1e9, p) <= p.freeze_cap + 1e-9


def test_split_neutrality_of_draw_is_approximate():
    """Splitting one stake into many identities should not materially change the
    outcome distribution (README 3.3). Compare a whale as 1 identity vs 20."""
    def approve_rate(identity_stake, seed):
        rng = random.Random(seed)
        approvals = 0
        trials = 1500
        for _ in range(trials):
            pop = sc.build_population(
                rng, attacker_total_stake=2000.0,
                attacker_identity_stake=identity_stake,
                attacker_target=Outcome.APPROVE)
            case = Case(kind="submission", honest_label=Outcome.REJECT, difficulty=0.0)
            case.attacker_target = Outcome.APPROVE
            r = run_case(pop, Params(), case, rng)
            approvals += int(r.final_outcome == Outcome.APPROVE)
        return approvals / trials

    whole = approve_rate(2000.0, 10)      # one big identity
    split = approve_rate(100.0, 10)       # twenty identities
    assert abs(whole - split) < 0.08, (whole, split)


def test_min_fee_scales_with_topics():
    p = Params()
    assert p.min_fee(1) < p.min_fee(3) < p.min_fee(5)
    assert p.min_fee(2) == p.fee_base + 2 * p.fee_per_topic


def test_uncontested_flag_semantics():
    """uncontested is True only for a clean unanimous approve with no appeal."""
    rng = random.Random(7)
    # all-honest population, clearly-safe content -> should approve unanimously
    got_clean = False
    for _ in range(200):
        pop = sc.build_population(rng)
        case = Case(kind="submission", honest_label=Outcome.APPROVE, difficulty=0.0)
        r = run_case(pop, Params(), case, rng)
        if r.final_outcome == Outcome.APPROVE and r.uncontested:
            got_clean = True
            break
    assert got_clean, "expected at least one clean uncontested approval"


def test_attacker_never_nets_large_profit():
    """The whale earns nothing internally: net stays ~<=0 across stake shares.

    A small positive residue at high stake is honest appeal-variance bonds
    (external money), never a stake transfer -- bounded by the honest appeal
    threshold. It must stay near zero.
    """
    for frac in (0.5, 0.75, 0.9):
        m = sc.whale(Params(), attacker_frac=frac, trials=1000, seed=11)
        per_case = m.faction_net("attacker") / m.n
        assert per_case < 0.25, (frac, per_case)


def test_first_round_outcome_tracks_stake_share():
    """No double-count: a faction's win probability equals its STAKE SHARE, once.

    With stake-weighted selection + flat voting, the depth-0 approve rate should
    track the attacker's stake fraction -- not exceed it (which a second,
    stake-weighted, tally benefit would cause).
    """
    from moderation_sim.protocol import Case, _run_round, honest_vote
    p = Params()
    for frac in (0.3, 0.5, 0.7):
        rng = random.Random(100 + int(frac * 10))
        approve = 0
        trials = 2500
        for _ in range(trials):
            pop = sc.build_population(
                rng, honest_total_stake=4000.0,
                attacker_total_stake=4000.0 * frac / (1 - frac),
                attacker_target=Outcome.APPROVE)
            case = Case(kind="submission", honest_label=Outcome.REJECT, difficulty=0.0)
            case.attacker_target = Outcome.APPROVE
            r = _run_round(case, pop, 0, p, rng)
            approve += int(r.outcome == Outcome.APPROVE)
        rate = approve / trials
        assert abs(rate - frac) < 0.06, (frac, rate)


def test_modest_split_farm_buys_little_attack_advantage():
    """A cheap split-identity farm does not buy the attacker success (campaign).

    In campaign mode the real payoff of farming would be freezing honest capacity
    out of later draws to raise attack success. A modest split-identity 30-case
    farm must not approach the freeze cap and must not materially raise the
    attacker's success over an unfarmed control. (Concentration is guarded
    separately in WO-6.)
    """
    res = sc.track_farming(Params(), farm_cases=30, attack_cases=150,
                           attacker_frac=0.5, identity_stake=100.0, seeds=6)
    assert res["freezing_power_gained"] < 2.0, res
    # averaged over seeds: a split farm buys no meaningful attack-success uplift
    assert res["success_uplift"] < 0.15, res


def test_freeze_excludes_from_draws():
    """A frozen moderator must not be drawn into any panel until it thaws.

    Guards the campaign-mode fix (WO-2): freezing is only a deterrent if a frozen
    moderator is actually absent from the eligible pool of later cases. Drives a
    persistent population on an absolute clock and checks a moderator frozen until
    day 10 is never seated before day 10, and is seated again afterward.
    """
    from moderation_sim.protocol import Case, run_case
    from moderation_sim.campaign import run_campaign
    rng = random.Random(5)
    p = Params()
    pop = sc.build_population(rng, n_honest=40, honest_total_stake=1200.0)
    victim = pop[0]
    victim.frozen_until = 10.0
    clock, seen_frozen, seen_thawed = 0.0, 0, 0
    for _ in range(80):
        case = Case(kind="submission", honest_label=Outcome.APPROVE, difficulty=0.0)
        case.now = clock
        run_case(pop, p, case, rng)
        appeared = any(victim.id in r.seats for r in case.rounds)
        if clock < 10.0 and appeared:
            seen_frozen += 1
        elif clock >= 10.0 and appeared and not victim.is_frozen(clock):
            seen_thawed += 1
        clock += 0.5
    assert seen_frozen == 0, "a frozen moderator was drawn into a panel"
    assert seen_thawed > 0, "moderator was never re-eligible after thawing"

    # smoke: run_campaign drives the same mechanism end to end
    pop2 = sc.build_population(random.Random(6), n_honest=50)
    res = run_campaign(pop2, p,
                       lambda i, r: Case(kind="submission",
                                         honest_label=Outcome.APPROVE, difficulty=0.0),
                       n_cases=30, rng=random.Random(6))
    assert len(res) == 30


def test_settlement_conserves_funds():
    """Invariant 1 (spec §9): every case pays out exactly what came in.

    Across many DISPUTED cases (appeals opened, outcomes flipping up the ladder),
    the pot (fee + all bonds) must equal refunds + claim bounty + all rewards
    credited. Guards the flip-flop insolvency (WO-1): no path may mint money.
    """
    from moderation_sim.protocol import Case, run_case
    rng = random.Random(123)
    p = Params()   # op_cost_per_vote == 0, so the pot is the only money in play

    def force_appeal(case, r, pop, pp, rng_):
        """Appeal EVERY round to max depth, so outcomes flip-flop and multiple
        appellants end up vindicated — the exact insolvency case WO-1 fixes."""
        bond = max(pp.bond_multiplier * (case.fee + sum(rr.bond for rr in case.rounds)),
                   pp.min_fee(case.n_topics))
        cands = [m for m in pop if not m.is_frozen(case.now) and m.stake >= bond]
        return max(cands, key=lambda m: m.stake) if cands else None

    n = 2500
    for _ in range(n):
        pop = sc.build_population(rng, attacker_total_stake=5000.0,
                                  attacker_target=Outcome.APPROVE)
        case = Case(kind="submission", honest_label=Outcome.REJECT, difficulty=0.4)
        case.attacker_target = Outcome.APPROVE
        r = run_case(pop, p, case, rng, appeal_policy=force_appeal)
        assert r.disputed, "forcing policy must produce a disputed case"
        inflow = case.fee + sum(rr.bond for rr in case.rounds)
        outflow = (r.refunded_bonds + r.claim_bounty_paid
                   + sum(r.rewards_earned.values()))
        assert abs(inflow - outflow) < 1e-6, (inflow, outflow, r.depth_reached)


def test_fee_floor_lets_moderators_clear_costs():
    """At the derived fee floor, honest moderators net positive after op costs.

    With SOLVENT settlement (WO-1), a 1.5x margin clears costs on clear content;
    covering borderline content too needs ~2x. Both are asserted so the guarantee
    is stated honestly rather than assumed (spec §11.5, FINDINGS §2b).
    """
    # margin 1.5 clears on clear content (the bulk of submissions)
    for r in sc.fee_floor(op_costs=(0.01, 0.05, 0.2), margin=1.5,
                          difficulty=0.0, trials=1500, seed=7):
        assert r["moderators_clear_costs"] and r["honest_net_per_case_xbzz"] > 0, r
    # margin 2.0 clears across content difficulty, including borderline
    for diff in (0.0, 0.5):
        for r in sc.fee_floor(op_costs=(0.01, 0.05, 0.2), margin=2.0,
                              difficulty=diff, trials=1500, seed=7):
            assert r["moderators_clear_costs"] and r["honest_net_per_case_xbzz"] > 0, (diff, r)


def test_fee_floor_gas_is_negligible():
    """The fee floor is dominated by voter pay, not Gnosis gas."""
    from moderation_sim.costs import CostModel
    for c in (0.005, 0.05, 0.25):
        bd = CostModel(op_cost_per_vote_xbzz=c).breakdown(1)
        assert bd["gas_share_of_fee"] < 0.05, bd


def _run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    failures = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failures += 1
            print(f"FAIL {fn.__name__}: {e}")
    print(f"\n{len(fns) - failures}/{len(fns)} passed")
    return failures


if __name__ == "__main__":
    sys.exit(1 if _run_all() else 0)
