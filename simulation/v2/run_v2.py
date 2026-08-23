"""Run the v2 simulation experiments.

    python3 run_v2.py

Answers the open parameters in ``specs/design-v2.md`` §9. Nothing here validates
the contracts in ``contracts/`` — those implement the first architecture and are
covered by ``../run.py``.
"""

from protocol_v2 import ParamsV2
from campaign_v2 import e6_pre_settlement_leverage
from experiments_v2 import (
    e1_pooling_holds_share,
    e2_dilution,
    e3_fee_sweep,
    e4_round_cap,
    e5_viable_region,
    find_viable,
)


def main() -> None:
    base = ParamsV2()
    print("=" * 78)
    print("Unassigned moderation — v2 simulation")
    print(f"population={base.n_moderators}  cohort={base.target_cohort}"
          f"  fee={base.fee}  gas={base.gas_cost}  max_rounds={base.max_rounds}")
    print("=" * 78)
    e5_viable_region(base)

    viable = find_viable(base)
    print("\n" + "=" * 78)
    print(f"Re-running at a VIABLE point: fee={viable.fee}"
          f"  freeze={viable.freeze_base_days*24:.0f}h"
          f"  (risk/reward {viable.risk_reward_ratio:.2f})")
    print("Everything below is meaningless at the defaults, where nobody votes.")
    print("=" * 78)
    e1_pooling_holds_share(viable)
    e2_dilution(viable)
    e4_round_cap(viable)
    e6_pre_settlement_leverage()
    print()


if __name__ == "__main__":
    main()
