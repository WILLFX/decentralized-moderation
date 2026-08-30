"""Run the v3 simulation.

    python3 run_v3.py

Answers the open parameters and findings in ``specs/state-machine-v3.md`` §10.
Nothing here validates ``contracts/`` — that Solidity implements the first
architecture and has nothing in common with this one.
"""

from protocol_v3 import ParamsV3
from experiments_v3 import (
    e1_amplifier_crossover, e2_registry_growth, e3_widening_turnout,
    e4_challenge_reliability, e5_viability, e6_honest_accuracy,
)


def main() -> None:
    b = ParamsV3()
    print("=" * 78)
    print("Moderation v3 — three tickets, one randomness, one challenge round")
    print(f"registry={b.n_moderators}  cohort={b.target_cohort}  fee={b.fee}"
          f"  d={b.penalty_debit:.2f} ({b.debit_multiple}x pay)"
          f"  MIN_COMMITS={b.min_commits}")
    print("=" * 78)
    e5_viability(b)
    e1_amplifier_crossover(b)
    e6_honest_accuracy(b)
    e4_challenge_reliability(b)
    e3_widening_turnout(b)
    e2_registry_growth(b)
    print()


if __name__ == "__main__":
    main()
