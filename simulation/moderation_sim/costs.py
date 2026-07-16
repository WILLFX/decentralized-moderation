"""Cost model for the submission fee floor (README P8, spec §11.5).

The contract enforces ``minFee = FEE_BASE + FEE_PER_TOPIC * nTopics``, which must
cover two real costs:

  1. **Protocol gas** — the storage the approval writes (the topic -> entry index
     write, plus submission bookkeeping) on Gnosis Chain.
  2. **Minimum voter pay** — enough that the cheapest viable moderator (an AI
     classifier) clears its per-judgment operating cost and participates.

This module turns assumptions about those two costs into concrete `FEE_BASE` /
`FEE_PER_TOPIC` values, all in xBZZ. Every assumption is an explicit field so the
floor can be swept rather than asserted. The load-bearing unknown is
``op_cost_per_vote_xbzz`` — the real cost of running one moderation judgment —
which the ``fee-floor`` scenario sweeps.

Reality check baked in: Gnosis gas is so cheap that the gas term is negligible
next to voter pay. The fee floor is, to first order, ``nSeats * voter_pay``.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class CostModel:
    # --- protocol gas (Gnosis Chain) ---
    # Rough SSTORE-based estimates for the approval write. An index Entry is
    # ~3 new storage words (contentHash, metaHash, packed approvalTime+flag+caseId)
    # plus array/length overhead; base covers the dedup key and case bookkeeping.
    storage_gas_base: float = 45_000       # per submission, independent of topics
    storage_gas_per_topic: float = 65_000  # per topic written to the index
    gas_price_gwei: float = 1.5            # typical Gnosis gas price

    # --- prices (for converting gas in xDAI to the xBZZ-denominated fee) ---
    xbzz_usd: float = 0.20                 # assumed xBZZ price (volatile — a knob)
    xdai_usd: float = 1.00                 # xDAI is a USD stablecoin on Gnosis

    # --- moderator economics ---
    op_cost_per_vote_xbzz: float = 0.02    # THE unknown: cost of one judgment
    voter_pay_margin: float = 1.5          # voter_pay = margin * op cost (>1 to profit)
    counted_seats_depth0: int = 5          # COMMIT_TARGET[0]; voters paid at depth 0

    # --- gas -> xBZZ ---
    def gas_to_xbzz(self, gas: float) -> float:
        cost_xdai = gas * self.gas_price_gwei * 1e-9      # gwei -> xDAI
        cost_usd = cost_xdai * self.xdai_usd
        return cost_usd / self.xbzz_usd

    def storage_cost_xbzz(self, n_topics: int) -> float:
        return self.gas_to_xbzz(self.storage_gas_base
                                + n_topics * self.storage_gas_per_topic)

    # --- fee floor ---
    def voter_pay(self) -> float:
        return self.voter_pay_margin * self.op_cost_per_vote_xbzz

    def fee_base(self) -> float:
        """FEE_BASE: minimum voter pay for the depth-0 panel + fixed gas."""
        return (self.counted_seats_depth0 * self.voter_pay()
                + self.gas_to_xbzz(self.storage_gas_base))

    def fee_per_topic(self) -> float:
        """FEE_PER_TOPIC: marginal gas of one extra index write."""
        return self.gas_to_xbzz(self.storage_gas_per_topic)

    def min_fee(self, n_topics: int) -> float:
        return self.fee_base() + self.fee_per_topic() * n_topics

    # --- breakdown, for reporting ---
    def breakdown(self, n_topics: int = 1) -> dict:
        voter_total = self.counted_seats_depth0 * self.voter_pay()
        gas_total = self.storage_cost_xbzz(n_topics)
        fee = voter_total + gas_total
        return {
            "op_cost_per_vote_xbzz": round(self.op_cost_per_vote_xbzz, 6),
            "voter_pay_xbzz": round(self.voter_pay(), 6),
            "voter_pay_total_xbzz": round(voter_total, 6),
            "gas_cost_xbzz": round(gas_total, 6),
            "gas_share_of_fee": round(gas_total / fee, 5) if fee else 0.0,
            "min_fee_xbzz": round(fee, 6),
            "min_fee_usd": round(fee * self.xbzz_usd, 5),
        }
