"""Freeze as a penalty currency: what "infinite concurrency" actually buys.

The open disagreement. One design says:

    "when you have a stake you can use it in infinite cases at the same time, any
     penalty from individual cases is added to the total freeze time, the only
     penalty is freeze"

The other debits a fixed amount from a bond and caps concurrency by solvency.

**The repository's stated reason for abolishing freezes does not hold up on its
own terms.** §5.1 of the spec says identity-wide freezing "produced zero honest
turnout at every fee from 3 to 300". That number came from the v2 engine, whose
participation utility multiplied an already-unconditional expected payment by the
probability of coherence — an error found by external review, not by us. See
`utility_threshold()`: the bug is enormous at small risk/reward ratios and
vanishes at the large ones freezing produces, so the conclusion survives, but the
evidence cited for it was bad and that is worth knowing.

**The argument that does hold is arithmetic and needs no simulation.** It is
derived in `throughput_ceiling()` and checked against a day-by-day run in
`simulate_throughput()`.

What is *not* claimed here: that freezing is wrong in principle. `F` is a free
parameter and a small `F` gives a high ceiling. The finding is the shape of the
trade — `F` large enough to deter is `F` large enough to throttle — and that the
throttle is immune to the fee.
"""

from __future__ import annotations

import random


def utility_threshold(r: float, *, buggy: bool = False) -> float:
    """Confidence a moderator needs before voting is +EV, at risk/reward ``r``.

    With `E` the unconditional expected payment, `p` the probability of being
    coherent, and a loss costing `r·E`:

        correct:  E − (1−p)·r·E > 0   ⟹   p > 1 − 1/r
        buggy:    p·E − (1−p)·r·E > 0 ⟹   p > r/(1+r)

    The v2 engine used the second. The gap is 29.8 points at `r = 1.4` and under
    0.1 points at `r ≥ 30`, which is why the freeze conclusion survives its own
    bad evidence: identity-wide freezing puts `r` in the tens or hundreds.
    """
    if buggy:
        return r / (1.0 + r)
    return max(0.0, 1.0 - 1.0 / r) if r > 0 else 0.0


def throughput_ceiling(freeze_days: float, prior: float) -> float:
    """Sustainable cases per day per identity under **additive** freeze.

    A moderator active on a given day votes in `L` cases. Each incoherent vote
    adds `F` days to a running total, and a frozen moderator votes in nothing. So
    per active day they accrue `F·(1−p)·L` frozen days, giving a duty cycle

        a  =  1 / (1 + F(1−p)L)

    and a realised throughput of

        L·a  =  L / (1 + F(1−p)L)   →   1 / (F(1−p))   as L → ∞

    **So concurrency saturates.** Going from one open case to two hundred moves a
    moderator at `p = 0.665, F = 8` from 0.272 to 0.373 cases per day, and no
    further. "Infinite concurrency" is nominal: the freeze converts it into a
    hard throughput ceiling.

    **And no fee changes it.** There is no price in the expression. It is a
    time-against-time constraint, so raising pay raises both sides equally — the
    same structural reason the v2 risk/reward ratio could not be tuned with money.

    Contrast the debit: a loss costs money, so throughput is not capped by
    accuracy at all. Concurrency is capped by capital, `(bond − BOND_MIN)/λ`, and
    capital can be added. Accuracy cannot.
    """
    if freeze_days <= 0 or prior >= 1.0:
        return float("inf")
    return 1.0 / (freeze_days * (1.0 - prior))


def throughput_at(concurrency: int, freeze_days: float, prior: float) -> float:
    """`L / (1 + F(1−p)L)` — throughput at a finite concurrency ``L``."""
    if concurrency <= 0:
        return 0.0
    return concurrency / (1.0 + freeze_days * (1.0 - prior) * concurrency)


def simulate_throughput(concurrency: int, freeze_days: float, prior: float,
                        *, days: int = 200_000, seed: int = 1) -> float:
    """Day-by-day check of ``throughput_at``. Exists to test the algebra."""
    rng = random.Random(seed)
    frozen = 0.0
    cases = 0
    for _ in range(days):
        if frozen > 0:
            frozen -= 1
            continue
        for _ in range(concurrency):
            cases += 1
            if rng.random() > prior:
                frozen += freeze_days
    return cases / days
