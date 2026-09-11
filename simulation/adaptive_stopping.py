"""Does adaptive stopping convert v3's liveness FAILURE into a latency COST?

`FINDINGS-v3.md` §E measures 92.2% `UNRESOLVED(NO_TURNOUT)` at registry 250.
That failure exists only because there is a fixed quorum to miss: §4.8 gates on
`commits >= MIN_COMMITS` at the close of one window, and a case that misses the
gate is dead rather than slow.

The alternative is Wald's sequential test, which is the optimal-expected-sample
rule for exactly this decision: keep a running posterior on the population's
Approve rate, stop the moment it is decisive, and otherwise keep sampling.

**The change under test is WHEN WE STOP, and nothing else.** At the stop the
verdict is still `protocol_v3.verdict` — the same three tickets against the same
`â = (A+1)/(N+2)` on the accumulated tally. Swapping the decision rule at the
same time would confound the two, and the decision rule is not what §E indicts.

Three configurations, measured against the same population:

* **V3** — `protocol_v3.run_case`, called directly. Not re-implemented here, so
  the baseline cannot be mis-stated in the direction that flatters the challenger.
* **ADAPTIVE** — sequential stopping over the same eligible set v3 sees. Asks
  whether stopping early is enough on its own.
* **ADAPTIVE+WIDEN** — the same, with §3.3's widening step re-triggered on
  *non-decisiveness* rather than on a fixed schedule. Asks whether the gain
  needs a bigger pool or only a better stopping rule.

The known risk of sequential stopping, which this models rather than hides: the
attacker is always-on (`attacker_always_on = 1.0`) and honest turnout trickles
in at `honest_availability` per window, so **early votes are hostile-enriched**.
A rule that stops early stops on that tally. `min_votes` is the defence and E11
sweeps it.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, replace
from typing import List, Optional, Tuple

from protocol_v3 import APPROVE, ParamsV3, draw_tickets, verdict, run_case


# ---------------------------------------------------------------------------
# the stopping rule
# ---------------------------------------------------------------------------

def p_theta_above_half(approve: int, reject: int) -> float:
    """`P(theta > 1/2 | A, R)` under the same uniform prior `â` assumes.

    The posterior is `Beta(A+1, R+1)`. Both parameters are integers, so the
    regularized incomplete beta at 1/2 is a finite binomial sum and needs no
    special function:

        P(theta > 1/2) = 2^-(N+1) * sum_{j=0}^{A} C(N+1, j),   N = A + R

    Checks: `(0,0) -> 0.5` (the uniform prior is undecided, which is the
    property that makes an empty tally unable to stop); `(3,0) -> 0.9375`,
    matching `1 - (1/2)^4` for `Beta(4,1)`.

    This is deliberately the SAME prior as §4.5's estimator. A stopping rule on
    one prior and a verdict on another would be two beliefs about one tally.
    """
    n = approve + reject
    total = sum(math.comb(n + 1, j) for j in range(approve + 1))
    return total / (1 << (n + 1))


@dataclass(frozen=True)
class AdaptiveParams:
    #: `epsilon` — stop when the posterior puts at most this much mass on the
    #: other side. Smaller is more evidence per case and more windows to get it.
    epsilon: float = 0.05

    #: Floor on votes before ANY stop is permitted. This is what `MIN_COMMITS`
    #: becomes: a floor on evidence rather than a gate on liveness. A case below
    #: it waits; it does not die.
    min_votes: int = 4

    #: Windows before the case gives up waiting. One window is v3's commit
    #: window, so 6 is about two hours.
    max_windows: int = 6

    #: Windows that must COMPLETE before any stop is permitted.
    #:
    #: `min_votes` is a floor on evidence and E11 shows it does not defend the
    #: rule, because an attacker supplies the evidence. A floor on TIME is a
    #: different object: the attacker cannot make the clock run faster, so a
    #: full window gives honest turnout its `honest_availability` chance to
    #: arrive before anything can be decided on. 0 reproduces naive sequential
    #: stopping.
    min_windows: int = 0

    #: At the cap, decide on whatever accumulated — provided there is at least
    #: this much. Below it the case is genuinely `UNRESOLVED`, and that residue
    #: is the honest remainder of the liveness problem.
    min_votes_to_decide: int = 3

    #: Eligibility multiplier per window. Under ADAPTIVE this stays 1.0 and the
    #: pool never grows; under ADAPTIVE+WIDEN it is §3.3's widening triggered by
    #: non-decisiveness instead of by the clock.
    widen_schedule: Tuple[float, ...] = (1.0,) * 6

    #: Evaluate the rule after EVERY vote rather than once per window.
    #:
    #: This is not a detail. A window-granular check cannot express the risk the
    #: rule is most exposed to: at registry 2,000 the first window delivers ~69
    #: votes at once, so the rule's first look is already at a large sample and
    #: `min_votes` can never bind. Per-vote evaluation is also what sequential
    #: testing actually means. Kept as a switch so the two can be compared.
    per_vote: bool = True

    #: Fraction of a window within which an always-on identity votes. Attackers
    #: are `attacker_always_on = 1.0` and are therefore bots; honest turnout is
    #: people, spread across the window. So the ORDER of arrival is hostile at
    #: the front, and a rule that stops early stops on that prefix. This is the
    #: mechanism §3.3's F12 asks about, applied to time within a window rather
    #: than to a widening step.
    bot_prefix: float = 0.20


#: Naive sequential stopping — no floor on time. E11 and E17 show this is
#: unsafe at every `bot_prefix` tested and catastrophically so below 0.2. Kept
#: because the finding is the reason the other two configurations exist.
NO_WIDEN = AdaptiveParams()
WIDEN = AdaptiveParams(widen_schedule=(1.0, 1.5, 2.0, 3.0, 4.0, 6.0))

#: Sequential stopping with E16's fix: one completed window before any stop is
#: permitted. This is the configuration any conclusion should be drawn from.
SAFE = AdaptiveParams(min_windows=1)
SAFE_WIDEN = AdaptiveParams(min_windows=1,
                            widen_schedule=(1.0, 1.5, 2.0, 3.0, 4.0, 6.0))


@dataclass
class AdaptiveResult:
    terminal: str                      # APPROVED | REJECTED | UNRESOLVED
    reason: Optional[str] = None       # NO_TURNOUT
    approve: int = 0
    reject: int = 0
    windows: int = 0
    stopped_early: bool = False        # decisive before the cap
    hostile: int = 0                   # hostile votes in the tally at the stop

    @property
    def approved(self) -> bool:
        return self.terminal == "APPROVED"

    @property
    def votes(self) -> int:
        return self.approve + self.reject


def run_case_adaptive(p: ParamsV3, ap: AdaptiveParams, rng: random.Random, *,
                      content_is_safe: bool,
                      attacker_wants: bool = APPROVE) -> AdaptiveResult:
    """One case under sequential stopping.

    Eligibility is the passive hash test of §3.1, modelled as a fixed uniform
    `u_i` per identity against a moving threshold — so widening is **monotone**
    and only ever adds identities, which is what §3.3 says it does. Availability
    is resampled per window, so an intermittent identity that misses window 1 is
    reachable in window 2. That is the entire mechanism under test: v3 asks the
    population once, this asks repeatedly.
    """
    n = p.n_moderators
    n_att = p.n_attackers
    u = [rng.random() for _ in range(n)]          # the hash value per identity
    voted = [False] * n
    base = p.target_cohort / n

    approve = reject = hostile = 0
    windows = 0

    for w in range(ap.max_windows):
        windows = w + 1
        thresh = base * ap.widen_schedule[min(w, len(ap.widen_schedule) - 1)]

        # Who shows up this window, and WHEN inside it. Attackers are bots and
        # land in the first `bot_prefix` of the window; honest turnout is people
        # and spreads across all of it.
        arrivals: List[Tuple[float, bool]] = []      # (time in window, attacker)
        for i in range(n):
            if voted[i] or u[i] >= thresh:
                continue
            attacker = i < n_att
            avail = p.attacker_always_on if attacker else p.honest_availability
            if rng.random() >= avail:
                continue                           # not available THIS window
            voted[i] = True
            t = rng.random() * (ap.bot_prefix if attacker else 1.0)
            arrivals.append((t, attacker))
        arrivals.sort()

        for k, (_, attacker) in enumerate(arrivals):
            if attacker:
                hostile += 1
                vote = attacker_wants
            else:
                # honest moderators are right with probability `prior`; a wrong
                # honest vote is indistinguishable from a hostile one, which is
                # E1's whole point
                correct = rng.random() < p.honest_prior
                vote = content_is_safe if correct else not content_is_safe
            if vote is APPROVE:
                approve += 1
            else:
                reject += 1

            last = k == len(arrivals) - 1
            if not (ap.per_vote or last):
                continue
            if approve + reject < ap.min_votes:
                continue
            # the time floor: a window in progress is not a window completed,
            # so a stop inside window `min_windows` is not permitted even on a
            # decisive tally
            if windows < ap.min_windows or (windows == ap.min_windows and not last):
                continue
            post = p_theta_above_half(approve, reject)
            if post >= 1.0 - ap.epsilon or post <= ap.epsilon:
                u3 = draw_tickets(rng)
                final = verdict(u3, approve, approve + reject)
                return AdaptiveResult("APPROVED" if final else "REJECTED",
                                      approve=approve, reject=reject,
                                      windows=windows, stopped_early=True,
                                      hostile=hostile)

    # the cap. Decide on what accumulated rather than discard it — an
    # indecisive tally is still evidence, and v3 decides on tallies this thin
    # whenever they clear MIN_COMMITS.
    if approve + reject >= ap.min_votes_to_decide:
        u3 = draw_tickets(rng)
        final = verdict(u3, approve, approve + reject)
        return AdaptiveResult("APPROVED" if final else "REJECTED",
                              approve=approve, reject=reject, windows=windows,
                              hostile=hostile)
    return AdaptiveResult("UNRESOLVED", "NO_TURNOUT", approve=approve,
                          reject=reject, windows=windows, hostile=hostile)


# ---------------------------------------------------------------------------
# measurement
# ---------------------------------------------------------------------------

@dataclass
class Stats:
    #: `P(approved | the case resolved)`. Conditional, NOT `approved / trials`.
    #: An unresolved case is not a rejection: it is a case with no verdict, and
    #: scoring it as one credits a design for the cases it failed to run. At
    #: registry 250 that error alone moves v3's apparent false-approval rate
    #: from 0.60 to 0.05.
    approved: float
    unresolved: float
    mean_votes: float           # over resolved cases
    mean_windows: float         # over resolved cases
    early: float                # share of resolved cases that stopped decisive
    hostile_share: float        # hostile votes / all votes, at the stop


def _finish(ok: int, un: int, trials: int, votes: int, wins: int,
            early: int, hostile: int) -> Stats:
    res = trials - un
    return Stats(
        ok / res if res else float("nan"),
        un / trials,
        votes / res if res else float("nan"),
        wins / res if res else float("nan"),
        early / res if res else float("nan"),
        hostile / votes if votes else float("nan"),
    )


def measure_v3(p: ParamsV3, *, safe: bool, wants: bool = APPROVE,
               trials: int, seed: int) -> Stats:
    rng = random.Random(seed)
    ok = un = votes = hostile = 0
    for _ in range(trials):
        r = run_case(p, rng, content_is_safe=safe, attacker_wants=wants)
        if r.terminal == "UNRESOLVED":
            un += 1
            continue
        ok += 1 if r.approved else 0
        votes += r.reveals
        hostile += sum(rd.commits_attacker for rd in r.rounds)
    # v3's latency is fixed by the clock, not by the evidence: one commit window
    # to the published tally whether the tally is 40-0 or 20-20. Reported as 1.0
    # so the column is comparable in units, not because it was measured.
    return _finish(ok, un, trials, votes, trials - un, 0, hostile)


def measure_adaptive(p: ParamsV3, ap: AdaptiveParams, *, safe: bool,
                     wants: bool = APPROVE, trials: int, seed: int) -> Stats:
    rng = random.Random(seed)
    ok = un = early = votes = wins = hostile = 0
    for _ in range(trials):
        r = run_case_adaptive(p, ap, rng, content_is_safe=safe,
                              attacker_wants=wants)
        if r.terminal == "UNRESOLVED":
            un += 1
            continue
        ok += 1 if r.approved else 0
        votes += r.votes
        wins += r.windows
        hostile += r.hostile
        early += 1 if r.stopped_early else 0
    return _finish(ok, un, trials, votes, wins, early, hostile)
