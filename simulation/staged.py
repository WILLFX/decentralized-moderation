"""Staged committees: does hiding the second committee defeat selective capture?

This is the measurement asked for directly, and never run:

    Conditional on the attacker obtaining a favourable first committee, what is
    the distribution of the final pooled vote — and how does that change when the
    second committee is selected only *after* the first has committed?

Four architectures, same population, same draw rule, same honest behaviour:

    A  one committee per round                (what the repository implements)
    B  two committees, first tally VISIBLE    (the naive two-stage)
    C  two committees, staged and HIDDEN      (the proposal)
    D  C, plus challenge rounds               (the proposal, complete)

The decided design for D, which differs from what the repository implements and
is the thing this run exists to evaluate:

  * the preliminary outcome is **published** after each pair reveals;
  * a challenge is a **public vote opposite** that outcome, so it discloses its
    direction and costs an ordinary vote liability;
  * tickets are drawn **fresh each round** over the pooled tally so far;
  * at most ``max_challenges`` challenges.

Retry is therefore bounded by the cap rather than by monotonicity. That is the
trade this run has to price: fresh draws restore uncertainty for the new
participants and, in the same motion, hand a losing attacker another draw.

Two modelling choices carry the result and both are stated rather than buried.

**Eligibility is publicly computable.** ``hash(case, moderator, seed)`` under a
public threshold means every party can enumerate its own eligible identities the
moment the seed exists. "A favourable first committee" is therefore *observed*,
not inferred — which is what makes selective capture a strategy at all, and what
staging is meant to break.

**The attacker is pay-insensitive.** Their prize is the listing, external to the
protocol, so cost never deters a vote. Honest moderators attend and vote their
reading — the optimistic case.

**WARNING on ``selective=True``.** That mode has the attacker decline to commit
in a committee that comes out unfavourable, and drops the case from the
denominator when they decline everywhere. **It is a dominated strategy and no
reported figure should use it.** Declining removes the attacker's own votes and
leaves the honest ones in the pooled tally, which lowers their share: with C1 at
10 attackers + 10 honest and C2 at 2 + 18, voting everywhere gives 12/40 = 30%
and voting only in C1 gives 10/38 = 26%. There is also no "abandon" — the fee is
paid and the case runs regardless. It is retained only so the error recorded in
``FINDINGS-staged.md`` §E can be re-derived. **Pass ``selective=False``.**
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from protocol_v3 import a_hat, draw_tickets, f, verdict

APPROVE, REJECT = True, False


@dataclass(frozen=True)
class StagedParams:
    n_moderators: int = 1000
    attacker_share: float = 0.30

    #: expected eligible identities *per committee*. Two staged committees of 20
    #: and one committee of 40 put the same number of reviewers on a case, which
    #: is what makes A and C comparable at equal cost.
    target_cohort: int = 20

    honest_prior: float = 0.665
    honest_availability: float = 0.80

    #: P(an honest voter who can see a leading tally votes with it rather than
    #: their own reading). The economic feedback problem: coherence pays, so
    #: following the visible majority is the profitable move. Only architecture
    #: B exposes a tally to vote against.
    conformity: float = 0.35

    #: P(the honest side registers a challenge after a wrong preliminary
    #: outcome). The attacker's is 1.0 — they always challenge a loss.
    honest_challenge_rate: float = 0.50

    max_challenges: int = 2

    #: an attempt is "favourable" when the attacker holds at least this share of
    #: the committee that has actually committed.
    favourable_at: float = 0.50

    @property
    def n_attackers(self) -> int:
        return int(round(self.n_moderators * self.attacker_share))

    @property
    def n_honest(self) -> int:
        return self.n_moderators - self.n_attackers

    @property
    def p_eligible(self) -> float:
        return min(1.0, self.target_cohort / max(self.n_moderators, 1))


@dataclass
class Committee:
    """One drawn cohort, after attendance but before votes are read."""

    attackers: int
    honest: int

    @property
    def size(self) -> int:
        return self.attackers + self.honest

    @property
    def attacker_share(self) -> float:
        return self.attackers / self.size if self.size else 0.0


def _binomial(rng: random.Random, n: int, p: float) -> int:
    if p <= 0.0 or n <= 0:
        return 0
    if p >= 1.0:
        return n
    return sum(1 for _ in range(n) if rng.random() < p)


def draw_committee(p: StagedParams, rng: random.Random) -> Committee:
    """Eligibility is per identity and independent, so the cohort is binomial.

    Attackers are always-on: every eligible attacker identity commits. Honest
    identities commit only if available inside the window.
    """
    att = _binomial(rng, p.n_attackers, p.p_eligible)
    hon_elig = _binomial(rng, p.n_honest, p.p_eligible)
    hon = _binomial(rng, hon_elig, p.honest_availability)
    return Committee(attackers=att, honest=hon)


def _votes(
    p: StagedParams,
    rng: random.Random,
    c: Committee,
    *,
    content_is_safe: bool,
    attackers_vote: Optional[bool],
    visible_lead: Optional[bool] = None,
) -> Tuple[int, int]:
    """Return ``(approve, reject)`` for one committee.

    ``attackers_vote`` is ``None`` when the attacker declines to commit in this
    committee — the selective strategy. ``visible_lead`` is the side a voter can
    see leading; where it is not ``None`` an honest voter follows it with
    probability ``conformity`` instead of voting their own reading.
    """
    approve = reject = 0

    if attackers_vote is not None:
        if attackers_vote is APPROVE:
            approve += c.attackers
        else:
            reject += c.attackers

    for _ in range(c.honest):
        if visible_lead is not None and rng.random() < p.conformity:
            read = visible_lead
        else:
            correct = rng.random() < p.honest_prior
            # the correct vote is Approve exactly when the content is safe
            read = content_is_safe if correct else (not content_is_safe)
        if read is APPROVE:
            approve += 1
        else:
            reject += 1

    return approve, reject


def _draw_verdict(rng: random.Random, approve: int, reject: int) -> bool:
    total = approve + reject
    if total == 0:
        return REJECT
    return verdict(draw_tickets(rng), approve, total)


@dataclass
class Outcome:
    admitted: bool
    approve: int
    reject: int
    rounds: int
    #: committees the attacker actually committed votes into
    attacker_committed: int
    #: committees drawn — what an attempt costs in review effort
    committees_drawn: int


def run_one(
    p: StagedParams,
    rng: random.Random,
    *,
    arch: str,
    content_is_safe: bool = False,
    selective: bool = True,
) -> Optional[Outcome]:
    """One attempt. Returns ``None`` when the attacker abandons before voting.

    The attacker attacks unsafe content toward Approve. ``content_is_safe`` is
    carried so the same engine measures censorship (attacker drives Reject on
    safe content) without a second code path.
    """
    attack_dir = APPROVE if not content_is_safe else REJECT

    c1 = draw_committee(p, rng)
    drawn = 1

    if arch == "A":
        # One committee. Its composition is public before anyone commits, so a
        # selective attacker abandons an unfavourable draw at no vote cost.
        if selective and c1.attacker_share < p.favourable_at:
            return None
        a, r = _votes(p, rng, c1, content_is_safe=content_is_safe,
                      attackers_vote=attack_dir)
        return Outcome(_draw_verdict(rng, a, r), a, r, 1, 1, drawn)

    # ---- two-committee architectures -------------------------------------
    # B and C differ in ONE respect: whether committee 2 can see committee 1's
    # tally while voting. In both, committee 1's composition is public before
    # committee 1 commits.
    c1_favourable = c1.attacker_share >= p.favourable_at

    if arch == "B":
        # First tally visible. The attacker commits in C1 when favourable, and
        # C2's honest members can see the lead they produced.
        att1 = attack_dir if (c1_favourable or not selective) else None
        if selective and not c1_favourable:
            # abandon before committing: C2 is knowable only after C1 closes, so
            # nothing is gained by paying into a bad first committee
            return None
        a1, r1 = _votes(p, rng, c1, content_is_safe=content_is_safe,
                        attackers_vote=att1)
        c2 = draw_committee(p, rng)
        drawn += 1
        lead = APPROVE if a1 > r1 else REJECT
        a2, r2 = _votes(p, rng, c2, content_is_safe=content_is_safe,
                        attackers_vote=attack_dir, visible_lead=lead)
        a, r = a1 + a2, r1 + r2
        return Outcome(_draw_verdict(rng, a, r), a, r, 1, 2, drawn)

    # arch C and D: staged. C2 is selected only after C1's commitments close,
    # and neither committee sees the other's votes before the joint reveal.
    #
    # The attacker has two selective strategies and takes the better one:
    #   (i)  commit in C1 when C1 is favourable, accepting an unknown C2;
    #   (ii) skip C1 entirely, wait for C2, commit only if C2 is favourable.
    # Staging blocks (i). It does not block (ii) — which is the residual attack,
    # and the reason this run reports `attacker_committed`.
    att1 = attack_dir if (c1_favourable or not selective) else None
    a1, r1 = _votes(p, rng, c1, content_is_safe=content_is_safe,
                    attackers_vote=att1)

    c2 = draw_committee(p, rng)
    drawn += 1
    c2_favourable = c2.attacker_share >= p.favourable_at
    # committing in C2 is free of C1's outcome: no tally is visible yet
    att2 = attack_dir if (c2_favourable or not selective) else None
    a2, r2 = _votes(p, rng, c2, content_is_safe=content_is_safe,
                    attackers_vote=att2)

    committed = int(att1 is not None) + int(att2 is not None)
    if selective and committed == 0:
        return None

    a, r = a1 + a2, r1 + r2

    if arch == "C":
        return Outcome(_draw_verdict(rng, a, r), a, r, 1, committed, drawn)

    # ---- D: the full proposal, with challenge rounds ----------------------
    if arch != "D":
        raise ValueError(f"unknown architecture {arch!r}")

    rounds = 1
    admitted = _draw_verdict(rng, a, r)

    for _ in range(p.max_challenges):
        # A challenge is a public vote OPPOSITE the published outcome. The side
        # that lost the draw is the side that may challenge.
        attacker_lost = admitted is not attack_dir
        if attacker_lost:
            challenges = True          # pay-insensitive: always challenges
            challenger_vote = attack_dir
        else:
            challenges = rng.random() < p.honest_challenge_rate
            # the honest challenger votes against the outcome, which on unsafe
            # content admitted is the correct direction
            challenger_vote = not admitted
        if not challenges:
            break

        if challenger_vote is APPROVE:
            a += 1
        else:
            r += 1

        c3 = draw_committee(p, rng)
        c4 = draw_committee(p, rng)
        drawn += 2
        for c in (c3, c4):
            fav = c.attacker_share >= p.favourable_at
            att = attack_dir if (fav or not selective) else None
            if att is not None:
                committed += 1
            ca, cr = _votes(p, rng, c, content_is_safe=content_is_safe,
                            attackers_vote=att)
            a += ca
            r += cr

        rounds += 1
        # FRESH tickets over the pooled tally — the decided fork. This is the
        # extra draw the cap has to pay for.
        admitted = _draw_verdict(rng, a, r)

    return Outcome(admitted, a, r, rounds, committed, drawn)


def campaign(
    p: StagedParams,
    *,
    arch: str,
    trials: int,
    seed: int = 0,
    content_is_safe: bool = False,
    selective: bool = True,
) -> Dict[str, float]:
    """Run ``trials`` attempts and report per-attempt and per-attack rates."""
    rng = random.Random(seed)
    proceeded = 0
    admitted = 0
    approves: List[int] = []
    rejects: List[int] = []
    rounds_total = 0
    committed_total = 0
    drawn_total = 0

    for _ in range(trials):
        out = run_one(p, rng, arch=arch, content_is_safe=content_is_safe,
                      selective=selective)
        if out is None:
            continue
        proceeded += 1
        admitted += int(out.admitted is (APPROVE if not content_is_safe else REJECT))
        approves.append(out.approve)
        rejects.append(out.reject)
        rounds_total += out.rounds
        committed_total += out.attacker_committed
        drawn_total += out.committees_drawn

    if proceeded == 0:
        return {"proceed_rate": 0.0, "admit_given_proceed": 0.0,
                "admit_per_trial": 0.0, "mean_approve": 0.0,
                "mean_reject": 0.0, "mean_rounds": 0.0,
                "mean_committed": 0.0, "mean_drawn": 0.0}

    return {
        "proceed_rate": proceeded / trials,
        "admit_given_proceed": admitted / proceeded,
        "admit_per_trial": admitted / trials,
        "mean_approve": sum(approves) / proceeded,
        "mean_reject": sum(rejects) / proceeded,
        "mean_rounds": rounds_total / proceeded,
        "mean_committed": committed_total / proceeded,
        "mean_drawn": drawn_total / proceeded,
    }


def attempts_for_confidence(per_attempt: float, confidence: float = 0.95) -> float:
    """Attempts needed for at least one success with probability ``confidence``.

    The campaign-scale question. Independence across attempts is assumed, which
    flatters the defence rather than the attacker: correlated content classes
    only make this smaller.
    """
    import math

    if per_attempt <= 0.0:
        return float("inf")
    if per_attempt >= 1.0:
        return 1.0
    return math.log(1.0 - confidence) / math.log(1.0 - per_attempt)
