"""Protocol parameters.

Every field here corresponds to a symbol in ``specs/state-machine.md`` section 1.
The defaults are the README's *working values*; the whole point of the M1
simulation is to sweep these and replace the defaults with values justified by
the adversarial scenarios. Nothing here is a final protocol parameter.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass
class Params:
    # --- staking ---
    min_stake: float = 10.0            # MIN_STAKE (xBZZ)

    # --- subset / voting ---
    # Counted votes per depth (COMMIT_TARGET). Index = appeal depth.
    commit_target: List[int] = field(default_factory=lambda: [5, 11, 23])
    min_reveals: int = 3               # MIN_REVEALS
    max_widen: int = 3                 # bounded widen retries on under-participation

    # Voting is FLAT: every counted seat is worth one vote, and the outcome is
    # drawn in proportion to the seat counts behind each side. Stake buys
    # selection frequency (with-replacement seat draws), not vote weight —
    # resolving the double-count that stake-weighted selection plus a
    # stake-weighted tally produced (spec §11.6, design review). No weight knob.

    # --- appeals ---
    max_depth: int = 3                 # MAX_DEPTH
    bond_multiplier: float = 2.0       # BOND_MULTIPLIER (bond >= 2x prev reward)
    # A rational appellant only bonds when the outcome looks overturnable, judged
    # by its own side's revealed seat share in the round just decided. Appealing
    # a round its side barely showed up in is -EV: it just funds the winners.
    honest_appeal_threshold: float = 0.50
    attacker_appeal_threshold: float = 0.40
    # Appeal windows per depth (days). Only used for latency accounting.
    appeal_window_days: List[float] = field(default_factory=lambda: [4.0, 3.0, 3.0])

    # --- settlement ---
    claim_bounty_frac: float = 0.01    # CLAIM_BOUNTY as fraction of pot
    winning_appellant_bonus_frac: float = 0.10  # bonus to a vindicated appellant

    # --- freezing ---
    freeze_base_days: float = 7.0      # FREEZE_BASE
    freeze_cap: float = 8.0            # FREEZE_CAP (max multiplier on base)
    track_saturation: float = 20.0     # TRACK_SAT (track count for ~cap power)
    track_decay: float = 0.98          # TRACK_DECAY (per-case multiplicative decay)
    failed_reveal_freeze_days: float = 1.0  # brief freeze for commit-and-vanish

    # --- fees (P8: minFee = base + perTopic * nTopics) ---
    fee_base: float = 1.0              # FEE_BASE
    fee_per_topic: float = 0.5         # FEE_PER_TOPIC
    max_topics: int = 5                # MAX_TOPICS
    # Operating cost a moderator pays per judgment (per case it votes in) —
    # e.g. an AI classifier call. Default 0 leaves existing scenarios unchanged;
    # the fee-floor model (costs.py) sets it to price the fee floor.
    op_cost_per_vote: float = 0.0

    # --- randomness / latency (informational in the sim) ---
    supersafe_age_hours: float = 96.0  # SUPERSAFE_AGE

    def min_fee(self, n_topics: int) -> float:
        return self.fee_base + self.fee_per_topic * n_topics

    def counted_target(self, depth: int) -> int:
        """COMMIT_TARGET[depth], clamped to the last defined depth."""
        return self.commit_target[min(depth, len(self.commit_target) - 1)]
