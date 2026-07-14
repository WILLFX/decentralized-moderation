"""Core protocol engine: the case lifecycle from ``specs/state-machine.md`` §5.

The engine plays one full case (submission or removal) through commit -> reveal
-> tally -> probabilistic draw -> appeal ladder -> settlement, over a population
of moderators. It records everything a scenario needs to price an attack:
who won, whether the outcome matched honest judgment, how much every faction
spent (fees + forfeited bonds), how much honest moderators earned, and how much
attacker capital got frozen and for how long.

Faithfulness notes (where the sim abstracts the chain):
  * Commit-reveal is modeled by its effect: votes are independent and hidden
    until tally. Copy-voting is modeled explicitly as a strategy, not via
    leaked commits.
  * Subset eligibility (1-10%) followed by "first-N-commits-count" collapses,
    under the assumption that response speed is independent of stake, to a
    single stake-weighted draw of the counted voters. That is what we sample.
  * Identity splitting is neutral by protocol design (stake-weighted draws), so
    each faction's attacker capital is modeled as its total stake rather than a
    number of identities. ``tests/`` asserts the neutrality we rely on.
  * "Stake behind each side" is configurable via ``Params.weight_policy``
    (spec open question §11.6).
"""

from __future__ import annotations

import math
import random
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

    def available_stake(self, now: float) -> float:
        return 0.0 if self.is_frozen(now) else self.stake


@dataclass
class _Round:
    depth: int
    counted: List[Moderator] = field(default_factory=list)
    votes: Dict[int, Outcome] = field(default_factory=dict)  # mod id -> revealed vote
    approve_weight: float = 0.0
    reject_weight: float = 0.0
    outcome: Optional[Outcome] = None
    bond: float = 0.0                 # bond that opened this round (0 at depth 0)
    appellant: Optional[Moderator] = None
    appellant_for: Optional[Outcome] = None  # the outcome the appellant argued for
    total_reward: float = 0.0         # basis for next bond floor


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
    # money flows, keyed by faction
    fees_paid: Dict[str, float] = field(default_factory=dict)
    bonds_forfeited: Dict[str, float] = field(default_factory=dict)
    rewards_earned: Dict[str, float] = field(default_factory=dict)
    # freeze pressure applied, keyed by faction: sum of stake*days frozen
    freeze_stake_days: Dict[str, float] = field(default_factory=dict)
    n_frozen: Dict[str, int] = field(default_factory=dict)
    uncontested: bool = False          # index field: no reject vote and never appealed


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def freezing_power(track_sum: float, p: Params) -> float:
    """Winning side's freeze multiplier from its aggregate track record.

    Saturating curve from 1 (newcomers) up to FREEZE_CAP (established veterans),
    realizing design principle 4. Exact shape is a simulation deliverable; this
    is a defensible default (spec §6.4, §11.3).
    """
    if track_sum <= 0:
        return 1.0
    frac = 1.0 - math.exp(-track_sum / p.track_saturation)
    return 1.0 + (p.freeze_cap - 1.0) * frac


def _weight(mod: Moderator, p: Params) -> float:
    if p.weight_policy == "whole":
        return mod.stake
    if p.weight_policy == "fixed":
        return p.fixed_weight
    if p.weight_policy == "capped":
        return min(mod.stake, p.weight_cap)
    raise ValueError(f"unknown weight_policy {p.weight_policy!r}")


def _weighted_sample_without_replacement(
    pool: List[Moderator], k: int, rng: random.Random
) -> List[Moderator]:
    """Efraimidis-Spirakis A-Res: draw k items with prob proportional to stake."""
    if k >= len(pool):
        return list(pool)
    keyed = []
    for m in pool:
        w = max(m.stake, 1e-12)
        # key = u^(1/w); larger stake -> key closer to 1 -> more likely selected
        key = rng.random() ** (1.0 / w)
        keyed.append((key, m.id, m))
    keyed.sort(reverse=True)
    return [m for _, _, m in keyed[:k]]


def _draw_outcome(approve_w: float, reject_w: float, rng: random.Random) -> Outcome:
    """Stake-proportional probabilistic outcome (spec §0)."""
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
        k = target + widen * target  # widening enlarges the counted set
        counted = _weighted_sample_without_replacement(eligible, k, rng)
        # commit -> reveal: some committers fail to reveal (liveness)
        revealed = [m for m in counted if rng.random() < m.reveal_prob]
        if len(revealed) >= p.min_reveals or widen >= p.max_widen:
            break
        widen += 1
        case.now += p.appeal_window_days[0] / 4.0  # small delay per widen

    r.counted = revealed
    # Votes are processed in arrival order so that strategies modeling a broken
    # commit-reveal (copy-voting / racing, README §7) can read the running tally
    # via ``case.partial_votes``. Honest strategies ignore it, matching the
    # independence that a working commit-reveal guarantees.
    case.partial_votes = []
    for m in revealed:
        vote = (m.vote_fn or honest_vote)(m, case, rng)
        case.partial_votes.append(vote)
        r.votes[m.id] = vote
        w = _weight(m, p)
        if vote == Outcome.APPROVE:
            r.approve_weight += w
        else:
            r.reject_weight += w
    r.outcome = _draw_outcome(r.approve_weight, r.reject_weight, rng)
    # A round's "reward" basis (for the next bond floor) is the pot it would
    # distribute; approximated here by the winning-side stake in the round.
    r.total_reward = r.approve_weight if r.outcome == Outcome.APPROVE else r.reject_weight
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
    """Play one case to settlement and return the accounting.

    ``appeal_policy`` decides who (if anyone) appeals a round's provisional
    outcome, returning the appellant Moderator or None. Defaults to
    :func:`default_appeal_policy`.
    """
    if appeal_policy is None:
        appeal_policy = default_appeal_policy

    case.fee = max(case.fee, p.min_fee(case.n_topics))
    pot = case.fee
    fees_paid: Dict[str, float] = {case.submitter_faction: case.fee}

    # depth 0
    r0 = _run_round(case, pop, 0, p, rng)
    case.rounds.append(r0)
    case.now += p.appeal_window_days[0]
    uncontested = (r0.reject_weight == 0.0)

    # appeal ladder
    depth = 0
    while depth < p.max_depth:
        r = case.rounds[-1]
        appellant = appeal_policy(case, r, pop, p, rng)
        if appellant is None:
            break
        uncontested = False
        bond = max(p.bond_multiplier * r.total_reward, p.min_fee(case.n_topics))
        pot += bond
        depth += 1
        nr = _run_round(case, pop, depth, p, rng)
        nr.bond = bond
        nr.appellant = appellant
        # the appellant argues for the opposite of the outcome being appealed
        nr.appellant_for = Outcome(1 - int(r.outcome))
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
        fees_paid=fees_paid,
        uncontested=uncontested,
    )
    _settle(case, p, pot, result)
    return result


def default_appeal_policy(case: Case, r: _Round, pop: List[Moderator],
                          p: Params, rng: random.Random) -> Optional[Moderator]:
    """Rational, EV-aware re-appeals of an overturnable wrong outcome.

    An appellant only bonds when its own side actually showed strength in the
    round just decided — measured by that side's revealed stake share. Appealing
    an outcome your side barely contested is negative expected value: the bond is
    just forfeited to the winners. This is why a dominant whale earns *nothing*
    from honest appellants — they rationally decline to appeal a round they were
    crushed in, so no bonds flow to the attacker (README §3.6, §4).
    """
    outcome = r.outcome
    bond = max(p.bond_multiplier * r.total_reward, p.min_fee(case.n_topics))
    total_w = r.approve_weight + r.reject_weight
    if total_w <= 0:
        return None

    def side_share(side: Outcome) -> float:
        w = r.approve_weight if side == Outcome.APPROVE else r.reject_weight
        return w / total_w

    # honest side wants the honest label; appeals only if it looks overturnable
    if outcome != case.honest_label and side_share(case.honest_label) >= p.honest_appeal_threshold:
        challengers = [m for m in pop
                       if m.faction == "honest" and not m.is_frozen(case.now)
                       and m.stake >= bond]
        if challengers:
            return max(challengers, key=lambda m: m.stake)

    # attacker pushes its target; same EV gate on its own revealed strength
    tgt = case.attacker_target
    if tgt is not None and outcome != tgt and side_share(tgt) >= p.attacker_appeal_threshold:
        attackers = [m for m in pop
                     if m.faction == "attacker" and not m.is_frozen(case.now)
                     and m.stake >= bond]
        if attackers:
            return max(attackers, key=lambda m: m.stake)

    return None


# ---------------------------------------------------------------------------
# settlement (spec §6)
# ---------------------------------------------------------------------------

def _settle(case: Case, p: Params, pot: float, result: CaseResult) -> None:
    final = case.final_outcome
    assert final is not None

    # 1. winning/losing appellants: refund+bonus, or forfeit into the pot.
    #    A vindicated appellant gets its bond back (its own capital, not a
    #    reward) plus a bonus; its bond must therefore leave the distributable
    #    pot. A losing appellant's bond stays in the pot and is its cost.
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
            # bond forfeited into the pot (already added to pot at appeal time)
            _bump(result.bonds_forfeited, r.appellant.faction, r.bond)

    # 2. claim bounty off the top
    claim_bounty = p.claim_bounty_frac * pot
    distributable = max(pot - refunded_bonds - winning_appellant_bonus - claim_bounty, 0.0)

    # 3. coherent voters split the remaining pot in proportion to coherent stake
    coherent_weight_by_mod: Dict[int, float] = {}
    coherent_mods: Dict[int, Moderator] = {}
    winners_track_sum = 0.0
    total_coherent = 0.0
    for r in case.rounds:
        for m in r.counted:
            v = r.votes.get(m.id)
            if v is None:
                continue
            if v == final:
                w = _weight(m, p)
                coherent_weight_by_mod[m.id] = coherent_weight_by_mod.get(m.id, 0.0) + w
                coherent_mods[m.id] = m
                total_coherent += w
    for mid, w in coherent_weight_by_mod.items():
        m = coherent_mods[mid]
        winners_track_sum += m.track
    if total_coherent > 0:
        for mid, w in coherent_weight_by_mod.items():
            m = coherent_mods[mid]
            reward = distributable * (w / total_coherent)
            m.earnings += reward
            _bump(result.rewards_earned, m.faction, reward)
            # track record: coherent + undisputed (approximate: coherent overall)
            m.track = m.track * p.track_decay + 1.0

    # 4. freeze incoherent voters (spec §6.4). No stake transfer — locked only.
    power = freezing_power(winners_track_sum, p)
    freeze_days = p.freeze_base_days * power
    seen = set()
    for r in case.rounds:
        for m in r.counted:
            if m.id in seen:
                continue
            v = r.votes.get(m.id)
            if v is None:
                continue
            if v != final:
                seen.add(m.id)
                m.frozen_until = max(m.frozen_until, case.now + freeze_days)
                _bump(result.freeze_stake_days, m.faction, m.stake * freeze_days)
                result.n_frozen[m.faction] = result.n_frozen.get(m.faction, 0) + 1
                # incoherent: decay track, no increment
                m.track *= p.track_decay


def _bump(d: Dict[str, float], key: str, amt: float) -> None:
    d[key] = d.get(key, 0.0) + amt
