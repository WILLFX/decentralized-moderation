"""The four experiments the v2 design's open parameters depend on.

Each maps to a question in ``specs/design-v2.md`` §9. Run with ``python run_v2.py``.
"""

from __future__ import annotations

import random
import statistics
from dataclasses import replace
from typing import Dict, List

from protocol_v2 import ParamsV2, Vote, build_population, run_case

TRIALS = 2000


def _campaign(p: ParamsV2, trials: int = TRIALS, seed: int = 0xC0FFEE) -> Dict:
    rng = random.Random(seed)
    attacker_wins = 0
    voided = 0
    rounds_used: List[int] = []
    turnout: List[List[int]] = []
    pays: List[float] = []
    totals: List[int] = []

    for _ in range(trials):
        pop = build_population(p, rng)
        r = run_case(p, pop, rng, truth=Vote.APPROVE)
        if r.voided:
            voided += 1
            continue
        attacker_wins += int(r.attacker_won)
        rounds_used.append(len(r.rounds))
        turnout.append(r.honest_turnout_by_round)
        pays.append(r.pay_per_voter)
        totals.append(r.total_votes)

    decided = trials - voided
    by_round: List[float] = []
    if turnout:
        width = max(len(t) for t in turnout)
        for i in range(width):
            vals = [t[i] for t in turnout if len(t) > i]
            by_round.append(statistics.mean(vals) if vals else 0.0)

    return {
        "decided": decided,
        "void_rate": voided / trials,
        "attacker_win_rate": (attacker_wins / decided) if decided else float("nan"),
        "mean_rounds": statistics.mean(rounds_used) if rounds_used else 0.0,
        "mean_total_votes": statistics.mean(totals) if totals else 0.0,
        "mean_pay": statistics.mean(pays) if pays else 0.0,
        "honest_turnout_by_round": by_round,
    }


# --------------------------------------------------------------------------
# E1 — does pooling hold the attacker at their population share? (§4.5)
# --------------------------------------------------------------------------

def e1_pooling_holds_share(base: ParamsV2) -> None:
    print("\nE1  Attacker verdict rate vs population share")
    print("    design-v2 §4.5 claims pooling holds P(attacker verdict) at ~q,")
    print("    and that extra rounds do not grant fresh draws.\n")
    print(f"    {'q':>6} {'P(attacker wins)':>18} {'ratio':>8} {'rounds':>8} {'votes':>8}")
    for q in (0.10, 0.20, 0.30, 0.40, 0.50):
        r = _campaign(replace(base, attacker_share=q))
        ratio = r["attacker_win_rate"] / q if q else float("nan")
        print(f"    {q:>6.2f} {r['attacker_win_rate']:>18.3f} {ratio:>8.2f}"
              f" {r['mean_rounds']:>8.2f} {r['mean_total_votes']:>8.1f}")
    print("\n    Read: ratio ~1.0 means the attacker gets their share and no more.")
    print("    A ratio climbing with q would mean retry is still open.")


# --------------------------------------------------------------------------
# E2 — does honest turnout survive dilution? (§4.6)
# --------------------------------------------------------------------------

def e2_dilution(base: ParamsV2) -> None:
    print("\nE2  Honest turnout by round — the dilution asymmetry")
    print("    Attacker turnout is pay-insensitive; honest turnout is not.")
    print("    If honest turnout collapses across rounds, forcing rounds is an attack.\n")
    for q in (0.20, 0.30, 0.40):
        r = _campaign(replace(base, attacker_share=q))
        series = "  ".join(f"{v:5.1f}" for v in r["honest_turnout_by_round"])
        print(f"    q={q:.2f}  honest votes per round: {series}")
    print("\n    Read: a falling series is dilution suppressing honest participation.")


# --------------------------------------------------------------------------
# E3 — what fee keeps turnout near the cohort target? (§9 Q2)
# --------------------------------------------------------------------------

def e3_fee_sweep(base: ParamsV2) -> None:
    print("\nE3  Fee level vs turnout and attacker success")
    print("    The fee is the dial that sets equilibrium turnout, since each")
    print("    additional voter dilutes the rest.\n")
    print(f"    {'fee':>7} {'round-0 honest':>16} {'total votes':>13}"
          f" {'pay/voter':>11} {'P(att)':>8} {'void':>7}")
    for fee in (1.5, 3.0, 6.0, 9.0, 15.0, 30.0):
        r = _campaign(replace(base, fee=fee))
        first = r["honest_turnout_by_round"][0] if r["honest_turnout_by_round"] else 0.0
        print(f"    {fee:>7.1f} {first:>16.1f} {r['mean_total_votes']:>13.1f}"
              f" {r['mean_pay']:>11.3f} {r['attacker_win_rate']:>8.3f}"
              f" {r['void_rate']:>7.2f}")
    print("\n    Read: the fee where round-0 honest turnout approaches the cohort")
    print("    target, without the void rate rising, is the working value.")


# --------------------------------------------------------------------------
# E4 — where does MAX_ROUNDS belong? (§4.6, §9 Q3)
# --------------------------------------------------------------------------

def e4_round_cap(base: ParamsV2) -> None:
    print("\nE4  Round cap vs dilution")
    print("    More rounds means more scrutiny and a thinner slice each.\n")
    print(f"    {'cap':>5} {'P(att)':>8} {'rounds':>8} {'votes':>8}"
          f" {'pay/voter':>11} {'last-round honest':>19}")
    for cap in (1, 2, 3, 4, 6, 8):
        r = _campaign(replace(base, max_rounds=cap))
        series = r["honest_turnout_by_round"]
        last = series[-1] if series else 0.0
        print(f"    {cap:>5} {r['attacker_win_rate']:>8.3f} {r['mean_rounds']:>8.2f}"
              f" {r['mean_total_votes']:>8.1f} {r['mean_pay']:>11.3f} {last:>19.1f}")
    print("\n    Read: the cap should sit where last-round honest turnout is still")
    print("    meaningfully above zero. Past that, extra rounds are attacker-only.")


# --------------------------------------------------------------------------
# E5 — the viable region. Three costs bind at once, so sweep two dimensions.
# --------------------------------------------------------------------------

def e5_viable_region(base: ParamsV2) -> None:
    """Where is honest participation rational at all?

    Three costs sit against one reward:

        gas      fixed, so a bigger fee helps
        freeze   = freeze_days x cases_per_day x pay_per_case, so it scales WITH
                   the fee and a bigger fee does not help at all
        dilution the voter is paid pot/final-turnout, not pot/cohort

    A one-dimensional sweep of any of them finds nothing, because the other two
    still bind. This is the map.
    """
    print("\nE5  Viable region — round-0 honest turnout (of a 32 cohort)")
    print("    rows: freeze term.  cols: fee.  0.0 means nobody honest votes.\n")
    fees = [3.0, 9.0, 30.0, 90.0, 300.0]
    print("    " + " " * 9 + "".join(f"{f:>10.0f}" for f in fees))
    for days in (7.0, 1.0, 0.25, 0.04, 0.0):
        label = "none" if days == 0 else (f"{days*24:.0f}h" if days < 1 else f"{days:.0f}d")
        row = []
        for fee in fees:
            r = _campaign(replace(base, freeze_base_days=days, fee=fee), trials=400)
            series = r["honest_turnout_by_round"]
            row.append(series[0] if series else 0.0)
        print(f"    {label:>9}" + "".join(f"{v:>10.1f}" for v in row))
    print("\n    Read across a row: the fee buys turnout only against GAS.")
    print("    Read down a column: the freeze term is what actually gates it.")


def find_viable(base: ParamsV2) -> ParamsV2:
    """Smallest fee and largest freeze at which honest turnout reaches half cohort."""
    best = None
    for days in (0.0, 0.04, 0.1, 0.25, 1.0):
        for fee in (3.0, 9.0, 30.0, 90.0, 300.0):
            p = replace(base, freeze_base_days=days, fee=fee)
            r = _campaign(p, trials=400)
            series = r["honest_turnout_by_round"]
            if series and series[0] >= base.target_cohort * 0.5:
                if best is None or fee < best.fee:
                    best = p
    return best or base
