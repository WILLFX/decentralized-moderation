"""What (prior, rho) do to the design's numbers.

`measurement/prior/` produces two numbers. This turns them into the ones the
specification argues from.

**Why a second engine rather than a parameter.** `protocol_v3.py` draws each
honest vote independently at `honest_prior`, which is the assumption
`v2-audit-checklist.md` P1-4 and §5.6 have flagged as wrong since the first audit
and which nothing has ever tested. Independence is not a detail of the model; it
is what `f(a) = 3a² − 2a³` *means*. `f` is the CDF of the median of three
uniforms, and the variance reduction a cohort is paid for exists only if the
cohort's errors are independent.

The model: per item, draw a latent difficulty `p ~ Beta(alpha, beta)` with mean
`prior`; every honest moderator on that item is then correct with probability `p`.
For a Beta-Binomial the intra-class correlation is `1 / (alpha + beta + 1)`, so

    alpha + beta = (1 - rho) / rho      alpha = prior * (alpha + beta)

`rho = 0` recovers `protocol_v3.py` exactly — independent errors, `p == prior`
always. `rho = 1` is one opinion sampled N times: every moderator on an item is
right together or wrong together. Real classifier populations sit between, and
nobody knows where.
"""

from __future__ import annotations

import random
from typing import Tuple

from protocol_v3 import APPROVE, REJECT, ParamsV3, verdict, draw_tickets


def _beta_params(prior: float, rho: float) -> Tuple[float, float]:
    if rho <= 0:
        return (float("inf"), float("inf"))
    s = (1.0 - rho) / rho
    return prior * s, (1.0 - prior) * s


def item_accuracy(rng: random.Random, prior: float, rho: float) -> float:
    """The per-item accuracy every honest moderator on this item shares."""
    if rho <= 0:
        return prior
    if rho >= 1:
        return 1.0 if rng.random() < prior else 0.0
    a, b = _beta_params(prior, rho)
    return rng.betavariate(a, b)


def run_case(p: ParamsV3, rng: random.Random, *, content_is_safe: bool,
             prior: float, rho: float, attacker_wants: bool = APPROVE) -> str:
    """One case. Same lifecycle as `protocol_v3.run_case`, with correlated
    honest error and no challenge round — the round is measured separately in
    `FINDINGS-v3` §B and only muddies this surface."""
    n_att = int(round(p.n_moderators * p.attacker_share))
    prob = p.target_cohort / p.n_moderators

    att = sum(1 for _ in range(n_att) if rng.random() < prob)
    hon = sum(1 for _ in range(p.n_moderators - n_att)
              if rng.random() < prob and rng.random() < p.honest_availability)
    if att + hon < p.min_commits:
        return "UNRESOLVED"

    acc = item_accuracy(rng, prior, rho)
    right = sum(1 for _ in range(hon) if rng.random() < acc)
    hon_approve = right if content_is_safe else hon - right

    approve = hon_approve + (att if attacker_wants is APPROVE else 0)
    total = hon + att
    if total < 1:
        return "UNRESOLVED"
    return "APPROVED" if verdict(draw_tickets(rng), approve, total) else "REJECTED"


def surface(base: ParamsV3, trials: int = 3000) -> None:
    print("\nHow correlated error moves the two numbers §8.4 and §4.5 argue from.")
    print("`rho` = 0 is what protocol_v3.py assumes; nobody has measured it.\n")
    for q, label in ((0.0, "no attacker at all"), (0.30, "30% hostile")):
        print(f"  {label}:")
        print(f"    {'prior':>7} " + " ".join(f"{'rho=' + str(r):>12}"
                                              for r in (0.0, 0.25, 0.50, 1.0)))
        for prior in (0.665, 0.85, 0.95, 0.99):
            row = []
            for rho in (0.0, 0.25, 0.50, 1.0):
                rng = random.Random(31)
                p = ParamsV3(attacker_share=q)
                bad = sum(1 for _ in range(trials)
                          if run_case(p, rng, content_is_safe=False,
                                      prior=prior, rho=rho) == "APPROVED")
                rng = random.Random(37)
                good = sum(1 for _ in range(trials)
                           if run_case(p, rng, content_is_safe=True,
                                       prior=prior, rho=rho,
                                       attacker_wants=REJECT) == "REJECTED")
                row.append(f"{bad/trials:.3f}/{good/trials:.3f}")
            print(f"    {prior:>7.3f} " + " ".join(f"{c:>12}" for c in row))
        print()
    print("  each cell: P(unsafe approved) / P(safe rejected)")
    print("  design-v3 §8 justifies PERMANENT rejection with 0.725% on the right-hand")
    print("  number. Find the cell where that is true.")


if __name__ == "__main__":
    surface(ParamsV3())
