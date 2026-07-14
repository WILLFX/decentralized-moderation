"""Voting strategies (agent behaviours).

Each function has signature ``(mod, case, rng) -> Outcome`` and is assigned to a
Moderator's ``vote_fn``. They encode the behaviours the M1 attack scenarios need
to price:

  * honest       -- judge the guidelines, erring more on borderline content
  * attacker     -- always vote the attacker's target outcome
  * lazy_copy    -- copy the running plurality (models broken commit-reveal /
                    copy-voting and first-come racing, README §7)
  * always       -- a constant-vote agent, for stress tests
"""

from __future__ import annotations

import random

from .protocol import Moderator, Case, Outcome, honest_vote

# re-export the engine default so callers have one import site
honest = honest_vote


def attacker_for(target: Outcome):
    """An agent that always votes ``target`` regardless of the content."""
    def _vote(mod: Moderator, case: Case, rng: random.Random) -> Outcome:
        return target
    return _vote


def lazy_copy(mod: Moderator, case: Case, rng: random.Random) -> Outcome:
    """Copy the running plurality of votes already cast this round.

    With no prior votes to copy, falls back to an honest read. This models the
    copy-voting / first-come racing failure mode that commit-reveal is meant to
    prevent: if independence breaks, the first vote can cascade.
    """
    partial = case.partial_votes
    if not partial:
        return honest_vote(mod, case, rng)
    approve = sum(1 for v in partial if v == Outcome.APPROVE)
    reject = len(partial) - approve
    if approve == reject:
        return partial[0]
    return Outcome.APPROVE if approve > reject else Outcome.REJECT


def constant(value: Outcome):
    def _vote(mod: Moderator, case: Case, rng: random.Random) -> Outcome:
        return value
    return _vote
