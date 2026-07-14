"""Aggregation of many :class:`CaseResult` runs into scenario-level metrics."""

from __future__ import annotations

from dataclasses import dataclass, field
from statistics import mean, pstdev
from typing import Dict, List

from .protocol import CaseResult, Outcome


@dataclass
class Metrics:
    n: int = 0
    correct: int = 0                       # final outcome == honest judgment
    attacker_success: int = 0              # final outcome == attacker target
    depths: List[int] = field(default_factory=list)
    latencies: List[float] = field(default_factory=list)
    # per-faction cumulative money (rewards positive, costs positive)
    rewards: Dict[str, float] = field(default_factory=dict)
    fees: Dict[str, float] = field(default_factory=dict)
    bonds_forfeited: Dict[str, float] = field(default_factory=dict)
    freeze_stake_days: Dict[str, float] = field(default_factory=dict)
    frozen_counts: Dict[str, int] = field(default_factory=dict)

    def add(self, r: CaseResult, attacker_target: Outcome | None = None) -> None:
        self.n += 1
        if r.correct:
            self.correct += 1
        if attacker_target is not None and r.final_outcome == attacker_target:
            self.attacker_success += 1
        self.depths.append(r.depth_reached)
        self.latencies.append(r.latency_days)
        for k, v in r.rewards_earned.items():
            self.rewards[k] = self.rewards.get(k, 0.0) + v
        for k, v in r.fees_paid.items():
            self.fees[k] = self.fees.get(k, 0.0) + v
        for k, v in r.bonds_forfeited.items():
            self.bonds_forfeited[k] = self.bonds_forfeited.get(k, 0.0) + v
        for k, v in r.freeze_stake_days.items():
            self.freeze_stake_days[k] = self.freeze_stake_days.get(k, 0.0) + v
        for k, v in r.n_frozen.items():
            self.frozen_counts[k] = self.frozen_counts.get(k, 0) + v

    # --- derived ---
    def correctness(self) -> float:
        return self.correct / self.n if self.n else 0.0

    def attack_success_rate(self) -> float:
        return self.attacker_success / self.n if self.n else 0.0

    def avg_depth(self) -> float:
        return mean(self.depths) if self.depths else 0.0

    def avg_latency(self) -> float:
        return mean(self.latencies) if self.latencies else 0.0

    def faction_net(self, faction: str) -> float:
        """Net external money for a faction: rewards - fees - forfeited bonds.

        Positive means the faction was paid by the system; negative means it
        funded the system. Frozen stake is NOT counted here (no stake is
        transferred) -- see ``freeze_stake_days`` for the freeze drag.
        """
        return (self.rewards.get(faction, 0.0)
                - self.fees.get(faction, 0.0)
                - self.bonds_forfeited.get(faction, 0.0))

    def summary(self) -> Dict[str, float]:
        return {
            "trials": self.n,
            "correctness": round(self.correctness(), 4),
            "attack_success_rate": round(self.attack_success_rate(), 4),
            "avg_depth": round(self.avg_depth(), 3),
            "avg_latency_days": round(self.avg_latency(), 2),
            "attacker_net": round(self.faction_net("attacker"), 3),
            "honest_net": round(self.faction_net("honest"), 3),
            "attacker_freeze_stake_days": round(self.freeze_stake_days.get("attacker", 0.0), 1),
            "honest_freeze_stake_days": round(self.freeze_stake_days.get("honest", 0.0), 1),
        }
