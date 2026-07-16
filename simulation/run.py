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
from dataclasses import replace
from statistics import mean, pstdev

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
    _print_summary(f"whale (attacker_frac={args.frac}, difficulty={args.difficulty})", s)
    return s


def cmd_whale_sweep(p: Params, args) -> dict:
    out = {}
    tr = args.trials
    print("\n=== whale sweep: attack success (mean±sd, 5 seeds) vs stake share ===")
    print("  clear content (difficulty 0), full honest liveness")
    print(f"  {'frac':>6} {'success':>16} {'attacker_net/case':>20}")
    for frac in (0.2, 0.35, 0.5, 0.6, 0.75, 0.9):
        r = sc.whale_multiseed(p, attacker_frac=frac, trials=tr, seeds=5)
        out[f"frac_{frac}"] = r
        print(f"  {frac:>6.2f}   {r['success_mean']:.3f}±{r['success_sd']:.3f}      "
              f"{r['attacker_net_mean']:>+8.3f}±{r['attacker_net_sd']:.3f}")

    print("\n  a MINORITY whale (frac 0.35) is not powerless: success rises with")
    print("  content difficulty (attacker picks borderline) and honest offline share")
    print(f"  {'difficulty':>10} | {'online 1.0':>11} {'online 0.5':>11} {'online 0.3':>11}")
    grid = {}
    for diff in (0.0, 0.25, 0.5):
        row = []
        for onl in (1.0, 0.5, 0.3):
            r = sc.whale_multiseed(p, attacker_frac=0.35, difficulty=diff,
                                   honest_online=onl, trials=tr, seeds=5)
            row.append(r["success_mean"])
            grid[f"d{diff}_o{onl}"] = r
        print(f"  {diff:>10.2f} | {row[0]:>11.3f} {row[1]:>11.3f} {row[2]:>11.3f}")
    out["liveness_difficulty_grid"] = grid
    return out


def cmd_naive(p: Params, args) -> dict:
    out = {}
    print("\n=== naive appellants: attacker net/case vs share of naive honest challengers ===")
    print("  frac-0.6 whale on clear content; a naive honest challenger appeals any")
    print("  wrong approval regardless of seat share, so its lost bonds can feed the whale")
    print(f"  {'naive_frac':>10} {'attacker_net/case':>20} {'attack_success':>15}")
    for nf in (0.0, 0.25, 0.5, 1.0):
        pp = replace(p, naive_appeal_frac=nf)
        r = sc.whale_multiseed(pp, attacker_frac=0.6, trials=args.trials, seeds=5)
        out[f"naive_{nf}"] = r
        print(f"  {nf:>10.2f}   {r['attacker_net_mean']:>+8.3f}±{r['attacker_net_sd']:.3f} "
              f"    {r['success_mean']:>11.3f}")
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
    fz = sc.honest_freeze_duration_stats(p)
    out["honest_freeze_duration_days"] = fz
    print(f"\n  honest freeze duration on borderline content, veteran network (principle-1):")
    print(f"    mean={fz['mean_days']}d  p95={fz['p95_days']}d  max={fz['max_days']}d  "
          f"({'OK: p95 <= 21d' if fz['p95_days'] <= 21 else 'FLAG: p95 > 21d'})")
    return out


def _seed_stats(fn, seeds, seed0, metric):
    vals = [metric(fn(seed0 + s)) for s in range(seeds)]
    return mean(vals), (pstdev(vals) if seeds > 1 else 0.0)


def cmd_honest(p: Params, args) -> dict:
    out = {}
    tr = max(args.trials // 2, 400)
    print("\n=== honest_earnings: net/case & correctness by difficulty (mean±sd, 5 seeds) ===")
    print(f"  {'difficulty':>10} {'correctness':>16} {'honest_net/case':>18} {'frz/case':>10}")
    for d in (0.0, 0.25, 0.5, 0.75):
        runs = [sc.honest_earnings(p, difficulty=d, trials=tr, seed=args.seed + s)
                for s in range(5)]
        cm, cs = mean(m.correctness() for m in runs), pstdev(m.correctness() for m in runs)
        nm, ns = mean(m.net_per_case("honest") for m in runs), pstdev(m.net_per_case("honest") for m in runs)
        frz = mean(m.freeze_per_case("honest") for m in runs)
        out[f"difficulty_{d}"] = {"correctness": (cm, cs), "honest_net_per_case": (nm, ns),
                                  "honest_freeze_per_case": frz}
        print(f"  {d:>10.2f}   {cm:.3f}±{cs:.3f}    {nm:>+8.4f}±{ns:.4f}   {frz:>10.1f}")

    print("\n  correlated honest error (difficulty 0.3): correctness vs error_correlation")
    print("  (i.i.d. errors wash out in a plurality; a shared blind spot does not)")
    for ec in (0.0, 0.25, 0.5):
        pp = replace(p, error_correlation=ec)
        cm, cs = _seed_stats(lambda s: sc.honest_earnings(pp, difficulty=0.3, trials=tr, seed=s),
                             5, args.seed, lambda m: m.correctness())
        out[f"error_correlation_{ec}"] = (cm, cs)
        print(f"  error_correlation={ec:<4} correctness={cm:.3f}±{cs:.3f}")
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
    print("\n=== copy/correlated voting ===")
    print("  no attacker: correctness vs copy-voter share (difficulty 0.1)")
    for lf in (0.0, 0.25, 0.5, 0.75, 0.95):
        m = sc.copy_voting(p, lazy_frac=lf, trials=args.trials, seed=args.seed)
        out[f"lazy_frac_{lf}"] = {"correctness": m.correctness()}
        print(f"    copy_frac={lf:<5} correctness={m.correctness():.3f}")
    print("\n  whale x copy: does a copy-voting honest side help a 20% attacker? (success)")
    for lf in (0.0, 0.5, 0.9):
        r = sc.whale_multiseed(p, attacker_frac=0.2, difficulty=0.1, lazy_frac=lf,
                               trials=args.trials, seeds=5)
        out[f"whale_copy_{lf}"] = r
        print(f"    copy_frac={lf:<5} attack_success={r['success_mean']:.3f}±{r['success_sd']:.3f}")
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
        "naive_appellants": cmd_naive(p, args),
        "track_farming": cmd_track_farming(p, args),
        "honest_earnings": cmd_honest(p, args),
        "fee_floor": cmd_fee_floor(p, args),
        "copy_voting": cmd_copy(p, args),
        "underparticipation": cmd_underparticipation(p, args),
    }


COMMANDS = {
    "whale": cmd_whale,
    "whale-sweep": cmd_whale_sweep,
    "naive": cmd_naive,
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
