#!/usr/bin/env python3
"""CLI for the moderation protocol simulation (M1).

Examples:
    python run.py whale --frac 0.5
    python run.py whale-sweep
    python run.py honest
    python run.py all
    python run.py all --json results.json

Run ``python run.py --help`` for the full list. All scenarios are seeded, so
runs are reproducible; pass --seed to vary.
"""

from __future__ import annotations

import argparse
import json
import sys

from moderation_sim import Params
from moderation_sim import scenarios as sc
from moderation_sim.protocol import Outcome


def _print_summary(title: str, summary: dict) -> None:
    print(f"\n=== {title} ===")
    width = max(len(k) for k in summary)
    for k, v in summary.items():
        print(f"  {k:<{width}} : {v}")


def cmd_whale(p: Params, args) -> dict:
    m = sc.whale(p, attacker_frac=args.frac, honest_track=args.track,
                 difficulty=args.difficulty, trials=args.trials, seed=args.seed)
    s = m.summary()
    _print_summary(f"whale (attacker_frac={args.frac}, honest_track={args.track})", s)
    return s


def cmd_whale_sweep(p: Params, args) -> dict:
    out = {}
    print("\n=== whale sweep: attack success & attacker net vs stake share ===")
    print(f"  {'frac':>6} | {'newcomer_success':>16} {'net':>9} | "
          f"{'veteran_success':>15} {'net':>9} {'frz(k·d)':>10}")
    for frac in (0.2, 0.35, 0.5, 0.6, 0.75, 0.9):
        newc = sc.whale(p, attacker_frac=frac, honest_track=0.0,
                        trials=args.trials, seed=args.seed).summary()
        vet = sc.whale(p, attacker_frac=frac, honest_track=15.0,
                       trials=args.trials, seed=args.seed + 1).summary()
        out[f"frac_{frac}"] = {"newcomer": newc, "veteran": vet}
        print(f"  {frac:>6.2f} | {newc['attack_success_rate']:>16.3f} "
              f"{newc['attacker_net']:>9.2f} | {vet['attack_success_rate']:>15.3f} "
              f"{vet['attacker_net']:>9.2f} {vet['attacker_freeze_stake_days']:>10.0f}")
    return out


def cmd_bond_war(p: Params, args) -> dict:
    m = sc.bond_war(p, attacker_frac=args.frac, trials=args.trials, seed=args.seed)
    s = m.summary()
    _print_summary(f"bond_war (attacker_frac={args.frac})", s)
    return s


def cmd_track_farming(p: Params, args) -> dict:
    print("\n=== track_farming (campaign mode: farm then attack, freeze bites) ===")
    print(f"  (averaged over 8 campaign seeds; uplift = farmed − control attack success)")
    print(f"  {'identity_stake':>14} {'farm_cost':>10} {'mean_track':>11} "
          f"{'power':>7} {'succ_farm':>10} {'succ_ctrl':>10} {'uplift':>9} {'±sd':>7}")
    out = {}
    for ident in (100.0, 1000.0, args.frac * 8000.0):  # split .. concentrated
        res = sc.track_farming(p, farm_cases=args.farm_cases, attacker_frac=args.frac,
                               identity_stake=ident, seeds=8)
        out[f"identity_{ident:.0f}"] = res
        print(f"  {ident:>14.0f} {res['farm_net_cost_xbzz']:>10.2f} "
              f"{res['attacker_mean_track']:>11.2f} {res['freezing_power_gained']:>7.2f} "
              f"{res['attack_success_farmed']:>10.3f} {res['attack_success_control']:>10.3f} "
              f"{res['success_uplift']:>+9.3f} {res['success_uplift_sd']:>7.3f}")
    return out


def cmd_honest(p: Params, args) -> dict:
    out = {}
    print("\n=== honest_earnings: net reward per case, by difficulty ===")
    for d in (0.0, 0.25, 0.5, 0.75):
        m = sc.honest_earnings(p, difficulty=d, trials=args.trials, seed=args.seed)
        s = m.summary()
        per_case = round(s["honest_net"] / s["trials"], 4)
        out[f"difficulty_{d}"] = {**s, "honest_net_per_case": per_case}
        print(f"  difficulty={d:<4}  correctness={s['correctness']:.3f}  "
              f"honest_net_per_case={per_case:+.4f}  "
              f"honest_frozen_stake_days={s['honest_freeze_stake_days']:.1f}")
    return out


def cmd_fee_floor(p: Params, args) -> dict:
    rows = sc.fee_floor(margin=args.margin, trials=args.trials, seed=args.seed)
    print("\n=== fee_floor: minimum fee derived from per-vote operating cost ===")
    print(f"  (voter_pay = {args.margin}x op cost; Gnosis gas at CostModel defaults)")
    print(f"  {'op_cost':>9} {'min_fee':>9} {'fee_usd':>8} {'gas_share':>10} "
          f"{'honest_net/case':>16} {'clears?':>8}")
    for r in rows:
        print(f"  {r['op_cost_per_vote_xbzz']:>9.4f} {r['min_fee_xbzz']:>9.4f} "
              f"{r['min_fee_usd']:>8.4f} {r['gas_share_of_fee']:>10.5f} "
              f"{r['honest_net_per_case_xbzz']:>16.5f} "
              f"{'yes' if r['moderators_clear_costs'] else 'NO':>8}")
    return {"rows": rows}


def cmd_copy(p: Params, args) -> dict:
    out = {}
    print("\n=== copy_voting: correctness vs copy-voter share (difficulty=0.1) ===")
    for lf in (0.0, 0.25, 0.5, 0.75, 0.95):
        m = sc.copy_voting(p, lazy_frac=lf, trials=args.trials, seed=args.seed)
        s = m.summary()
        out[f"lazy_frac_{lf}"] = s
        print(f"  copy_frac={lf:<5} correctness={s['correctness']:.3f}")
    return out


def cmd_underparticipation(p: Params, args) -> dict:
    out = {}
    print("\n=== underparticipation: correctness/latency vs online share ===")
    for of in (1.0, 0.5, 0.3, 0.15, 0.08):
        m = sc.underparticipation(p, online_frac=of, trials=args.trials, seed=args.seed)
        s = m.summary()
        out[f"online_frac_{of}"] = s
        print(f"  online={of:<5} correctness={s['correctness']:.3f}  "
              f"avg_latency_days={s['avg_latency_days']:.2f}")
    return out


def cmd_all(p: Params, args) -> dict:
    return {
        "whale_sweep": cmd_whale_sweep(p, args),
        "track_farming": cmd_track_farming(p, args),
        "honest_earnings": cmd_honest(p, args),
        "fee_floor": cmd_fee_floor(p, args),
        "copy_voting": cmd_copy(p, args),
        "underparticipation": cmd_underparticipation(p, args),
    }


COMMANDS = {
    "whale": cmd_whale,
    "whale-sweep": cmd_whale_sweep,
    "bond-war": cmd_bond_war,
    "track-farming": cmd_track_farming,
    "honest": cmd_honest,
    "fee-floor": cmd_fee_floor,
    "copy": cmd_copy,
    "underparticipation": cmd_underparticipation,
    "all": cmd_all,
}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=sorted(COMMANDS), help="scenario to run")
    ap.add_argument("--trials", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--frac", type=float, default=0.5, help="attacker stake share")
    ap.add_argument("--track", type=float, default=0.0, help="honest track record")
    ap.add_argument("--difficulty", type=float, default=0.0)
    ap.add_argument("--farm-cases", type=int, default=30)
    ap.add_argument("--margin", type=float, default=1.5,
                    help="voter pay as a multiple of per-vote op cost (fee-floor)")
    ap.add_argument("--json", type=str, default=None, help="write results as JSON")
    ap.add_argument("--track-saturation", type=float, default=None,
                    help="override Params.track_saturation (freeze calibration)")
    ap.add_argument("--track-decay", type=float, default=None,
                    help="override Params.track_decay (freeze calibration)")
    args = ap.parse_args(argv)

    p = Params()
    if args.track_saturation is not None:
        p.track_saturation = args.track_saturation
    if args.track_decay is not None:
        p.track_decay = args.track_decay

    result = COMMANDS[args.command](p, args)

    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
