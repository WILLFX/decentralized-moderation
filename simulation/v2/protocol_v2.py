"""Simulation engine for the unassigned architecture (design-v2, state-machine-v2).

The v1 engine in ``moderation_sim/`` models the assigned-panel design and still
validates the contracts in ``contracts/``. This is a separate engine, not a port:
the mechanics differ at the level of what a "round" is.

What this exists to measure, in priority order:

1.  Does pooling actually hold P(attacker verdict) at the attacker's population
    share, across rounds?  (design-v2 §4.5 claims it does.)
2.  Does honest turnout survive dilution?  (design-v2 §4.6 says it might not, and
    that is the one part of the design nobody has stress-tested.)
3.  What fee level keeps turnout near the cohort target?
4.  Where does MAX_ROUNDS have to sit?

The model deliberately gives the attacker every advantage the design admits:
attacker turnout is insensitive to pay (their prize is the listing, external to
the protocol), while honest turnout is a rational response to expected earnings
net of freeze risk. If the design survives that, the asymmetry is priced.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from enum import IntEnum
from typing import List, Optional, Tuple


class Vote(IntEnum):
    REJECT = 0
    APPROVE = 1


@dataclass
class ParamsV2:
    # --- population ---
    n_moderators: int = 1000
    attacker_share: float = 0.30       # q — fraction of identities attacker-controlled

    # --- eligibility (state-machine-v2 §3) ---
    target_cohort: int = 32            # TARGET_COHORT
    min_reveals: int = 5               # MIN_REVEALS
    age_factor_step: float = 1.5       # AGE_FACTOR_STEP
    max_extensions: int = 4            # MAX_EXTENSIONS

    # --- rounds (§4) ---
    max_rounds: int = 4                # MAX_ROUNDS

    # --- money ---
    fee: float = 9.0                   # F, xBZZ. Working: ~6x v1's 1.5 to pay 32.
    claim_bounty_frac: float = 0.01    # β
    gas_cost: float = 0.05             # cost of commit+reveal, xBZZ-equivalent

    # --- penalty (§5) ---
    freeze_base_days: float = 7.0      # FREEZE_BASE
    freeze_cap: float = 4.0
    # Cases a working moderator judges per day. This is what makes a suspension
    # expensive: it removes you from ALL cases, while a reward is for ONE.
    cases_per_day: float = 10.0

    # --- behaviour ---
    # P(an honest moderator reads the case the way the guidelines intend).
    # 0.95 is a clear-cut case; 0.6 is genuinely borderline.
    case_clarity: float = 0.95
    # If True, a loser's freeze scales with how badly they lost: being outvoted
    # 1-31 is a bad judgment, being outvoted 15-17 is bad luck. Proposed fix for
    # the risk/reward result — see FINDINGS-v2.md.
    margin_scaled_freeze: bool = False
    # How far ahead an honest moderator looks when estimating final turnout.
    # 0 = myopic (assumes the case ends this round, over-participates early).
    # 1 = assumes every remaining round happens.
    foresight: float = 0.5
    # An honest moderator challenges only when its side holds at least this share
    # of the pool — challenging into a pool you are losing is -EV.
    honest_challenge_threshold: float = 0.50

    @property
    def pot(self) -> float:
        return self.fee * (1.0 - self.claim_bounty_frac)

    @property
    def pay_per_case(self) -> float:
        """What one case pays a coherent voter at target turnout."""
        return self.pot / self.target_cohort

    @property
    def freeze_cost(self) -> float:
        """Opportunity cost of a suspension, in xBZZ.

        Derived rather than assumed, and the derivation is the whole point:

            freeze_cost = freeze_days x cases_per_day x pay_per_case

        so the ratio of downside to upside is `freeze_days x cases_per_day`, and
        it does NOT move with the fee -- raising the fee raises the reward and the
        foregone earnings by the same factor. No fee level fixes a bad ratio.
        """
        return self.freeze_base_days * self.cases_per_day * self.pay_per_case

    @property
    def risk_reward_ratio(self) -> float:
        """Downside/upside. Voting is rational only when p/(1-p) exceeds this."""
        return self.freeze_base_days * self.cases_per_day


@dataclass
class Moderator:
    idx: int
    attacker: bool
    suspended_until: float = 0.0       # serial accumulator, in days (§5.1)

    def active(self, now: float) -> bool:
        return now >= self.suspended_until

    def suspend(self, now: float, duration: float, cap: float) -> None:
        """Serial stacking: sum of terms, not the max of them."""
        base = max(now, self.suspended_until)
        self.suspended_until = min(now + cap, base + duration)


@dataclass
class RoundLog:
    index: int
    eligible: int
    honest_voted: int
    attacker_voted: int
    pooled_approve: int
    pooled_reject: int
    provisional: Optional[Vote]
    expected_pay: float


@dataclass
class CaseResult:
    truth: Vote                        # what a correct verdict would be
    verdict: Optional[Vote] = None     # None => VOID
    rounds: List[RoundLog] = field(default_factory=list)
    voided: bool = False
    attacker_won: bool = False
    total_votes: int = 0
    pay_per_voter: float = 0.0
    honest_turnout_by_round: List[int] = field(default_factory=list)


def _eligible(pop: List[Moderator], p: ParamsV2, rng: random.Random,
              already_voted: set, now: float, age_factor: float) -> List[Moderator]:
    """Hash eligibility, modelled as an independent Bernoulli per identity.

    state-machine-v2 §3.3: the realized cohort is Binomial, not a fixed target.
    A moderator who has already voted in this case is skipped (§3.4, one vote per
    moderator per CASE), and a suspended one is not eligible at all.
    """
    active = [m for m in pop if m.active(now)]
    if not active:
        return []
    prob = min(1.0, p.target_cohort * age_factor / len(active))
    return [m for m in active
            if m.idx not in already_voted and rng.random() < prob]


def _prior_coherence(p: ParamsV2) -> float:
    """An honest voter's prior that the verdict will match their reading.

    The draw is linear in vote counts, so P(coherent) is the expected share of the
    pool held by their side. Honest moderators are a (1-q) fraction and read the
    case correctly with probability `case_clarity`; the attacker's whole share
    votes the other way.
    """
    return (1.0 - p.attacker_share) * p.case_clarity


def _honest_will_vote(p: ParamsV2, pooled: int, round_idx: int,
                      my_side_share: Optional[float]) -> Tuple[bool, float]:
    """A rational honest moderator's participation decision.

    Expected pay is pot / final-turnout (design-v2 §4.2 — P/N regardless of
    direction). They estimate final turnout; `foresight` is how far ahead they
    look. Against that they weigh the chance of being frozen for landing on the
    wrong side of a probabilistic draw.

    Note what this ratio actually is. A freeze suspends the moderator from EVERY
    case for its duration, while the reward is for ONE case. So the downside is
    roughly `freeze_days x cases_per_day x pay_per_case` and the upside is
    `pay_per_case` -- the ratio scales with throughput, and no fee level changes
    it, because raising the fee raises both sides equally.
    """
    remaining = max(0, p.max_rounds - round_idx - 1)
    projected = pooled + p.target_cohort * (1.0 + p.foresight * remaining)
    expected_pay = p.pot / max(1.0, projected)

    p_coherent = _prior_coherence(p) if my_side_share is None else my_side_share
    penalty = p.freeze_cost
    if p.margin_scaled_freeze:
        # Losing narrowly costs little; losing badly costs the full term. The
        # expected margin for a voter on a side holding share s is (1 - s).
        penalty *= (1.0 - p_coherent)
    utility = p_coherent * expected_pay - (1.0 - p_coherent) * penalty - p.gas_cost
    return utility > 0.0, expected_pay


def run_case(p: ParamsV2, pop: List[Moderator], rng: random.Random,
             now: float = 0.0, truth: Vote = Vote.APPROVE) -> CaseResult:
    """One case, from submission to verdict, under the unassigned design.

    The attacker wants the opposite of `truth` and votes that way whenever
    eligible, regardless of pay. Honest moderators vote `truth` (modulo error)
    and only when it is worth their while.
    """
    res = CaseResult(truth=truth)
    approve = reject = 0
    voted: set = set()
    provisional: Optional[Vote] = None
    extensions = 0
    round_idx = 0
    attacker_side = Vote.REJECT if truth == Vote.APPROVE else Vote.APPROVE

    while round_idx < p.max_rounds:
        age_factor = p.age_factor_step ** extensions
        cohort = _eligible(pop, p, rng, voted, now, age_factor)

        pooled = approve + reject
        h_votes = a_votes = 0
        expected_pay = 0.0

        for m in cohort:
            if m.attacker:
                # Pay-insensitive: the prize is the listing, not the fee.
                voted.add(m.idx)
                a_votes += 1
                if attacker_side == Vote.APPROVE:
                    approve += 1
                else:
                    reject += 1
                continue

            # An honest moderator judges the content, then decides if it pays.
            my_vote = truth if rng.random() < p.case_clarity else Vote(1 - truth)
            mine = approve if my_vote == Vote.APPROVE else reject
            share = (mine / pooled) if pooled else None
            will, expected_pay = _honest_will_vote(p, pooled, round_idx, share)
            if not will:
                continue
            voted.add(m.idx)
            h_votes += 1
            if my_vote == Vote.APPROVE:
                approve += 1
            else:
                reject += 1

        res.honest_turnout_by_round.append(h_votes)

        # §4.4 — below quorum the round extends rather than proceeding.
        if approve + reject < p.min_reveals:
            extensions += 1
            now += 2.0
            if extensions > p.max_extensions:
                res.voided = True
                return res
            continue

        # §4.5 — the verdict is one pooled vote, drawn uniformly.
        n = approve + reject
        provisional = Vote.APPROVE if rng.randrange(n) < approve else Vote.REJECT

        res.rounds.append(RoundLog(
            index=round_idx, eligible=len(cohort), honest_voted=h_votes,
            attacker_voted=a_votes, pooled_approve=approve, pooled_reject=reject,
            provisional=provisional, expected_pay=expected_pay,
        ))

        now += 5.0  # commit + reveal + challenge window, days

        # §4.7 — does anyone challenge? Only a moderator who has not voted, is
        # eligible next round, disagrees, and for whom it is +EV.
        if round_idx + 1 >= p.max_rounds:
            break
        losing_side = Vote(1 - provisional)
        losing_pool = approve if losing_side == Vote.APPROVE else reject
        losing_share = losing_pool / n

        # A challenger must actually be ELIGIBLE for the next round, not merely
        # exist. The first version of this checked only "is there an unused
        # attacker", which with hundreds of identities is always true and
        # overstated the attacker's ability to force rounds. (External review,
        # section 11.)
        next_cohort = _eligible(pop, p, rng, voted, now, age_factor)
        want = [m for m in next_cohort if m.attacker == (losing_side == attacker_side)]

        if losing_side == attacker_side:
            challenged = len(want) > 0          # pay-insensitive, challenges if able
        else:
            challenged = want and losing_share >= p.honest_challenge_threshold

        if not challenged:
            break

        # The challenge IS a vote against the standing verdict, pooled immediately
        # (state-machine-v2 §4.7). The first version opened a round without adding
        # it, so a challenge cost nothing and added nothing.
        challenger = want[0]
        voted.add(challenger.idx)
        if losing_side == Vote.APPROVE:
            approve += 1
        else:
            reject += 1

        round_idx += 1

    # --- settlement (§5) ---
    if provisional is None:
        res.voided = True
        return res

    n = approve + reject
    winners = approve if provisional == Vote.APPROVE else reject
    res.verdict = provisional
    res.total_votes = n
    res.pay_per_voter = p.pot / winners if winners else 0.0
    res.attacker_won = (provisional == attacker_side)

    return res


def build_population(p: ParamsV2, rng: random.Random) -> List[Moderator]:
    n_att = int(round(p.n_moderators * p.attacker_share))
    pop = [Moderator(idx=i, attacker=(i < n_att)) for i in range(p.n_moderators)]
    rng.shuffle(pop)
    for i, m in enumerate(pop):
        m.idx = i
    return pop
