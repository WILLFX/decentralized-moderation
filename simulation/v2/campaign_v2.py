"""Multi-case campaign — the model that can see P0-1.

The single-case engine in ``protocol_v2.py`` structurally cannot observe the
finding that prompted the v2.1 revision. Pre-settlement leverage is about voting in
*many cases at once* before any of them settles, and a one-case-at-a-time model has
no "at once" in it. That gap is what hid the finding from this project's first
simulation; the external review found it analytically instead.

What this measures: over a horizon, how many votes can an attacker place before the
first penalty lands, with and without risk units?

    unlimited concurrency (pre-v2.1)  -- one stake backs every case, no reservation
    K risk units (v2.1)               -- committing reserves one until settlement

The attacker is pay-insensitive throughout: their prize is the listing, which is
external to the protocol, so they vote whenever eligible and able.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Dict, List


@dataclass
class CampaignParams:
    n_moderators: int = 1000
    attacker_share: float = 0.30
    target_cohort: int = 32
    cases_per_day: float = 40.0        # arrival rate of new cases
    horizon_days: float = 30.0
    case_duration_days: float = 5.0    # commit + reveal + challenge, then settlement
    units_per_moderator: int = 10      # K; ignored in the unlimited arm
    settlement_lag_days: float = 1.0   # finalized -> actually settled


def run_campaign(p: CampaignParams, limited: bool, seed: int = 7) -> Dict:
    """One arm. `limited=False` reproduces the pre-v2.1 rule."""
    rng = random.Random(seed)
    n_att = int(round(p.n_moderators * p.attacker_share))

    # free[i] = units currently available; releases[t] = units coming back at day t
    free: List[int] = [p.units_per_moderator] * p.n_moderators
    releases: Dict[int, List[int]] = {}

    attacker_votes = 0
    honest_votes = 0
    blocked = 0                  # attacker votes prevented by having no free unit
    peak_concurrent = 0
    in_flight = 0                # attacker votes not yet settled, both arms
    expiry: Dict[int, int] = {}  # day -> attacker votes settling that day

    hold = p.case_duration_days + p.settlement_lag_days
    day = 0
    while day < p.horizon_days:
        for idx in releases.pop(day, []):
            free[idx] += 1
        in_flight -= expiry.pop(day, 0)

        for _ in range(int(p.cases_per_day)):
            # Who is eligible? Bernoulli per identity, as in the case engine.
            prob = p.target_cohort / p.n_moderators
            for i in range(p.n_moderators):
                if rng.random() >= prob:
                    continue
                attacker = i < n_att
                if limited and free[i] <= 0:
                    if attacker:
                        blocked += 1
                    continue
                if limited:
                    free[i] -= 1
                    releases.setdefault(day + int(hold), []).append(i)
                if attacker:
                    attacker_votes += 1
                    in_flight += 1
                    d = day + int(hold)
                    expiry[d] = expiry.get(d, 0) + 1
                else:
                    honest_votes += 1

        peak_concurrent = max(peak_concurrent, in_flight)
        day += 1

    return {
        "attacker_votes": attacker_votes,
        "honest_votes": honest_votes,
        "blocked": blocked,
        "peak_concurrent_attacker_votes": peak_concurrent,
    }


def e6_pre_settlement_leverage(p: CampaignParams | None = None) -> None:
    base = p or CampaignParams()
    print("\nE6  Pre-settlement leverage — the finding a one-case model cannot see")
    print("    An attacker votes in as many cases as possible before the first")
    print("    penalty lands. Risk units are supposed to bound that.\n")
    print(f"    {base.horizon_days:.0f}-day horizon, {base.attacker_share:.0%} hostile,"
          f" K={base.units_per_moderator}, unit held {base.case_duration_days:.0f}+"
          f"{base.settlement_lag_days:.0f} days\n")
    print(f"    {'cases/day':>10} {'peak concurrent (unlimited)':>28}"
          f" {'(K units)':>12} {'bounded to':>12} {'blocked':>10}")
    for rate in (10, 40, 100, 250, 500, 1000):
        q = replace_rate(base, rate)
        unl = run_campaign(q, limited=False)
        lim = run_campaign(q, limited=True)
        a = unl["peak_concurrent_attacker_votes"]
        b = lim["peak_concurrent_attacker_votes"]
        frac = f"{b/a:.0%}" if a else "-"
        print(f"    {rate:>10} {a:>28,} {b:>12,} {frac:>12} {lim['blocked']:>10,}")

    n_att = int(round(base.n_moderators * base.attacker_share))
    ceiling = n_att * base.units_per_moderator
    print(f"\n    Hard ceiling under K units: {n_att} hostile identities x"
          f" K={base.units_per_moderator} = {ceiling:,} concurrent votes, whatever")
    print("    the case rate. Under unlimited concurrency there is no ceiling at all —")
    print("    the campaign grows with how many cases the attacker chooses to open,")
    print("    and opening cases is something the attacker controls.")
    print("\n    Note the shape: at ordinary load the limit does not bind, so honest")
    print("    work is unaffected. It binds exactly when someone floods.")


def replace_rate(p: CampaignParams, rate: float) -> CampaignParams:
    from dataclasses import replace as _r
    return _r(p, cases_per_day=rate)


if __name__ == "__main__":
    e6_pre_settlement_leverage()
