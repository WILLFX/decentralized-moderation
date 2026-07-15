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
  copy_voting          -- copy-voting / correlated voting degrades correctness
                          only if commit-reveal independence breaks. (Panels are
                          drawn by sortition, so there is no first-come race.)
  underparticipation   -- offline moderators trigger subset widening; effect on
                          liveness and correctness. Spec §5.2 widen path.
"""

from __future__ import annotations

import math
import random
from statistics import mean, pstdev
from typing import Callable, List, Optional

from .agents import attacker_for, honest, lazy_copy
from .campaign import run_campaign
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
    min_stake: float = 10.0,
) -> List[Moderator]:
    """Construct a moderator population.

    Honest stake is spread with mild dispersion around the mean so the set is
    not perfectly uniform, and clamped to the ``min_stake`` floor so every
    moderator would be valid on-chain (MIN_STAKE = 10). Attacker capital is split
    into ``attacker_identity_stake`` sized identities (splitting is
    protocol-neutral for stake-weighted draws; see tests). ``lazy_frac`` of honest
    moderators use the copy-voting strategy.
    """
    pop: List[Moderator] = []
    mean_stake = honest_total_stake / max(n_honest, 1)
    next_id = 0
    for _ in range(n_honest):
        # log-normal-ish spread, clamped to the MIN_STAKE floor (not 1.0), so no
        # sub-minimum-stake moderators exist that the contract would reject.
        s = max(min_stake, rng.lognormvariate(math.log(max(mean_stake, 1.0)) - 0.18, 0.6))
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
          difficulty: float = 0.0, honest_online: float = 1.0, lazy_frac: float = 0.0,
          trials: int = 2000, seed: int = 1) -> Metrics:
    """Probability-buying whale forcing APPROVE on unsafe content.

    ``attacker_frac`` is the attacker's share of total stake. A rational attacker
    chooses ``difficulty`` (plausibly-borderline content is easier to push) and
    stays online while honest liveness (``honest_online``) fluctuates — the
    attacker's own reveal probability is always 1.0. ``lazy_frac`` seeds
    copy-voters into the honest side.
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
            honest_reveal_prob=honest_online, lazy_frac=lazy_frac,
        )
        case = _make_case("submission", Outcome.REJECT, difficulty, Outcome.APPROVE)
        r = run_case(pop, p, case, rng)
        m.add(r, attacker_target=Outcome.APPROVE)
    return m


def whale_multiseed(p: Params, attacker_frac=0.5, difficulty=0.0, honest_online=1.0,
                    lazy_frac=0.0, honest_track=0.0, trials=800, seeds=5, seed0=1):
    """Run :func:`whale` across several seeds; return (mean, sd) of attack success
    and attacker net/case, so headline numbers carry a confidence band."""
    succ, net = [], []
    for s in range(seeds):
        m = whale(p, attacker_frac=attacker_frac, difficulty=difficulty,
                  honest_online=honest_online, lazy_frac=lazy_frac,
                  honest_track=honest_track, trials=trials, seed=seed0 + s)
        succ.append(m.attack_success_rate())
        net.append(m.faction_net("attacker") / m.n)
    return {
        "success_mean": mean(succ), "success_sd": pstdev(succ) if seeds > 1 else 0.0,
        "attacker_net_mean": mean(net), "attacker_net_sd": pstdev(net) if seeds > 1 else 0.0,
    }


def bond_war(p: Params, attacker_frac: float = 0.55, trials: int = 2000,
             seed: int = 2) -> Metrics:
    """Attacker with a slight majority that keeps re-appealing; honest side too.

    Focuses on depth reached and who forfeits bonds into the pot.
    """
    return whale(p, attacker_frac=attacker_frac, honest_track=5.0,
                 difficulty=0.0, trials=trials, seed=seed)


def _farm_then_attack(p: Params, do_farm: bool, farm_cases: int, attack_cases: int,
                      attacker_frac: float, identity_stake: float,
                      cases_per_day: float, seed: int):
    """One CAMPAIGN: an attacker cohort optionally farms track on innocuous
    self-submissions, then attacks unsafe content, on ONE persistent population
    and clock. Because freeze is absolute-time and the population persists, a
    farm that lets the attacker freeze honest voters longer actually removes that
    honest capacity from later draws — the real payoff campaign mode can measure.
    Returns (attack Metrics, attacker seat-weighted mean track, farm net cost).
    """
    rng = random.Random(seed)
    honest_total = 4000.0
    attacker_total = honest_total * attacker_frac / max(1e-9, 1.0 - attacker_frac)
    pop = build_population(rng, honest_total_stake=honest_total,
                           attacker_total_stake=attacker_total,
                           attacker_identity_stake=identity_stake,
                           attacker_target=Outcome.APPROVE)
    atk = [m for m in pop if m.faction == "attacker"]
    for m in atk:
        m._atk_vote = m.vote_fn
    clock, dt, farm_net = 0.0, 1.0 / cases_per_day, 0.0

    if do_farm:
        for m in atk:
            m.vote_fn = honest                      # judge innocuous content honestly
        for _ in range(farm_cases):
            case = _make_case("submission", Outcome.APPROVE, 0.0, None)
            case.submitter_faction = "attacker"
            case.now = clock
            r = run_case(pop, p, case, rng, appeal_policy=lambda *a, **k: None)
            farm_net += (r.fees_paid.get("attacker", 0.0)
                         - r.rewards_earned.get("attacker", 0.0))
            clock += dt
        for m in atk:
            m.vote_fn = m._atk_vote

    mm = Metrics()
    for _ in range(attack_cases):
        case = _make_case("submission", Outcome.REJECT, 0.0, Outcome.APPROVE)
        case.now = clock                            # persistent clock: farmed freeze carries
        r = run_case(pop, p, case, rng)
        mm.add(r, attacker_target=Outcome.APPROVE)
        clock += dt
    mean_track = (sum(m.track * m.stake for m in atk) / sum(m.stake for m in atk)
                  if atk else 0.0)
    return mm, mean_track, farm_net


def track_farming(p: Params, farm_cases: int = 30, attack_cases: int = 200,
                  attacker_frac: float = 0.5, identity_stake: float = 100.0,
                  cases_per_day: float = 2.0, seeds: int = 8, seed0: int = 100) -> dict:
    """Manufacture freezing power via innocuous self-submissions, then attack —
    in campaign mode, so the farm's real payoff (freezing honest capacity out of
    later draws, raising the attacker's success over time) is measured, not just
    a passive stake-days number. Compares a farmed attacker against an
    identical-stake control that skipped the farm.

    Freeze creates a compounding positive-feedback loop, so a single campaign is a
    high-variance random walk; results are AVERAGED over ``seeds`` independent
    campaigns and reported with a standard deviation. This is essential — a single
    seed is not interpretable.
    """
    from .protocol import freezing_power

    upl, sf, sc_, mt, fn = [], [], [], [], []
    for s in range(seeds):
        farmed, mean_track, farm_net = _farm_then_attack(
            p, True, farm_cases, attack_cases, attacker_frac, identity_stake,
            cases_per_day, seed0 + s)
        control, _, _ = _farm_then_attack(
            p, False, farm_cases, attack_cases, attacker_frac, identity_stake,
            cases_per_day, seed0 + s)
        sf.append(farmed.attack_success_rate())
        sc_.append(control.attack_success_rate())
        upl.append(farmed.attack_success_rate() - control.attack_success_rate())
        mt.append(mean_track)
        fn.append(farm_net)
    return {
        "farm_cases": farm_cases,
        "identity_stake": identity_stake,
        "seeds": seeds,
        "farm_net_cost_xbzz": round(mean(fn), 3),
        "attacker_mean_track": round(mean(mt), 3),
        "freezing_power_gained": round(freezing_power(mean(mt), p), 3),  # 1=none..cap
        "attack_success_farmed": round(mean(sf), 4),
        "attack_success_control": round(mean(sc_), 4),
        "success_uplift": round(mean(upl), 4),
        "success_uplift_sd": round(pstdev(upl) if len(upl) > 1 else 0.0, 4),
    }


def whale_campaign(p: Params, attacker_frac: float = 0.5, honest_track: float = 0.0,
                   n_cases: int = 400, cases_per_day: float = 2.0,
                   seed: int = 1) -> Metrics:
    """A whale attacking unsafe content across a persistent-population CAMPAIGN.

    Unlike the single-case `whale`, freeze bites here: an attacker that loses a
    round is frozen out of later draws, and honest VETERANS (high `honest_track`)
    freeze it for longer (principle 4), so veteran and newcomer honest populations
    now diverge — which they could not in the freeze-inert single-case model.
    """
    rng = random.Random(seed)
    honest_total = 4000.0
    attacker_total = honest_total * attacker_frac / max(1e-9, 1.0 - attacker_frac)
    pop = build_population(rng, honest_total_stake=honest_total, honest_track=honest_track,
                           attacker_total_stake=attacker_total,
                           attacker_target=Outcome.APPROVE)

    def factory(i, r):
        return _make_case("submission", Outcome.REJECT, 0.0, Outcome.APPROVE)

    m = Metrics()
    for res in run_campaign(pop, p, factory, n_cases, rng, cases_per_day=cases_per_day):
        m.add(res, attacker_target=Outcome.APPROVE)
    return m


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
    """Copy-voting / correlated voting: correctness as copy-voter share grows.

    Panels are drawn by sortition (no first-come race); this isolates the effect
    of votes ceasing to be independent, which commit-reveal exists to prevent.
    """
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
