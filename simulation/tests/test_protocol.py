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
    """The whale earns nothing internally: net stays ~<=0 across stake shares."""
    for frac in (0.5, 0.75, 0.9):
        m = sc.whale(Params(), attacker_frac=frac, trials=800, seed=11)
        per_case = m.faction_net("attacker") / m.n
        assert per_case < 0.5, (frac, per_case)


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
