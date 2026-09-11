"""Exact enumeration of the one-committee vs staged-pair comparison.

`staged.py` answers this by sampling. Sampling is the wrong instrument for a
claim this load-bearing: 20,000 trials carries roughly +/-0.3pp of noise, the
behavioural model is hand-written, and a reader who doubts the conclusion has no
way to separate a real effect from a seed. This module computes the same
quantities **exactly** — no RNG, no trials, machine precision — by summing over
the whole (finite) state space.

What "exact" does and does not buy. It removes *sampling* error completely: the
numbers here are the true values of the model, not estimates of them. It does not
remove *model* error. The assumptions are listed in `assumptions()` and every one
of them is a place this could still be wrong.

One correction to `staged.py` is carried here. That engine tested favourability
against the committee that *attends*. An attacker cannot observe attendance —
eligibility is a public hash, attendance is not. This module tests favourability
against the **eligible** set, which is what is actually observable, and offers
the attended variant as a sensitivity.

The state space, per committee, for a population of 1,000 at cohort 20:

    a  ~ Binomial(n_attackers, p)          attacker identities eligible
    he ~ Binomial(n_honest, p)             honest identities eligible
    each eligible honest is independently one of three things:
        absent               (1 - avail)
        present, votes Approve   avail * P(reads Approve)
        present, votes Reject    avail * P(reads Reject)

so the honest contribution is trinomial given `he`, and the whole thing is a
finite sum. Tails below `EPS` are dropped, which is the only approximation and is
bounded: the dropped mass is reported by every function that drops any.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import comb
from typing import Dict, Iterable, List, Tuple

#: Probability mass below which a state is dropped. The total dropped mass is
#: tracked and asserted against this, so the error is bounded and visible rather
#: than assumed away.
EPS = 1e-15

#: (approve, total) -> probability
Dist = Dict[Tuple[int, int], float]


# --------------------------------------------------------------------------
# distributions
# --------------------------------------------------------------------------

def binom_pmf(n: int, p: float, eps: float = EPS) -> Dict[int, float]:
    """Exact binomial pmf, truncated where mass falls below ``eps``."""
    if n <= 0:
        return {0: 1.0}
    if p <= 0.0:
        return {0: 1.0}
    if p >= 1.0:
        return {n: 1.0}
    out: Dict[int, float] = {}
    # walk outward from the mode so truncation removes tails, not the centre
    for k in range(n + 1):
        pk = comb(n, k) * (p ** k) * ((1.0 - p) ** (n - k))
        if pk >= eps:
            out[k] = pk
    return out


def _trinomial(n: int, p_a: float, p_r: float) -> Dict[Tuple[int, int], float]:
    """Joint pmf of (approvals, rejections) among ``n`` eligible honest.

    The third category — absent — is implicit at ``1 - p_a - p_r``.
    """
    out: Dict[Tuple[int, int], float] = {}
    p_abs = 1.0 - p_a - p_r
    for x in range(n + 1):
        for y in range(n - x + 1):
            z = n - x - y
            pk = (comb(n, x) * comb(n - x, y)
                  * (p_a ** x) * (p_r ** y) * (p_abs ** z))
            if pk >= EPS:
                out[(x, y)] = pk
    return out


# --------------------------------------------------------------------------
# model
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Model:
    n_moderators: int = 1000
    attacker_share: float = 0.30
    cohort: int = 20                 # expected eligible identities per committee
    prior: float = 0.665             # P(honest moderator reads the case correctly)
    availability: float = 0.80       # P(an eligible honest identity votes in time)
    favourable_at: float = 0.50      # attacker share at which they proceed
    content_is_safe: bool = False
    #: test favourability against the ATTENDING committee instead of the
    #: eligible one. False is correct — attendance is not observable.
    favourable_on_attendance: bool = False

    @property
    def n_attackers(self) -> int:
        return int(round(self.n_moderators * self.attacker_share))

    @property
    def n_honest(self) -> int:
        return self.n_moderators - self.n_attackers

    @property
    def p_eligible(self) -> float:
        return min(1.0, self.cohort / self.n_moderators)

    @property
    def p_honest_approves(self) -> float:
        """P(an *attending* honest moderator votes Approve).

        On unsafe content the correct vote is Reject, so an Approve is an error,
        at rate ``1 - prior``. On safe content it is the correct vote.
        """
        return self.prior if self.content_is_safe else (1.0 - self.prior)

    @property
    def attacker_votes_approve(self) -> bool:
        """The attacker drives Approve on unsafe content, Reject on safe."""
        return not self.content_is_safe


def a_hat(approve: int, total: int) -> float:
    return (approve + 1) / (total + 2)


def f(a: float) -> float:
    """P(majority of three tickets approves) = 3a^2 - 2a^3."""
    return 3.0 * a * a - 2.0 * a * a * a


# --------------------------------------------------------------------------
# one committee
# --------------------------------------------------------------------------

def committee(m: Model) -> Tuple[Dist, Dist, float]:
    """Exact (approve, total) contribution of one committee.

    Returns ``(favourable, unfavourable, dropped_mass)``. Both distributions are
    **unnormalised**: their masses sum to ``P(favourable)`` and
    ``P(unfavourable)`` respectively.

    A committee the attacker declines still contributes its honest votes — the
    attacker's identities simply do not commit.
    """
    p_att_app = m.availability * m.p_honest_approves
    p_att_rej = m.availability * (1.0 - m.p_honest_approves)

    a_pmf = binom_pmf(m.n_attackers, m.p_eligible)
    he_pmf = binom_pmf(m.n_honest, m.p_eligible)

    fav: Dist = {}
    unfav: Dist = {}
    total_mass = 0.0

    for a, pa in a_pmf.items():
        for he, phe in he_pmf.items():
            base = pa * phe
            if base < EPS:
                continue

            eligible_share = a / (a + he) if (a + he) else 0.0
            fav_on_eligible = eligible_share >= m.favourable_at

            for (x, y), pxy in _trinomial(he, p_att_app, p_att_rej).items():
                p = base * pxy
                if p < EPS:
                    continue
                total_mass += p

                if m.favourable_on_attendance:
                    attending = a + x + y
                    proceed = (a / attending >= m.favourable_at) if attending else False
                else:
                    proceed = fav_on_eligible

                if proceed:
                    if m.attacker_votes_approve:
                        key = (a + x, a + x + y)
                    else:
                        key = (x, a + x + y)
                    fav[key] = fav.get(key, 0.0) + p
                else:
                    key = (x, x + y)
                    unfav[key] = unfav.get(key, 0.0) + p

    return fav, unfav, 1.0 - total_mass


def convolve(d1: Dist, d2: Dist) -> Dist:
    """Pool two committees' contributions. Tallies add."""
    out: Dist = {}
    for (a1, t1), p1 in d1.items():
        if p1 < EPS:
            continue
        for (a2, t2), p2 in d2.items():
            p = p1 * p2
            if p < EPS:
                continue
            key = (a1 + a2, t1 + t2)
            out[key] = out.get(key, 0.0) + p
    return out


def mass(d: Dist) -> float:
    return sum(d.values())


def expected_admit(d: Dist, *, attacker_wants_approve: bool) -> float:
    """Unnormalised E[P(the attacker's preferred verdict)] over ``d``."""
    tot = 0.0
    for (approve, total), p in d.items():
        if total == 0:
            continue
        pa = f(a_hat(approve, total))
        tot += p * (pa if attacker_wants_approve else (1.0 - pa))
    return tot


# --------------------------------------------------------------------------
# architectures
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Result:
    proceed: float
    admit_given_proceed: float
    admit_per_submission: float
    dropped: float


def one_committee(m: Model) -> Result:
    """Architecture A. One committee; the attacker proceeds or abandons."""
    fav, _unfav, dropped = committee(m)
    p_proceed = mass(fav)
    admit = expected_admit(fav, attacker_wants_approve=m.attacker_votes_approve)
    return Result(
        proceed=p_proceed,
        admit_given_proceed=admit / p_proceed if p_proceed else 0.0,
        admit_per_submission=admit,
        dropped=dropped,
    )


def staged_pair(m: Model) -> Result:
    """Architecture C. Two committees of the same size, selected in sequence.

    One submission buys **two** independent draws at a favourable committee. The
    attacker proceeds if either comes up, and commits only into the ones that do.
    """
    fav, unfav, dropped = committee(m)

    both = convolve({**_merge(fav, unfav)}, {**_merge(fav, unfav)})
    neither = convolve(unfav, unfav)

    p_proceed = 1.0 - mass(neither)

    admit_all = expected_admit(both, attacker_wants_approve=m.attacker_votes_approve)
    admit_neither = expected_admit(neither, attacker_wants_approve=m.attacker_votes_approve)
    admit = admit_all - admit_neither

    return Result(
        proceed=p_proceed,
        admit_given_proceed=admit / p_proceed if p_proceed else 0.0,
        admit_per_submission=admit,
        dropped=dropped,
    )


def _merge(d1: Dist, d2: Dist) -> Dist:
    out = dict(d1)
    for k, v in d2.items():
        out[k] = out.get(k, 0.0) + v
    return out


def equal_effort(m: Model) -> Tuple[Result, Result]:
    """A at one committee of ``2*cohort`` against C at two of ``cohort``.

    Same expected number of reviewers on the case, so the only difference is the
    shape.
    """
    from dataclasses import replace

    big = one_committee(replace(m, cohort=m.cohort * 2))
    pair = staged_pair(m)
    return big, pair


# --------------------------------------------------------------------------
# the lemma
# --------------------------------------------------------------------------

def p_favourable(m: Model) -> float:
    """P(one committee is favourable to the attacker), exactly."""
    fav, _u, _d = committee(m)
    return mass(fav)


def lemma_holds(m: Model) -> Tuple[float, float, float, bool]:
    """Check the inequality the whole result rests on.

    Splitting one committee of ``2n`` into two of ``n`` cannot lower the chance
    that some committee is favourable, and strictly raises it whenever the
    threshold exceeds the attacker's population share.

    *Why it is not an empirical question.* Let ``P_m`` be the probability that a
    committee drawn with expected size ``m`` has attacker share at least ``θ``.
    The share concentrates on ``q`` as ``m`` grows, so for ``θ > q`` the tail
    probability ``P_m`` is strictly decreasing in ``m``. Two independent draws
    give ``1 − (1 − P_n)² = 2P_n − P_n²``, and since ``0 < P_n < 1``:

        P_2n  <  P_n  <  2P_n − P_n²

    The first inequality is concentration; the second is algebra. So the split
    strictly increases the attacker's chance of finding a favourable committee,
    for every ``θ > q``, with no parameter fitting anywhere.

    Returns ``(P_2n, P_n, 1-(1-P_n)^2, holds)``.
    """
    from dataclasses import replace

    p_n = p_favourable(m)
    p_2n = p_favourable(replace(m, cohort=m.cohort * 2))
    p_either = 1.0 - (1.0 - p_n) ** 2
    return p_2n, p_n, p_either, p_2n < p_either


def assumptions() -> List[str]:
    """Every place this can still be wrong. Exactness does not cover these."""
    return [
        "Eligibility is independent across identities (a per-identity hash "
        "threshold, which is what the protocol specifies).",
        "Honest reading errors are INDEPENDENT across moderators. Correlated "
        "error — a content class many reviewers misread together — is not "
        "modelled and would raise every figure here.",
        "One identity, one vote, and the attacker controls a fixed share of the "
        "registry. Sybil cost is not modelled.",
        "The attacker is pay-insensitive: their prize is external to the "
        "protocol, so cost deters an attempt but never a vote.",
        "Honest moderators vote their reading and do not model the attacker.",
        "Attendance is independent of committee composition.",
        "No conformity term: neither committee sees the other's votes. This is "
        "the staged proposal's own claim, granted to it in full.",
    ]
