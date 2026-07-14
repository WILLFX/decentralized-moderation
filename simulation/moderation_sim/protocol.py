"""Core protocol engine: the case lifecycle from ``specs/state-machine.md`` §5.

The engine plays one full case (submission or removal) through selection ->
commit-reveal -> tally -> probabilistic draw -> appeal ladder -> settlement, over
a population of moderators. It records everything a scenario needs to price an
attack: who won, whether the outcome matched honest judgment, how much every
faction spent (fees + forfeited bonds), how much honest moderators earned, and
how much attacker capital got frozen and for how long.

Selection / voting model (post-review decision — see design log). Stake buys a
moderator *one* benefit, not two:

  * SELECTION is stake-weighted **with replacement**: the round has N counted
    seats, and each seat is drawn in proportion to stake, so a large stake can
    hold several seats (Kleros sortition). Splitting a stake into many identities
    is neutral — expected seats track total stake however it is sliced.
  * VOTING is **flat**: every seat is worth exactly one vote. The outcome is
    drawn with probability proportional to the *seat counts* behind each side.

This removes the earlier double-count (stake-weighted selection AND a
stake-weighted tally), which over-represented and over-weighted the same whale.
Stake now matters exactly once, through how many seats it wins.

Faithfulness notes (where the sim abstracts the chain):
  * Commit-reveal is modeled by its effect: votes are independent and hidden
    until tally. Copy-voting is modeled explicitly as a strategy (agents.py).
  * A drawn seat whose holder does not reveal is dropped (liveness); if too few
    seats reveal, the panel is re-drawn larger (spec §5.2 widen path).
"""

from __future__ import annotations

import math
import random
from collections import Counter
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Dict, List, Optional

from .params import Params


class Outcome(IntEnum):
    REJECT = 0
    APPROVE = 1


# A strategy decides a moderator's vote given the case's honest label and
# difficulty. It returns an Outcome. rng is passed for stochastic strategies.
VoteFn = Callable[["Moderator", "Case", random.Random], Outcome]


@dataclass
class Moderator:
    id: int
    stake: float
    faction: str = "honest"           # "honest" | "attacker" | "lazy" | ...
    track: float = 0.0                # decayed, capped participation count
    frozen_until: float = 0.0         # sim-day timestamp
    earnings: float = 0.0             # cumulative external reward credited
    vote_fn: Optional[VoteFn] = None  # how this moderator votes
    reveal_prob: float = 1.0          # P(reveals after committing); models liveness

    def is_frozen(self, now: float) -> bool:
        return self.frozen_until > now


@dataclass
class _Round:
    depth: int
    seats: Dict[int, int] = field(default_factory=dict)      # mod id -> seat count
    mods: Dict[int, Moderator] = field(default_factory=dict)  # mod id -> Moderator
    votes: Dict[int, Outcome] = field(default_factory=dict)   # mod id -> revealed vote
    approve_seats: int = 0
    reject_seats: int = 0
    outcome: Optional[Outcome] = None
    bond: float = 0.0                 # bond that opened this round (0 at depth 0)
    appellant: Optional[Moderator] = None
    appellant_for: Optional[Outcome] = None  # the outcome the appellant argued for


@dataclass
class Case:
    kind: str                          # "submission" | "removal"
    honest_label: Outcome              # what a neutral reader of the guidelines decides
    difficulty: float                  # 0 = clear-cut, ->1 = borderline (honest error rate)
    n_topics: int = 1
    submitter_faction: str = "creator"
    fee: float = 0.0
    rounds: List[_Round] = field(default_factory=list)
    final_outcome: Optional[Outcome] = None
    now: float = 0.0                   # sim-day clock, advanced per phase
    attacker_target: Optional[Outcome] = None  # outcome an attacker faction pushes
    partial_votes: List[Outcome] = field(default_factory=list)  # votes so far this round


@dataclass
class CaseResult:
    final_outcome: Outcome
    honest_label: Outcome
    correct: bool                      # final outcome == honest judgment
    depth_reached: int
    pot: float
    latency_days: float
    disputed: bool = False             # any appeal opened
    fees_paid: Dict[str, float] = field(default_factory=dict)
    bonds_forfeited: Dict[str, float] = field(default_factory=dict)
    rewards_earned: Dict[str, float] = field(default_factory=dict)
    freeze_stake_days: Dict[str, float] = field(default_factory=dict)
    n_frozen: Dict[str, int] = field(default_factory=dict)
    op_costs: Dict[str, float] = field(default_factory=dict)  # operating cost of judging
    uncontested: bool = False          # index field: no reject vote and never appealed


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def freezing_power(mean_track: float, p: Params) -> float:
    """Winning side's freeze multiplier from its aggregate track record.

    Takes the **seat-weighted mean** track of the winning side, not the sum, so
    it is neutral to identity-splitting: dividing one moderator's history across
    many identities cannot inflate an average. Saturating curve from 1
    (newcomers) up to FREEZE_CAP (established veterans), realizing design
    principle 4 (spec §6.4). Curve shape and saturation chosen by simulation.
    """
    if mean_track <= 0:
        return 1.0
    frac = 1.0 - math.exp(-mean_track / p.track_saturation)
    return 1.0 + (p.freeze_cap - 1.0) * frac


def _draw_seats(pool: List[Moderator], k: int, rng: random.Random) -> Counter:
    """Draw k seats stake-weighted WITH replacement. Returns mod.id -> seat count.

    A moderator may win several seats in proportion to stake. Splitting a stake
    into many identities is neutral in expectation: total selection weight is the
    summed stake either way.
    """
    if not pool or k <= 0:
        return Counter()
    weights = [max(m.stake, 1e-12) for m in pool]
    drawn = rng.choices(pool, weights=weights, k=k)
    return Counter(m.id for m in drawn)


def _draw_outcome(approve_w: float, reject_w: float, rng: random.Random) -> Outcome:
    """Seat-proportional probabilistic outcome (spec §0)."""
    total = approve_w + reject_w
    if total <= 0:
        return Outcome.REJECT
    return Outcome.APPROVE if rng.random() * total < approve_w else Outcome.REJECT


# ---------------------------------------------------------------------------
# one round
# ---------------------------------------------------------------------------

def _run_round(case: Case, pop: List[Moderator], depth: int,
               p: Params, rng: random.Random) -> _Round:
    r = _Round(depth=depth)
    target = p.counted_target(depth)
    widen = 0
    while True:
        eligible = [m for m in pop if not m.is_frozen(case.now)]
        by_id = {m.id: m for m in eligible}
        k = target + widen * target  # widening enlarges the counted panel
        seat_counts = _draw_seats(eligible, k, rng)
        # commit -> reveal: a seat's holder reveals with reveal_prob; unrevealed
        # seats are dropped (liveness).
        revealed_seats: Dict[int, int] = {}
        for mid, cnt in seat_counts.items():
            if rng.random() < by_id[mid].reveal_prob:
                revealed_seats[mid] = cnt
        total_revealed = sum(revealed_seats.values())
        if total_revealed >= p.min_reveals or widen >= p.max_widen:
            r.seats = revealed_seats
            r.mods = {mid: by_id[mid] for mid in revealed_seats}
            break
        widen += 1
        case.now += p.appeal_window_days[0] / 4.0  # small delay per widen

    # Votes are processed in seat-draw order so strategies modeling a broken
    # commit-reveal (copy-voting / racing) can read the running tally via
    # ``case.partial_votes``. Honest strategies ignore it, matching the
    # independence a working commit-reveal guarantees.
    case.partial_votes = []
    for mid, cnt in r.seats.items():
        m = r.mods[mid]
        vote = (m.vote_fn or honest_vote)(m, case, rng)
        r.votes[mid] = vote
        case.partial_votes.append(vote)
        if vote == Outcome.APPROVE:
            r.approve_seats += cnt
        else:
            r.reject_seats += cnt
    r.outcome = _draw_outcome(r.approve_seats, r.reject_seats, rng)
    return r


# ---------------------------------------------------------------------------
# default strategies (see agents.py for the richer set)
# ---------------------------------------------------------------------------

def honest_vote(mod: Moderator, case: Case, rng: random.Random) -> Outcome:
    """Vote the honest label, with an error rate that grows with difficulty."""
    err = 0.02 + 0.4 * case.difficulty      # clear-cut ~2%, fully borderline ~42%
    if rng.random() < err:
        return Outcome(1 - int(case.honest_label))
    return case.honest_label


# ---------------------------------------------------------------------------
# full case
# ---------------------------------------------------------------------------

def run_case(
    pop: List[Moderator],
    p: Params,
    case: Case,
    rng: random.Random,
    appeal_policy: Optional[Callable[[Case, _Round, List[Moderator], Params, random.Random],
                                     Optional[Moderator]]] = None,
) -> CaseResult:
    """Play one case to settlement and return the accounting."""
    if appeal_policy is None:
        appeal_policy = default_appeal_policy

    case.fee = max(case.fee, p.min_fee(case.n_topics))
    pot = case.fee
    fees_paid: Dict[str, float] = {case.submitter_faction: case.fee}

    # depth 0
    r0 = _run_round(case, pop, 0, p, rng)
    case.rounds.append(r0)
    case.now += p.appeal_window_days[0]
    uncontested = (r0.reject_seats == 0)
    disputed = False

    # appeal ladder — bonds escalate with the pot (>= bond_multiplier x pot).
    depth = 0
    while depth < p.max_depth:
        r = case.rounds[-1]
        appellant = appeal_policy(case, r, pop, p, rng)
        if appellant is None:
            break
        uncontested = False
        disputed = True
        bond = max(p.bond_multiplier * pot, p.min_fee(case.n_topics))
        pot += bond
        depth += 1
        nr = _run_round(case, pop, depth, p, rng)
        nr.bond = bond
        nr.appellant = appellant
        nr.appellant_for = Outcome(1 - int(r.outcome))  # argues against the appealed outcome
        case.rounds.append(nr)
        case.now += p.appeal_window_days[min(depth, len(p.appeal_window_days) - 1)]

    final = case.rounds[-1].outcome
    case.final_outcome = final

    result = CaseResult(
        final_outcome=final,
        honest_label=case.honest_label,
        correct=(final == case.honest_label),
        depth_reached=len(case.rounds) - 1,
        pot=pot,
        latency_days=case.now,
        disputed=disputed,
        fees_paid=fees_paid,
        uncontested=uncontested,
    )
    _settle(case, p, pot, result)
    return result


def default_appeal_policy(case: Case, r: _Round, pop: List[Moderator],
                          p: Params, rng: random.Random) -> Optional[Moderator]:
    """Rational, EV-aware re-appeals of an overturnable wrong outcome.

    An appellant bonds only when its own side showed real strength in the round
    just decided, measured by that side's **seat share**. Appealing a round your
    side was crushed in is negative expected value: the bond is just forfeited to
    the winners. This is why a dominant whale earns *nothing* from honest
    appellants — they rationally decline to appeal a lost cause (README §3.6, §4).
    """
    outcome = r.outcome
    total = r.approve_seats + r.reject_seats
    if total <= 0:
        return None
    # bond floor matches run_case: escalates with the current pot
    bond = max(p.bond_multiplier * _pot_so_far(case), p.min_fee(case.n_topics))

    def side_share(side: Outcome) -> float:
        s = r.approve_seats if side == Outcome.APPROVE else r.reject_seats
        return s / total

    if outcome != case.honest_label and side_share(case.honest_label) >= p.honest_appeal_threshold:
        challengers = [m for m in pop
                       if m.faction == "honest" and not m.is_frozen(case.now)
                       and m.stake >= bond]
        if challengers:
            return max(challengers, key=lambda m: m.stake)

    tgt = case.attacker_target
    if tgt is not None and outcome != tgt and side_share(tgt) >= p.attacker_appeal_threshold:
        attackers = [m for m in pop
                     if m.faction == "attacker" and not m.is_frozen(case.now)
                     and m.stake >= bond]
        if attackers:
            return max(attackers, key=lambda m: m.stake)

    return None


def _pot_so_far(case: Case) -> float:
    return case.fee + sum(rr.bond for rr in case.rounds)


# ---------------------------------------------------------------------------
# settlement (spec §6)
# ---------------------------------------------------------------------------

def _settle(case: Case, p: Params, pot: float, result: CaseResult) -> None:
    final = case.final_outcome
    assert final is not None

    # 1. winning/losing appellants: refund+bonus, or forfeit into the pot.
    winning_appellant_bonus = 0.0
    refunded_bonds = 0.0
    for r in case.rounds:
        if r.appellant is None:
            continue
        if r.appellant_for == final:
            refunded_bonds += r.bond               # returned to appellant, off-pot
            bonus = p.winning_appellant_bonus_frac * pot
            winning_appellant_bonus += bonus
            r.appellant.earnings += bonus
            _bump(result.rewards_earned, r.appellant.faction, bonus)
        else:
            _bump(result.bonds_forfeited, r.appellant.faction, r.bond)

    # 2. claim bounty off the top
    claim_bounty = p.claim_bounty_frac * pot
    distributable = max(pot - refunded_bonds - winning_appellant_bonus - claim_bounty, 0.0)

    # 3. coherent voters split the pot in proportion to their COHERENT SEATS
    #    (flat per seat — no stake weighting; stake already paid off in selection).
    coherent_seats: Dict[int, int] = {}
    coherent_mods: Dict[int, Moderator] = {}
    for r in case.rounds:
        for mid, cnt in r.seats.items():
            if r.votes.get(mid) == final:
                coherent_seats[mid] = coherent_seats.get(mid, 0) + cnt
                coherent_mods[mid] = r.mods[mid]
    total_coherent = sum(coherent_seats.values())

    # winners' aggregate track = seat-weighted mean (split-resistant, spec §6.4)
    if total_coherent > 0:
        winners_mean_track = sum(coherent_mods[mid].track * s
                                 for mid, s in coherent_seats.items()) / total_coherent
    else:
        winners_mean_track = 0.0

    undisputed = not result.disputed
    for mid, s in coherent_seats.items():
        m = coherent_mods[mid]
        reward = distributable * (s / total_coherent) if total_coherent else 0.0
        m.earnings += reward
        _bump(result.rewards_earned, m.faction, reward)
        # track accrues only on coherent + undisputed + at/above stake floor
        # participations (anti-farming, spec §6.5). Others just decay.
        if undisputed and m.stake >= p.min_stake:
            m.track = m.track * p.track_decay + 1.0
        else:
            m.track *= p.track_decay

    # 3b. operating cost: every moderator that judged the case pays its per-vote
    #     cost once per round it was drawn into (it evaluates the content to
    #     vote). Reduces its earnings; tracked for the fee-floor model (costs.py).
    if p.op_cost_per_vote > 0:
        for r in case.rounds:
            for mid in r.seats:
                if r.votes.get(mid) is not None:
                    m = r.mods[mid]
                    m.earnings -= p.op_cost_per_vote
                    _bump(result.op_costs, m.faction, p.op_cost_per_vote)

    # 4. freeze incoherent voters (spec §6.4). No stake transfer — locked only.
    power = freezing_power(winners_mean_track, p)
    freeze_days = p.freeze_base_days * power
    seen = set()
    for r in case.rounds:
        for mid in r.seats:
            if mid in seen:
                continue
            if r.votes.get(mid) is not None and r.votes[mid] != final:
                seen.add(mid)
                m = r.mods[mid]
                m.frozen_until = max(m.frozen_until, case.now + freeze_days)
                _bump(result.freeze_stake_days, m.faction, m.stake * freeze_days)
                result.n_frozen[m.faction] = result.n_frozen.get(m.faction, 0) + 1
                m.track *= p.track_decay


def _bump(d: Dict[str, float], key: str, amt: float) -> None:
    d[key] = d.get(key, 0.0) + amt
