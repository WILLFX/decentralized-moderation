"""Pricing §11's per-committee minimum.

The open item, in the specification's own words: *"Set a minimum commitment
requirement for each committee. A combined threshold is not enough: 40 commits in
committee 1 and one in committee 2 is not two committees."*

It turned out to be load-bearing rather than tidy-up. With `A/N`, a unanimous
tally decides with certainty; three commits start the clock and are explicitly
not a quorum; nothing requires committee B to hold anybody. So three identities
that are the only committers take a case with probability 1 —
`contracts/test/ThreeVote.t.sol` pins that at 40 of 40.

A floor closes it. This prices the floor: what it costs in cases that cannot
resolve, against what it buys in identities an attacker must own.

Everything here is exact. The quantities are binomial tails over a few hundred
states, so there is nothing to sample and no seed to get unlucky with.

**Where the cohort size comes from.** §3 makes a moderator eligible when
`hash(...)` carries at least `N − 5` leading zero bits, with `N` set so the
registry lies in `[2^N, 2^(N+1))`. So each identity is eligible with probability
`2^-(N-5) = 32 / 2^N`, and the expected committee is between 32 and 64. It is not
a parameter anyone chose; it falls out of the eligibility rule.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import comb


def elig_bits(registry: int) -> int:
    """§3's `N − 5`, from the registry size."""
    n, bits = registry, 0
    while n > 1:
        n >>= 1
        bits += 1
    return max(0, bits - 5)


def p_eligible(registry: int) -> float:
    return 0.5 ** elig_bits(registry)


def binom_tail_ge(n: int, p: float, k: int) -> float:
    """`P(X >= k)` for `X ~ Binomial(n, p)`.

    Summed as `1 - P(X < k)` using the pmf recurrence

        pmf(0)   = (1-p)^n
        pmf(i+1) = pmf(i) * (n-i)/(i+1) * p/(1-p)

    rather than `comb(n, i) * p^i * (1-p)^(n-i)` term by term. The direct form
    overflows: at `n = 5000` the binomial coefficient is astronomically large and
    `p^i` astronomically small, and they only cancel *after* both have left the
    range of a float. The recurrence never forms either factor, and because the
    floors here are small it touches only the first `k` terms.
    """
    if k <= 0:
        return 1.0
    if k > n:
        return 0.0
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 1.0

    pmf = (1 - p) ** n
    below = pmf
    ratio = p / (1 - p)
    for i in range(k - 1):
        pmf *= (n - i) / (i + 1) * ratio
        below += pmf
    return max(0.0, 1.0 - below)


def binom_pmf_at(n: int, p: float, k: int) -> float:
    if k < 0 or k > n:
        return 0.0
    return comb(n, k) * p**k * (1 - p) ** (n - k)


@dataclass(frozen=True)
class World:
    registry: int = 1000
    attacker_identities: int = 3
    #: P(an eligible honest moderator commits inside the window)
    availability: float = 0.80

    @property
    def honest(self) -> int:
        return self.registry - self.attacker_identities

    @property
    def p_elig(self) -> float:
        return p_eligible(self.registry)

    @property
    def p_honest_commits(self) -> float:
        """Eligible AND available. The attacker is always-on, so their rate is
        `p_elig` alone."""
        return self.p_elig * self.availability


# ---------------------------------------------------------------- the cost


def p_case_unresolved(w: World, floor: int) -> float:
    """`P(an ordinary case fails the floor)` — the availability price.

    Both committees must reach the floor, and they are drawn independently, so a
    case survives with `P(A >= k)^2`. **That squaring is the whole reason a
    per-committee floor costs more than a combined one of the same total**, and
    it is also the reason a combined floor does not do the job.
    """
    per = binom_tail_ge(w.registry, w.p_honest_commits, floor)
    return 1.0 - per * per


def p_case_unresolved_combined(w: World, floor: int) -> float:
    """The same for a COMBINED floor over both committees, for comparison."""
    return 1.0 - binom_tail_ge(2 * w.registry, w.p_honest_commits, floor)


# ------------------------------------------------------------- the benefit


def p_sole_committers(w: World, floor: int) -> float:
    """`P(the attacker is the ONLY committer in both committees, at the floor)`.

    This is the capture `ThreeVote.t.sol` demonstrates: unanimous, so certain
    under `A/N`. It needs the attacker to field at least `floor` of their own in
    each committee AND no honest moderator to commit in either.
    """
    a = binom_tail_ge(w.attacker_identities, w.p_elig, floor)
    quiet = (1 - w.p_honest_commits) ** w.honest
    return (a * quiet) ** 2


def identities_for_capture(w: World, floor: int, target: float = 0.01) -> int:
    """Smallest attacker holding that reaches `target` probability of capture.

    Returns 0 if even the whole registry cannot — which happens once the floor
    demands more silence from honest moderators than is plausible.
    """
    for m in range(max(1, floor), w.registry):
        probe = World(w.registry, m, w.availability)
        if p_sole_committers(probe, floor) >= target:
            return m
    return 0
