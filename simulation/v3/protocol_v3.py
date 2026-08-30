"""Simulation engine for the challenge-free-then-not architecture.

Design: ``specs/design-v3.md``.  Normative: ``specs/state-machine-v3.md`` at
`e2f374a`.  Where the two disagree the state machine wins, and this engine
follows the state machine.

**The v2 engine cannot be reused and its results cannot be carried over.** Three
things changed at the level of what a case *is*:

* the verdict is a **majority of three tickets**, not one, so `P(Approve)` is
  `f(a) = 3a² − 2a³` rather than `a`;
* the three tickets are **fixed once per claim** and reused at the final draw
  (state-machine §4.5), which makes the verdict *monotone* in the tally and is
  the whole reason a challenge cannot buy a re-roll;
* penalties are **balance debits**, not time freezes, so the risk/reward ratio is
  a chosen constant instead of `freeze_days × concurrent_cases`.

``simulation/v2/FINDINGS-v2.md`` §A and §D are produced by risk units, which are
withdrawn.  Nothing from them transfers.

What this exists to measure — the questions the spec cannot answer about itself,
listed in `state-machine-v3.md` §10:

1.  **F9.** `T` is calibrated so the expected cohort is `TARGET_COHORT`, which
    needs the active-moderator count — the quantity §3.6 says cannot be
    maintained on chain.  What does a static `T` cost as the registry grows?
2.  **F12.** §3.3 argues eligibility widening cannot shift composition because it
    is uniform over *identities*.  Composition is a property of who *acts*.  Does
    a widening step at a publicly known minute favour an always-on cohort?
3.  **`h`.** Honest challenge reliability, the one quantity that lives outside the
    contract.  §4.5 claims the single-randomness rule largely defuses it.
4.  The open parameters: `d`, `BOND_MIN`, `MIN_COMMITS`, `CHALLENGE_BOND`.

The attacker is pay-insensitive throughout: their prize is the listing, which is
external to the protocol, so they act whenever eligible and able.  Honest turnout
is a rational response to expected earnings net of the debit.  That asymmetry is
the design's own claim about motives.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, replace
from typing import List, Optional, Tuple

APPROVE, REJECT = True, False


@dataclass(frozen=True)
class ParamsV3:
    # population
    n_moderators: int = 1000
    attacker_share: float = 0.30

    # eligibility (§3.1, §3.3)
    target_cohort: int = 40
    widen_factor: float = 1.5
    widen_enabled: bool = True

    # quorum (§4.8) — the gate is on COMMITS, decided before any tally exists
    min_commits: int = 16
    min_reveals: int = 16

    # economics (§5)
    fee: float = 90.0
    gas_cost: float = 3.0
    #: `d`, the incoherence debit, as a multiple of expected pay. §1 gives the
    #: working value `d = 1.4 × E[P/N]`, the ratio v2.1 found viable.
    #: `REVEAL_BOND = LAMBDA = d` (§1, §2.4, §5.2).
    debit_multiple: float = 1.4

    # behaviour
    honest_prior: float = 0.665          # P(honest moderator is right)
    honest_availability: float = 0.80    # P(available inside a 20-minute window)
    #: fraction of honest moderators who are always-on (bots). The rest arrive
    #: uniformly across the commit window, which is what makes §3.3's widening
    #: step (F12) worth measuring.
    honest_always_on: float = 0.30
    attacker_always_on: float = 1.00

    #: `h` — P(the honest side registers a challenge after losing a draw). The
    #: attacker's is 1.0 by assumption.
    honest_challenge_rate: float = 0.5

    max_rounds: int = 2                  # round 0 + one challenge round

    @property
    def n_attackers(self) -> int:
        return int(round(self.n_moderators * self.attacker_share))

    @property
    def expected_share(self) -> float:
        """`E[P/N]` — the pot over expected turnout."""
        return self.fee / max(self.target_cohort * self.honest_availability, 1e-9)

    @property
    def penalty_debit(self) -> float:
        """`d`, derived from expected pay per §1's working value."""
        return self.debit_multiple * self.expected_share

    @property
    def risk_reward_ratio(self) -> float:
        """`d / E[share]`, which is just `debit_multiple`. A chosen constant, and
        that is the whole property §5.1 buys by using balance debits instead of
        time freezes. Under v2's identity-wide freezing it was
        `freeze_days × concurrent_cases`: unbounded when concurrency is, perverse
        in direction, and it produced zero honest turnout at every fee tested."""
        return self.penalty_debit / max(self.expected_share, 1e-9)

    @property
    def confidence_threshold(self) -> float:
        """Below this belief, voting is irrational. `r/(1+r)` for ratio `r`."""
        r = self.risk_reward_ratio
        return r / (1.0 + r)


# ---------------------------------------------------------------------------
# §4.5 — one randomness per claim, evaluated against both tallies
# ---------------------------------------------------------------------------

def draw_tickets(rng: random.Random) -> Tuple[float, float, float]:
    """The three uniforms, realized ONCE at the round-0 draw and stored (§4.5).

    On chain these are `uint128(H(OUTCOME_DOMAIN, …, i))`; here the [0,1) form is
    the same object without the fixed-point noise.
    """
    return (rng.random(), rng.random(), rng.random())


def verdict(u: Tuple[float, float, float], approve: int, total: int) -> bool:
    """Majority of three, evaluated against a tally.

    The comparison is `u[i] < a`, matching the spec's `u·N < approve·2^128` and
    **not** `u mod N < approve`.  Both are uniform and both give `f(a)`; only
    this one is monotone in `a`, which is what makes a challenge that adds no
    votes return an identical verdict (§4.5, I22).
    """
    if total <= 0:
        raise ValueError("verdict() on an empty tally — I11 should have caught this")
    a = approve / total
    return sum(1 for x in u if x < a) >= 2


def f(a: float) -> float:
    """`P(Approve) = 3a² − 2a³`. The marginal distribution `draw_tickets` +
    `verdict` reproduce; kept for closed-form comparison."""
    return 3.0 * a * a - 2.0 * a ** 3


# ---------------------------------------------------------------------------
# behaviour
# ---------------------------------------------------------------------------

def _commits(p: ParamsV3, rng: random.Random, *, threshold_mult: float,
             excluded: set, attacker: bool) -> List[int]:
    """Who commits, for one side, at one eligibility threshold.

    Eligibility is a per-identity Bernoulli — the passive hash test of §3.1.
    Availability is what turns eligibility into a commit, and it is the variable
    §9 says everything is priced on: `x` is the hostile share **of reveals**, not
    of the registry.
    """
    prob = min(1.0, threshold_mult * p.target_cohort / p.n_moderators)
    lo, hi = (0, p.n_attackers) if attacker else (p.n_attackers, p.n_moderators)
    avail = p.attacker_always_on if attacker else p.honest_availability
    out = []
    for i in range(lo, hi):
        if i in excluded:
            continue
        if rng.random() < prob and rng.random() < avail:
            out.append(i)
    return out


def _honest_votes_correct(p: ParamsV3, rng: random.Random, n: int,
                          content_is_safe: bool) -> int:
    """Honest moderators are right with probability `honest_prior`."""
    right = sum(1 for _ in range(n) if rng.random() < p.honest_prior)
    return right if content_is_safe else n - right


@dataclass
class Round:
    commits_honest: int = 0
    commits_attacker: int = 0
    approve: int = 0
    reject: int = 0

    @property
    def commits(self) -> int:
        return self.commits_honest + self.commits_attacker

    @property
    def reveals(self) -> int:
        return self.approve + self.reject


@dataclass
class CaseResult:
    terminal: str                     # APPROVED | REJECTED | UNRESOLVED
    reason: Optional[str] = None      # NO_TURNOUT | WITHHELD | NO_RANDOMNESS
    provisional: Optional[bool] = None
    challenged: bool = False
    rounds: Tuple[Round, ...] = ()
    pooled_approve: int = 0
    pooled_reject: int = 0

    @property
    def approved(self) -> bool:
        return self.terminal == "APPROVED"

    @property
    def reveals(self) -> int:
        return self.pooled_approve + self.pooled_reject


def run_case(p: ParamsV3, rng: random.Random, *, content_is_safe: bool,
             attacker_wants: bool = APPROVE) -> CaseResult:
    """One case, following state-machine-v3 §4.

    `attacker_wants` is the verdict the hostile side is pushing: `APPROVE` for a
    listing attack, `REJECT` for censorship.  They are pay-insensitive and vote
    that way regardless of the content.
    """
    voted: set = set()

    # ---- round 0: COMMIT ------------------------------------------------
    r0 = Round()
    hon = _commits(p, rng, threshold_mult=1.0, excluded=voted, attacker=False)
    att = _commits(p, rng, threshold_mult=1.0, excluded=voted, attacker=True)

    if p.widen_enabled and len(hon) + len(att) < p.min_commits:
        # §3.3 — widening is on a schedule fixed at round open, not conditional
        # on live counts. Modelled as a second pass over the identities the wider
        # threshold admits. F12 asks whether the *marginal* pool is composed like
        # the population: an always-on identity is present at minute 12, an
        # intermittent one may not be.
        extra_excl = voted | set(hon) | set(att)
        hon2 = _commits(p, rng, threshold_mult=p.widen_factor - 1.0,
                        excluded=extra_excl, attacker=False)
        att2 = _commits(p, rng, threshold_mult=p.widen_factor - 1.0,
                        excluded=extra_excl, attacker=True)
        hon += [i for i in hon2 if rng.random() < p.honest_always_on]
        att += [i for i in att2 if rng.random() < p.attacker_always_on]

    r0.commits_honest, r0.commits_attacker = len(hon), len(att)
    voted |= set(hon) | set(att)

    # §4.8 — the gate is on COMMITS, at commit close, before any tally exists.
    if r0.commits < p.min_commits:
        return CaseResult("UNRESOLVED", "NO_TURNOUT", rounds=(r0,))

    # ---- round 0: REVEAL ------------------------------------------------
    # `REVEAL_BOND = d` makes revealing weakly dominant at every belief (§5.2),
    # so honest moderators always reveal. The attacker is modelled the same way;
    # withholding to force WITHHELD is a separate experiment.
    a_hon = _honest_votes_correct(p, rng, len(hon), content_is_safe)
    r0.approve = a_hon + (len(att) if attacker_wants is APPROVE else 0)
    r0.reject = (len(hon) - a_hon) + (0 if attacker_wants is APPROVE else len(att))

    if r0.reveals < p.min_reveals:
        return CaseResult("UNRESOLVED", "WITHHELD", rounds=(r0,))

    # ---- round 0: DRAW --------------------------------------------------
    u = draw_tickets(rng)
    prov = verdict(u, r0.approve, r0.reveals)

    pooled_a, pooled_r = r0.approve, r0.reject

    # ---- challenge window (§3.5, §3.5b) ---------------------------------
    attacker_lost = (prov is not attacker_wants)
    honest_lost = (prov is not content_is_safe)
    challenged = attacker_lost or (honest_lost and rng.random() < p.honest_challenge_rate)

    rounds = (r0,)
    if challenged and p.max_rounds > 1:
        r1 = Round()
        # §3.4 — one vote per CLAIM. Round-0 voters are excluded.
        hon1 = _commits(p, rng, threshold_mult=1.0, excluded=voted, attacker=False)
        att1 = _commits(p, rng, threshold_mult=1.0, excluded=voted, attacker=True)
        r1.commits_honest, r1.commits_attacker = len(hon1), len(att1)
        # §4.9 — no quorum gate in round 1. An empty round is self-healing,
        # because an unchanged tally yields an identical verdict.
        a_hon1 = _honest_votes_correct(p, rng, len(hon1), content_is_safe)
        r1.approve = a_hon1 + (len(att1) if attacker_wants is APPROVE else 0)
        r1.reject = (len(hon1) - a_hon1) + (0 if attacker_wants is APPROVE else len(att1))
        pooled_a += r1.approve
        pooled_r += r1.reject
        rounds = (r0, r1)

    # ---- the binding evaluation (§4.5) — SAME u, pooled tally ------------
    final = verdict(u, pooled_a, pooled_a + pooled_r)
    return CaseResult(
        "APPROVED" if final else "REJECTED",
        provisional=prov, challenged=challenged, rounds=rounds,
        pooled_approve=pooled_a, pooled_reject=pooled_r,
    )


def sweep(p: ParamsV3, **kw) -> ParamsV3:
    return replace(p, **kw)
