"""The M1 adversarial scenarios (README §7, §3.6).

Each scenario builds a population, runs many independent trials of a case, and
returns a :class:`Metrics` aggregate. Scenarios are pure functions of
(:class:`Params`, knobs, seed) so a sweep is reproducible and diffable.

Design intent, mapped to what each scenario is meant to demonstrate:

  whale                -- probability-buying whale: even a stake majority cannot
                          force an outcome with certainty, and winning pays it
                          nothing internally (net cost = fees + forfeited bonds;
                          plus freeze drag). README §3.6 "Why not deterministic
                          majority", "Where does the attack cost live".
  bond_war             -- honest challengers re-appeal attacker wins up the
                          ladder; who funds whom. README §3.6 bond ladder.
  track_farming        -- manufacturing freezing power by self-submitting
                          innocuous content; the cost of the farm vs the power
                          gained. README §7 "Track-record farming".
  honest_earnings      -- an honest moderator's ROI on clear vs borderline
                          content with no attacker present. Principle 1.
  copy_voting          -- first-come racing / copy-voting degrades correctness
                          only if commit-reveal independence breaks. README §7.
  underparticipation   -- offline moderators trigger subset widening; effect on
                          liveness and correctness. Spec §5.2 widen path.
"""

from __future__ import annotations

import math
import random
from typing import Callable, List, Optional

from .agents import attacker_for, honest, lazy_copy
from .metrics import Metrics
from .params import Params
from .protocol import Case, Moderator, Outcome, run_case


# ---------------------------------------------------------------------------
# population construction
# ---------------------------------------------------------------------------

def build_population(
    rng: random.Random,
    n_honest: int = 200,
    honest_total_stake: float = 4000.0,
    honest_track: float = 0.0,
    attacker_total_stake: float = 0.0,
    attacker_identity_stake: float = 100.0,
    attacker_target: Optional[Outcome] = None,
    honest_reveal_prob: float = 1.0,
    lazy_frac: float = 0.0,
) -> List[Moderator]:
    """Construct a moderator population.

    Honest stake is spread with mild dispersion around the mean so the set is
    not perfectly uniform. Attacker capital is split into ``attacker_identity_stake``
    sized identities (splitting is protocol-neutral for stake-weighted draws;
    see tests). ``lazy_frac`` of honest moderators use the copy-voting strategy.
    """
    pop: List[Moderator] = []
    mean_stake = honest_total_stake / max(n_honest, 1)
    next_id = 0
    for _ in range(n_honest):
        # log-normal-ish spread, clamped to >= min stake, preserving the mean
        s = max(1.0, rng.lognormvariate(math.log(max(mean_stake, 1.0)) - 0.18, 0.6))
        is_lazy = rng.random() < lazy_frac
        pop.append(Moderator(
            id=next_id, stake=s, faction="honest", track=honest_track,
            vote_fn=(lazy_copy if is_lazy else honest),
            reveal_prob=honest_reveal_prob,
        ))
        next_id += 1

    if attacker_total_stake > 0:
        tgt = attacker_target if attacker_target is not None else Outcome.APPROVE
        remaining = attacker_total_stake
        while remaining > 1e-9:
            s = min(attacker_identity_stake, remaining)
            remaining -= s
            pop.append(Moderator(
                id=next_id, stake=s, faction="attacker", track=0.0,
                vote_fn=attacker_for(tgt), reveal_prob=1.0,
            ))
            next_id += 1
    return pop


def _make_case(kind: str, honest_label: Outcome, difficulty: float,
               attacker_target: Optional[Outcome], n_topics: int = 1) -> Case:
    c = Case(kind=kind, honest_label=honest_label, difficulty=difficulty,
             n_topics=n_topics, submitter_faction="attacker" if attacker_target else "creator")
    c.attacker_target = attacker_target
    return c


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

def whale(p: Params, attacker_frac: float = 0.5, honest_track: float = 0.0,
          difficulty: float = 0.0, trials: int = 2000, seed: int = 1) -> Metrics:
    """Probability-buying whale forcing APPROVE on unsafe content.

    ``attacker_frac`` is the attacker's share of total stake. ``honest_track``
    lets us contrast a newcomer-whale against established veterans (principle 4:
    veterans freeze the attacker far longer).
    """
    rng = random.Random(seed)
    m = Metrics()
    honest_total = 4000.0
    # attacker stake so that A / (A + H) == attacker_frac
    attacker_total = honest_total * attacker_frac / max(1e-9, 1.0 - attacker_frac)
    for _ in range(trials):
        pop = build_population(
            rng, honest_total_stake=honest_total, honest_track=honest_track,
            attacker_total_stake=attacker_total, attacker_target=Outcome.APPROVE,
        )
        case = _make_case("submission", Outcome.REJECT, difficulty, Outcome.APPROVE)
        r = run_case(pop, p, case, rng)
        m.add(r, attacker_target=Outcome.APPROVE)
    return m


def bond_war(p: Params, attacker_frac: float = 0.55, trials: int = 2000,
             seed: int = 2) -> Metrics:
    """Attacker with a slight majority that keeps re-appealing; honest side too.

    Focuses on depth reached and who forfeits bonds into the pot.
    """
    return whale(p, attacker_frac=attacker_frac, honest_track=5.0,
                 difficulty=0.0, trials=trials, seed=seed)


def track_farming(p: Params, farm_cases: int = 30, attacker_frac: float = 0.5,
                  trials: int = 500, seed: int = 3) -> dict:
    """Manufacture freezing power via innocuous self-submissions, then attack.

    Returns the cost of the farm (fees spent), the freezing power gained, and the
    attack outcome afterwards. The farm is only worthwhile if the extra freeze
    drag it buys exceeds its fee cost -- which the cap+decay are meant to prevent.
    """
    from .protocol import freezing_power

    rng = random.Random(seed)
    # A single persistent attacker cohort farms track over `farm_cases` honest
    # self-submissions (they judge their own innocuous content coherently).
    honest_total = 4000.0
    attacker_total = honest_total * attacker_frac / max(1e-9, 1.0 - attacker_frac)

    farm_fee_cost = 0.0
    farm_reward = 0.0
    # Build a persistent population so track accumulates.
    pop = build_population(rng, honest_total_stake=honest_total,
                           attacker_total_stake=attacker_total,
                           attacker_target=Outcome.APPROVE)
    # During farming the attacker votes honestly on genuinely safe content, so
    # temporarily give attacker identities the honest strategy.
    for mod in pop:
        if mod.faction == "attacker":
            mod._farm_vote = mod.vote_fn
            mod.vote_fn = honest

    for _ in range(farm_cases):
        case = _make_case("submission", Outcome.APPROVE, 0.0, None)
        case.submitter_faction = "attacker"
        r = run_case(pop, p, case, rng, appeal_policy=lambda *a, **k: None)
        farm_fee_cost += r.fees_paid.get("attacker", 0.0)
        farm_reward += r.rewards_earned.get("attacker", 0.0)

    # Freezing power is computed from the split-resistant MEAN track of the
    # winning side (spec §6.4), so report the mean the engine actually uses —
    # not the sum, which splitting would inflate.
    atk = [mod for mod in pop if mod.faction == "attacker"]
    mean_track = sum(mod.track for mod in atk) / max(len(atk), 1)
    power_gained = freezing_power(mean_track, p)

    def _attack_freeze(cohort, n):
        """Run n attacks with `cohort` as the attacker set; return honest freeze
        drag (stake-days) and attack success. Fresh honest cohort each attack."""
        mm = Metrics()
        for _ in range(n):
            honest_pop = build_population(rng, honest_total_stake=honest_total,
                                          attacker_total_stake=0.0)
            for a in cohort:
                a.frozen_until = 0.0
            case = _make_case("submission", Outcome.REJECT, 0.0, Outcome.APPROVE)
            r = run_case(honest_pop + cohort, p, case, rng)
            mm.add(r, attacker_target=Outcome.APPROVE)
        return mm

    # restore attack behaviour on the farmed cohort
    for mod in atk:
        mod.vote_fn = mod._farm_vote
    farmed = _attack_freeze(atk, trials)

    # control: an identical-stake attacker that never farmed (track = 0)
    control_cohort = build_population(rng, n_honest=0, honest_total_stake=0.0,
                                      attacker_total_stake=attacker_total,
                                      attacker_target=Outcome.APPROVE)
    control = _attack_freeze(control_cohort, trials)

    f_honest = farmed.freeze_stake_days.get("honest", 0.0) / max(farmed.n, 1)
    c_honest = control.freeze_stake_days.get("honest", 0.0) / max(control.n, 1)
    return {
        "farm_cases": farm_cases,
        "farm_net_cost_xbzz": round(farm_fee_cost - farm_reward, 3),
        "attacker_mean_track": round(mean_track, 3),
        "freezing_power_gained": round(power_gained, 3),   # 1.0 = none, cap = max
        "honest_freeze_per_attack_farmed": round(f_honest, 1),
        "honest_freeze_per_attack_control": round(c_honest, 1),
        "farm_freeze_multiplier": round(f_honest / c_honest, 3) if c_honest else None,
        "post_farm_attack": farmed.summary(),
    }


def honest_earnings(p: Params, difficulty: float = 0.0, trials: int = 3000,
                    seed: int = 4) -> Metrics:
    """Honest-moderator economics with no attacker: clear vs borderline content."""
    rng = random.Random(seed)
    m = Metrics()
    for _ in range(trials):
        pop = build_population(rng)
        label = Outcome.APPROVE if rng.random() < 0.5 else Outcome.REJECT
        case = _make_case("submission", label, difficulty, None)
        r = run_case(pop, p, case, rng)
        m.add(r)
    return m


def fee_floor(op_costs=(0.005, 0.02, 0.05, 0.1, 0.25), margin: float = 1.5,
              difficulty: float = 0.0, trials: int = 3000, seed: int = 7) -> list:
    """Derive the fee floor from the per-vote operating cost, and validate it.

    For each assumed per-judgment operating cost ``c`` (the real-world unknown),
    build the fee floor via :class:`CostModel` (gas + minimum voter pay at
    ``margin`` over cost), then run the honest, no-attacker scenario at exactly
    that floor with moderators charged ``c`` per judgment. Reports whether honest
    moderators clear their costs (``honest_net_per_case`` > 0) at the floor, and
    how little of the fee is gas.
    """
    from .costs import CostModel

    rows = []
    for c in op_costs:
        cm = CostModel(op_cost_per_vote_xbzz=c, voter_pay_margin=margin)
        p = Params()
        p.fee_base = cm.fee_base()
        p.fee_per_topic = cm.fee_per_topic()
        p.op_cost_per_vote = c
        rng = random.Random(seed)
        m = Metrics()
        for _ in range(trials):
            pop = build_population(rng)
            label = Outcome.APPROVE if rng.random() < 0.5 else Outcome.REJECT
            case = _make_case("submission", label, difficulty, None)  # fee defaults to min_fee
            r = run_case(pop, p, case, rng)
            m.add(r)
        bd = cm.breakdown(1)
        rows.append({
            **bd,
            "honest_net_per_case_xbzz": round(m.faction_net("honest") / m.n, 5),
            "correctness": round(m.correctness(), 4),
            "moderators_clear_costs": m.faction_net("honest") > 0,
        })
    return rows


def copy_voting(p: Params, lazy_frac: float = 0.5, difficulty: float = 0.1,
                trials: int = 3000, seed: int = 5) -> Metrics:
    """First-come racing / copy-voting: correctness as copy-voter share grows."""
    rng = random.Random(seed)
    m = Metrics()
    for _ in range(trials):
        pop = build_population(rng, lazy_frac=lazy_frac)
        label = Outcome.APPROVE if rng.random() < 0.5 else Outcome.REJECT
        case = _make_case("submission", label, difficulty, None)
        r = run_case(pop, p, case, rng)
        m.add(r)
    return m


def underparticipation(p: Params, online_frac: float = 0.3, difficulty: float = 0.0,
                       trials: int = 3000, seed: int = 6) -> Metrics:
    """Only ``online_frac`` of committers reveal; measure liveness + correctness."""
    rng = random.Random(seed)
    m = Metrics()
    for _ in range(trials):
        pop = build_population(rng, honest_reveal_prob=online_frac)
        label = Outcome.APPROVE if rng.random() < 0.5 else Outcome.REJECT
        case = _make_case("submission", label, difficulty, None)
        r = run_case(pop, p, case, rng)
        m.add(r)
    return m
