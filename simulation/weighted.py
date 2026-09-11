"""Reliability-weighted aggregation: can we raise the effective `prior` without
raising anybody's `prior`?

`measurement/prior/README.md` records that every safety figure in the design is a
function of `q + (1−q)(1−prior)`. But that `prior` is the mean of the pooled
population **under equal weights**, and equal weighting is a choice. Standard
crowdsourcing practice since Dawid–Skene estimates each rater's reliability and
weights by it; where reliabilities are heterogeneous, that beats majority vote by
a lot. The design already accumulates `track` (§6) and does not use it here.

**What would have to be true for this to work**, tested in that order:

1.  Reliabilities must actually *differ*. If every moderator is 0.665, weighting
    is weighting on estimation noise and must **hurt**. E18 holds the mean fixed
    and sweeps the spread, against an ORACLE that knows every `r_i` exactly —
    the upper bound on what any estimator could deliver.
2.  The estimate must be cheap enough. E19 replaces the oracle with `n_gold`
    observations of known-answer cases.
3.  **The signal must not be farmable.** E20 is the one that decides it. Gold
    cases are indistinguishable from real ones, so an attacker cannot dodge them
    — but he does not need to. He can answer every case honestly *except* the one
    he is attacking, and his measured reliability is then whatever his judgment
    is worth, not what his behaviour is worth. An honest moderator at `prior`
    0.665 cannot score above 0.665; an attacker who knows the truth can score 1.0.
    Weighting would then transfer weight from the honest side to the hostile one.
4.  The gold labels must be right. E21: `measurement/prior` says ground truth has
    to come from outside, and the cheap alternative is to bootstrap it from the
    protocol's own unanimous settlements — which is circular, because at `prior`
    0.665 those are wrong most of the time.

Weight function is the Nitzan–Paroush optimum for combining independent binary
judgments, `w = log(r / (1−r))`, clipped below at zero rather than allowed
negative: a negative weight counts a Reject as an Approve, which is optimal Bayes
and not implementable as a vote-counting rule anyone would accept.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, replace
from typing import List, Optional, Sequence, Tuple

from protocol_v3 import APPROVE, ParamsV3, draw_tickets


# ---------------------------------------------------------------------------
# population
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class WeightParams:
    #: Beta concentration for the honest reliability distribution. The mean is
    #: held at `ParamsV3.honest_prior` so that sweeping this changes the SPREAD
    #: and not the population's average competence — otherwise the experiment
    #: measures "better moderators", which is not what weighting claims to buy.
    #: `None` is the homogeneous population v3 currently assumes.
    concentration: Optional[float] = None

    #: Gold cases observed per moderator before the estimate is used.
    n_gold: int = 50

    #: P(a gold label is actually correct). 1.0 is externally supplied truth;
    #: below that is the bootstrap-from-our-own-settlements shortcut (E21).
    gold_accuracy: float = 1.0

    #: An attacker's accuracy ON GOLD CASES. He votes his attack line on the case
    #: he is attacking and can answer everything else however he likes, so this
    #: is a free parameter of his strategy and not a property of the protocol.
    #: 0.665 is "no better at judging content than anyone else"; 1.0 is "knows
    #: the truth and reports it everywhere it is not the target".
    attacker_gold_accuracy: float = 1.0

    #: Cap on |log-odds| so one identity cannot dominate a cohort.
    weight_cap: float = 3.0

    #: ORACLE mode weights by the true `r_i` — the upper bound on what any
    #: estimator can deliver. Not implementable; it exists to bound the idea.
    oracle: bool = False

    #: Unweighted. Reproduces v3's aggregation exactly.
    unweighted: bool = False


def _logit_weight(r: float, cap: float) -> float:
    r = min(max(r, 1e-6), 1 - 1e-6)
    return max(0.0, min(cap, math.log(r / (1 - r))))


@dataclass
class Population:
    """Identities, their true reliabilities, and the weights the protocol would
    assign them. Built ONCE and reused across cases, because a reliability
    estimate that is redrawn per case is not a reputation."""
    reliability: List[float]
    weight: List[float]
    n_attackers: int

    @staticmethod
    def build(p: ParamsV3, wp: WeightParams, rng: random.Random) -> "Population":
        n, n_att = p.n_moderators, p.n_attackers
        rel: List[float] = []
        for i in range(n):
            if i < n_att:
                rel.append(p.honest_prior)          # unused: attackers vote to plan
            elif wp.concentration is None:
                rel.append(p.honest_prior)
            else:
                k = wp.concentration
                rel.append(rng.betavariate(p.honest_prior * k, (1 - p.honest_prior) * k))

        w: List[float] = []
        for i in range(n):
            if wp.unweighted:
                w.append(1.0)
                continue
            if i < n_att:
                # the attacker's SCORE, not his honesty: he answers gold cases
                # at `attacker_gold_accuracy` and defects only on his target
                true_score = wp.attacker_gold_accuracy
            else:
                true_score = rel[i]
            if wp.oracle:
                w.append(_logit_weight(true_score, wp.weight_cap))
                continue
            # `n_gold` observations, each of which the moderator gets right with
            # probability `true_score`, and each of which is LABELLED correctly
            # with probability `gold_accuracy`. A wrong label inverts the mark.
            hits = 0
            for _ in range(wp.n_gold):
                right = rng.random() < true_score
                if rng.random() >= wp.gold_accuracy:
                    right = not right
                hits += 1 if right else 0
            r_hat = (hits + 1) / (wp.n_gold + 2)      # same Laplace prior as `â`
            w.append(_logit_weight(r_hat, wp.weight_cap))
        return Population(rel, w, n_att)


# ---------------------------------------------------------------------------
# one case
# ---------------------------------------------------------------------------

@dataclass
class WResult:
    terminal: str
    approve_w: float = 0.0
    total_w: float = 0.0
    n: int = 0
    hostile_weight_share: float = 0.0

    @property
    def approved(self) -> bool:
        return self.terminal == "APPROVED"


def run_case_weighted(p: ParamsV3, wp: WeightParams, pop: Population,
                      rng: random.Random, *, content_is_safe: bool,
                      attacker_wants: bool = APPROVE) -> WResult:
    """One case. Structurally identical to `protocol_v3.run_case` at round 0 with
    §4.8b's gate removed; the only change is that `â` is computed over weights
    instead of counts.

    Weights are **normalized to mean 1 over this case's revealers**, so the
    weighted total equals `N` and `(WA + 1)/(WN + 2)` keeps the same Laplace
    correction §4.5 derives. Without that the prior's strength would drift with
    the cohort's average competence, which would confound every comparison here.
    """
    n, n_att = p.n_moderators, pop.n_attackers
    prob = min(1.0, p.target_cohort / n)

    idx: List[int] = []
    for i in range(n):
        avail = p.attacker_always_on if i < n_att else p.honest_availability
        if rng.random() < prob and rng.random() < avail:
            idx.append(i)

    if not idx:
        return WResult("UNRESOLVED")

    raw = [pop.weight[i] for i in idx]
    tot = sum(raw)
    if tot <= 0.0:
        # every revealer was estimated at or below chance and clipped to zero.
        # Falling back to unweighted is the only non-arbitrary choice: refusing
        # to decide would hand a censor a free veto.
        norm = [1.0] * len(idx)
    else:
        norm = [len(idx) * x / tot for x in raw]

    wa = wn = hostile_w = 0.0
    for i, w in zip(idx, norm):
        if i < n_att:
            vote = attacker_wants
            hostile_w += w
        else:
            correct = rng.random() < pop.reliability[i]
            vote = content_is_safe if correct else not content_is_safe
        if vote is APPROVE:
            wa += w
        wn += w

    a_hat = (wa + 1.0) / (wn + 2.0)
    u = draw_tickets(rng)
    final = sum(1 for x in u if x < a_hat) >= 2
    return WResult("APPROVED" if final else "REJECTED", wa, wn, len(idx),
                   hostile_w / wn if wn else 0.0)


@dataclass
class WStats:
    approved: float
    unresolved: float
    mean_n: float
    hostile_weight: float          # hostile share of WEIGHT in the tally
    hostile_head: float            # hostile share of HEADS, for comparison


def measure(p: ParamsV3, wp: WeightParams, *, safe: bool,
            wants: bool = APPROVE, trials: int, seed: int) -> WStats:
    rng = random.Random(seed)
    pop = Population.build(p, wp, random.Random(seed ^ 0x5EED))
    ok = un = 0
    heads = hostile_heads = 0
    hw = 0.0
    for _ in range(trials):
        r = run_case_weighted(p, wp, pop, rng, content_is_safe=safe,
                              attacker_wants=wants)
        if r.terminal == "UNRESOLVED":
            un += 1
            continue
        ok += 1 if r.approved else 0
        hw += r.hostile_weight_share
        heads += r.n
    res = trials - un
    # head share is a property of the population and the draw, not of weighting;
    # reported so the weight column can be read against something fixed
    exp_head = p.attacker_share * p.attacker_always_on / (
        p.attacker_share * p.attacker_always_on
        + (1 - p.attacker_share) * p.honest_availability)
    return WStats(ok / res if res else float("nan"), un / trials,
                  heads / res if res else float("nan"),
                  hw / res if res else float("nan"), exp_head)


def spread_of(p: ParamsV3, wp: WeightParams, seed: int = 7) -> float:
    """SD of the honest reliability distribution, so a concentration parameter
    can be reported as something a reader can picture."""
    if wp.concentration is None:
        return 0.0
    m, k = p.honest_prior, wp.concentration
    return math.sqrt(m * (1 - m) / (k + 1))
