"""Campaign mode: run a persistent population through a stream of cases on a
shared absolute clock, so freezes actually remove capacity from later draws.

The single-case scenarios rebuild the population every trial and start each case
at ``now = 0``, so a freeze — stored as an absolute ``frozen_until`` — never
excludes anyone from a *subsequent* draw. Under that setup freezing is
economically inert (the blind review measured zero frozen moderators at any
eligibility check). Campaign mode fixes it: one population, an absolute day-clock
advancing by ``1 / cases_per_day`` between case arrivals, each case initialized
to the current clock. A moderator frozen in one case is then absent from the
eligible pool of later cases until its ``frozen_until``.

Sequential approximation. Cases arrive faster (e.g. every 12h) than they resolve
(days, through appeal windows), so in reality many run concurrently. We resolve
each case fully before starting the next; a moderator frozen partway through a
case's timeline is treated as frozen from the next case's start. This captures
the load-bearing dynamic — freeze shrinks the eligible pool over time — while
keeping the engine sequential. It slightly *front-loads* freeze onset relative to
true concurrency, so it is, if anything, favorable to the freeze deterrent; that
caveat is carried into any conclusion drawn from campaign runs.
"""

from __future__ import annotations

import random
from typing import Callable, List, Optional

from .params import Params
from .protocol import Case, CaseResult, Moderator, run_case

# A factory builds the i-th case of the campaign (its honest label, difficulty,
# attacker_target, etc.). The campaign sets case.now to the clock itself.
CaseFactory = Callable[[int, random.Random], Case]


def frozen_count(pop: List[Moderator], now: float) -> int:
    """Number of moderators currently frozen at time `now`."""
    return sum(1 for m in pop if m.is_frozen(now))


def run_campaign(
    pop: List[Moderator],
    p: Params,
    case_factory: CaseFactory,
    n_cases: int,
    rng: random.Random,
    cases_per_day: float = 2.0,
    appeal_policy=None,
) -> List[CaseResult]:
    """Play `n_cases` sequential cases over one persistent population.

    Returns the list of CaseResults. The population is mutated in place — its
    moderators carry stake, earnings, track record, and freeze state across the
    whole campaign, which is the entire point (freeze must persist to bite).
    """
    clock = 0.0
    dt = 1.0 / cases_per_day
    results: List[CaseResult] = []
    for i in range(n_cases):
        case = case_factory(i, rng)
        case.now = clock                 # anchor the case to the absolute clock
        results.append(run_case(pop, p, case, rng, appeal_policy=appeal_policy))
        clock += dt
    return results
