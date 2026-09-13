"""The draw, as `specs/protocol.md` §5 decides it and `Moderation` implements it.

One module so there is one estimator. Both live engines import from here —
`staged.py` samples, `exact.py` enumerates — and neither carries its own copy,
because two copies is how they silently drifted apart from the contract in the
first place.

**The estimator is the raw share `A/N`.** §5 settles it against the Laplace form
`â = (A+1)/(N+2)`, and the reasoning is worth having next to the code because the
Laplace form is the intuitive choice and it is the wrong one:

- Against a clique holding a unanimous tally of 3, Laplace lowers capture from
  certainty to 89.6% — about 1.12 fees. The attacker's prize is the listing, which
  is external to the protocol, so a resubmission fee is not a barrier.
- On an *honest* unanimous tally of 3 it produces an outcome contradicting every
  vote 10.4% of the time.

The estimator is a function of `(A, N)` alone. It cannot tell a thin attacker tally
from a thin honest one, and in a quiet registry both are thin — so it charges the
wrong party. The thin-tally problem is closed structurally by §4.4's per-committee
reveal floor instead, which is priced in `FINDINGS-floor-price.md`.

**`verdict` compares rather than reduces.** The contract evaluates
`u * den < num << 128` for each of three `uint128` tickets; in the [0,1) form used
here that is `u < A/N`. The alternative `u mod N < A` is also uniform and also
gives `f(a)`, but it is not monotone in the tally. The current design does not
depend on that monotonicity — it draws fresh tickets each round on purpose, bounding
retry by the challenge cap — but the comparison form is what the contract does, so
it is what this reproduces.
"""

from __future__ import annotations

import random
from typing import Optional, Tuple

APPROVE, REJECT = True, False


def share(approve: int, total: int) -> float:
    """`A/N`, the estimator fed to the tickets (§5).

    Raises on an empty tally rather than returning a default. `Moderation._decide`
    handles `den == 0` by resolving REJECT with zero tickets before the estimator is
    ever consulted, so a caller reaching here with `total == 0` has skipped a case
    the contract terminates earlier — and silently returning 0.0 would model that as
    a *drawn* Reject, which is a different event.
    """
    if total <= 0:
        raise ValueError("share() on an empty tally; the caller must handle N == 0")
    return approve / total


def f(a: float) -> float:
    """`P(majority of three tickets approves) = 3a² − 2a³`.

    The marginal distribution that `draw_tickets` + `verdict` reproduce when handed
    the same `a`. Kept for closed-form work and for cross-checking the sampler.
    """
    return 3.0 * a * a - 2.0 * a * a * a


def draw_tickets(rng: random.Random) -> Tuple[float, float, float]:
    """Three uniforms, drawn afresh for one preliminary outcome (§5).

    On chain each is `uint128(H(OUTCOME_DOMAIN, …, challenges, i, entropy))`, with
    the round mixed into the preimage so every round's tickets are independent.
    Here the [0,1) form is the same object without the fixed-point noise.
    """
    return (rng.random(), rng.random(), rng.random())


def verdict(u: Tuple[float, float, float], approve: int, total: int) -> Optional[bool]:
    """Majority of three tickets against the tally. `None` on an empty tally.

    `None` rather than REJECT because the two are different events and a caller
    that conflates them will report a drawn Reject where the contract had no draw
    at all. With §4.4's floor in force an empty tally cannot reach a draw on chain.
    """
    if total <= 0:
        return None
    a = share(approve, total)
    return sum(1 for x in u if x < a) >= 2
