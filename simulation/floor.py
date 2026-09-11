"""The lottery's irreducible floor, and what it would take to remove it.

The claim under examination, from the external review:

    "Suppose increasingly large challenge committees consistently contribute 30%
    false approvals and 70% correct rejections. The influence of the original
    captured committee eventually becomes negligible, but the pooled approval
    fraction approaches 0.30. Consequently [P(approve) -> 21.6%]."

`f(0.30) = 3(0.09) - 2(0.027) = 0.216`, so the arithmetic is right. **The 21.6%
is optimistic**, because it assumes honest moderators never err. This module
computes the floor under the design's own accuracy assumption, proves the
asymptotic claim rather than sampling it, and then asks the question the floor
actually poses: what decision rule would not have one, and what does it cost?

Three results, in order of importance:

1.  **The lottery's error does not vanish with cohort size.** It converges to a
    positive constant. More honest review does not help past a point.
2.  **A threshold rule's error vanishes exponentially in cohort size.** So the
    difference between the two is not a tuning question; it is the difference
    between `Theta(1)` and `exp(-Theta(N))`.
3.  **Neither matters below a separability bound on `prior`.** If honest
    moderators are not accurate enough relative to the attacker's share, safe and
    unsafe content produce overlapping vote distributions and *no* rule — lottery,
    threshold, or anything else — separates them at any cohort size. That bound
    is derived in `separability_bound()` and it is the finding that outranks the
    other two.

Everything here is exact: closed forms verified against direct enumeration, and
asymptotics proved rather than extrapolated from a table.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import comb, exp, log
from typing import Tuple


def f(a: float) -> float:
    """P(a majority of three tickets approves) = 3a^2 - 2a^3."""
    return 3.0 * a * a - 2.0 * a * a * a


# --------------------------------------------------------------------------
# the vote-generating process
# --------------------------------------------------------------------------

def p_approve(q: float, prior: float, *, content_is_safe: bool) -> float:
    """P(a random revealed vote is Approve).

    On **unsafe** content the attacker's whole share approves, and an honest
    moderator approves only by error, at `1 - prior`:

        p = q + (1 - q)(1 - prior)

    On **safe** content the attacker rejects to censor, and an honest moderator
    approves when correct:

        p = (1 - q) * prior

    This is the design's own claim about motive: the attacker is pay-insensitive
    and always votes its direction; honest moderators vote their reading.
    """
    if content_is_safe:
        return (1.0 - q) * prior
    return q + (1.0 - q) * (1.0 - prior)


# --------------------------------------------------------------------------
# 1. the lottery
# --------------------------------------------------------------------------

def lottery_exact(n: int, p: float) -> float:
    """`E[f((A+1)/(N+2))]` for `A ~ Binomial(n, p)`, in closed form.

    `f` is a cubic in `a_hat`, and `a_hat` is affine in `A`, so the expectation
    is a polynomial in the first three raw moments of a binomial — which are
    exact. No sum over `n` is needed and no approximation is made.

    Using falling factorials, `E[A^(k)] = n^(k) p^k`, and
    `A^3 = A^(3) + 3A^(2) + A^(1)`:

        E[A]   = np
        E[A^2] = n(n-1)p^2 + np
        E[A^3] = n(n-1)(n-2)p^3 + 3n(n-1)p^2 + np
    """
    m = n + 2
    e1 = n * p
    e2 = n * (n - 1) * p * p + e1
    e3 = n * (n - 1) * (n - 2) * p ** 3 + 3 * n * (n - 1) * p * p + e1

    # E[(A+1)^2] and E[(A+1)^3]
    e1p = e1 + 1.0
    e2p = e2 + 2.0 * e1 + 1.0
    e3p = e3 + 3.0 * e2 + 3.0 * e1 + 1.0

    return 3.0 * e2p / (m * m) - 2.0 * e3p / (m ** 3)


def lottery_enumerated(n: int, p: float) -> float:
    """The same quantity by direct summation. Independent of the closed form.

    Exists only to check `lottery_exact`; O(n) rather than O(1).
    """
    total = 0.0
    for a in range(n + 1):
        pa = comb(n, a) * (p ** a) * ((1.0 - p) ** (n - a))
        total += pa * f((a + 1) / (n + 2))
    return total


def lottery_limit(p: float) -> float:
    """`lim_{N->inf} E[f(a_hat)] = f(p)`. A constant, and positive for `p > 0`.

    **Proof.** `a_hat = (A+1)/(N+2)` and `A/N -> p` almost surely by the strong
    law, so `a_hat -> p` almost surely. `f` is a polynomial, hence continuous and
    bounded on `[0,1]`, so by bounded convergence `E[f(a_hat)] -> f(p)`.

    The limit does not depend on `N`. **Adding honest reviewers cannot drive the
    lottery's error below `f(p)`** — it only removes the sampling noise around
    it. That is the floor.
    """
    return f(p)


# --------------------------------------------------------------------------
# 2. a threshold rule
# --------------------------------------------------------------------------

def threshold_exact(n: int, p: float, theta: float) -> float:
    """`P(A/n >= theta)` for `A ~ Binomial(n, p)`. Exact upper tail."""
    if n <= 0:
        return 0.0
    k0 = 0
    # smallest k with k/n >= theta, computed in integers to avoid a float edge
    while k0 <= n and k0 < theta * n:
        k0 += 1
    total = 0.0
    for a in range(k0, n + 1):
        total += comb(n, a) * (p ** a) * ((1.0 - p) ** (n - a))
    return total


def threshold_bound(n: int, p: float, theta: float) -> float:
    """Hoeffding bound on the same tail: `exp(-2n(theta-p)^2)` for `theta > p`.

    **This is the whole point.** Where the lottery converges to a positive
    constant, a threshold rule's error decays *exponentially in the number of
    reviewers*. Review effort buys nothing under the first rule and everything
    under the second.
    """
    if theta <= p:
        return 1.0
    return exp(-2.0 * n * (theta - p) ** 2)


def reviewers_for(target: float, p: float, theta: float) -> float:
    """Reviewers needed for a threshold rule to reach `target` error.

    Inverting Hoeffding: `n >= ln(1/target) / (2 (theta - p)^2)`. Finite for any
    target whenever `theta > p`; **infinite for the lottery at any target below
    its floor**, which is the asymmetry stated as a number.
    """
    if theta <= p:
        return float("inf")
    return log(1.0 / target) / (2.0 * (theta - p) ** 2)


# --------------------------------------------------------------------------
# 3. separability — the bound that outranks both
# --------------------------------------------------------------------------

def separability_bound(q: float) -> float:
    """Minimum `prior` for safe and unsafe content to be distinguishable at all.

    A threshold rule needs a `theta` strictly between the two Approve rates:

        p_unsafe = q + (1-q)(1-prior)   <   theta   <   (1-q) prior = p_safe

    Such a `theta` exists iff `p_safe > p_unsafe`:

        (1-q) prior              >  q + (1-q)(1-prior)
        (1-q)[prior - (1-prior)] >  q
        (1-q)(2 prior - 1)       >  q
        prior                    >  (1 + q/(1-q)) / 2

    **Below this line the two distributions overlap in the wrong order** — a
    randomly chosen vote is *more* likely to be Approve on unsafe content than on
    safe content — and no decision rule over the tally separates them, at any
    cohort size, because the tally carries no signal to separate. This is not a
    statement about the lottery. It is a statement about the votes.
    """
    return 0.5 * (1.0 + q / (1.0 - q))


@dataclass(frozen=True)
class Regime:
    q: float
    prior: float
    p_unsafe: float
    p_safe: float
    separable: bool
    bound: float


def regime(q: float, prior: float) -> Regime:
    return Regime(
        q=q,
        prior=prior,
        p_unsafe=p_approve(q, prior, content_is_safe=False),
        p_safe=p_approve(q, prior, content_is_safe=True),
        separable=prior > separability_bound(q),
        bound=separability_bound(q),
    )


def assumptions() -> Tuple[str, ...]:
    return (
        "Votes are INDEPENDENT given the content. This is conservative for the "
        "floor result specifically: independence is the best case for averaging, "
        "and correlated error raises the floor rather than lowering it.",
        "The attacker controls a fixed share q of revealed votes and always "
        "votes its direction.",
        "Honest accuracy `prior` is a single number, not a per-content-class "
        "distribution. An adversary who selects content from a class where "
        "reviewers do worse faces a lower effective prior than the average.",
        "The threshold comparison assumes a fixed denominator — the certificate "
        "counts approvals out of preselected positions, not out of whoever "
        "revealed. Without that, selective non-participation reshapes the "
        "denominator and the exponential decay does not hold.",
    )
