"""Agent-based simulation of the decentralized moderation protocol (M1).

This package models the on-chain moderation game described in the repository
README and formalized in ``specs/state-machine.md``: stake-weighted subset
draws, stake-proportional probabilistic outcomes, bonded appeals, and
freeze-based settlement with no internal stake transfer. Its purpose is to turn
the README's *working values* into data-backed protocol parameters by running
the adversarial scenarios of README section 7 before any Solidity is written.

The engine is deliberately economic, not cryptographic: commit-reveal is modeled
by its *effect* (independent, hidden votes) rather than by hashing. See
``protocol.py`` for the abstractions and where they diverge from the on-chain
mechanism.
"""

from .params import Params
from .protocol import Moderator, Case, CaseResult, run_case, Outcome
from .campaign import run_campaign

__all__ = [
    "Params",
    "Moderator",
    "Case",
    "CaseResult",
    "run_case",
    "Outcome",
    "run_campaign",
]
