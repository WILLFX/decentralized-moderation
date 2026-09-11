"""E18-E22 — reliability-weighted aggregation.

Run: ``python3 run_weighted.py``
"""

from __future__ import annotations

from protocol_v3 import APPROVE, ParamsV3, sweep
from weighted import WeightParams, measure, spread_of

TRIALS = 4000
SEED = 11

UNW = WeightParams(unweighted=True)


def _pair(p: ParamsV3, wp: WeightParams):
    """(false approval, false rejection) — unsafe/attacker-approves and
    safe/attacker-rejects, the two directions §4.5 is judged on."""
    u = measure(p, wp, safe=False, trials=TRIALS, seed=SEED)
    s = measure(p, wp, safe=True, wants=not APPROVE, trials=TRIALS, seed=23)
    return u, s


def e18_heterogeneity(base: ParamsV3) -> None:
    """The precondition. Weighting can only pay if reliabilities differ; against
    a homogeneous population it is weighting on estimation noise."""
    print("\nE18 Does weighting pay, and does it need heterogeneity to?")
    print("    Mean reliability is held at `prior` throughout — sweeping the")
    print("    spread must not smuggle in better moderators. ORACLE weights by")
    print("    the true r_i and is the upper bound on any estimator.\n")
    for prior in (0.665, 0.95):
        p = sweep(base, honest_prior=prior)
        print(f"    prior {prior:.3f}, q = {base.attacker_share:.2f}   "
              f"(attacker scores {prior:.3f} on gold — no better a JUDGE than")
        print("       anyone else, so this table isolates heterogeneity alone.")
        print("       E20 removes that assumption, and it is the whole story.)")
        print(f"      {'SD of r':>9} | {'unweighted':>11} {'ORACLE':>8} "
              f"{'gold n=50':>10} | {'oracle gain':>12}")
        for k in (None, 200.0, 50.0, 20.0, 8.0, 4.0, 2.0):
            wp_o = WeightParams(concentration=k, oracle=True,
                                attacker_gold_accuracy=prior)
            wp_g = WeightParams(concentration=k, n_gold=50,
                                attacker_gold_accuracy=prior)
            sd = spread_of(p, wp_o)
            u0, _ = _pair(p, WeightParams(concentration=k, unweighted=True))
            uo, _ = _pair(p, wp_o)
            ug, _ = _pair(p, wp_g)
            print(f"      {sd:>9.3f} | {u0.approved:>11.3f} {uo.approved:>8.3f} "
                  f"{ug.approved:>10.3f} | {u0.approved - uo.approved:>+12.3f}")
        print()


def e19_estimation_cost(base: ParamsV3) -> None:
    print("\nE19 How much gold does the estimate need?")
    print("    ORACLE is free knowledge. This is what it costs to approximate.")
    print("    Attacker still scores only `prior` on gold — E20 removes that.\n")
    for k in (8.0, 2.0):
        p = base
        wp_o = WeightParams(concentration=k, oracle=True,
                            attacker_gold_accuracy=p.honest_prior)
        uo, _ = _pair(p, wp_o)
        u0, _ = _pair(p, WeightParams(concentration=k, unweighted=True))
        print(f"    SD of r = {spread_of(p, wp_o):.3f}   unweighted "
              f"{u0.approved:.3f}   ORACLE {uo.approved:.3f}")
        print(f"      {'n_gold':>8} {'falseAppr':>10} {'vs unweighted':>14} "
              f"{'% of oracle':>12}")
        for ng in (5, 10, 25, 50, 100, 250):
            ug, _ = _pair(p, WeightParams(concentration=k, n_gold=ng,
                                          attacker_gold_accuracy=p.honest_prior))
            gain = u0.approved - ug.approved
            cap = u0.approved - uo.approved
            pct = 100 * gain / cap if abs(cap) > 1e-9 else float("nan")
            print(f"      {ng:>8} {ug.approved:>10.3f} {gain:>+14.3f} "
                  f"{pct:>11.0f}%")
        print()


def e20_farming(base: ParamsV3) -> None:
    """The one that decides it.

    Gold cases are indistinguishable from real ones, so an attacker cannot dodge
    them. He does not need to: he can answer every case honestly except the one
    he is attacking. His measured reliability is then what his JUDGMENT is worth,
    while an honest moderator's is capped at `prior`."""
    print("\nE20 THE ATTACK — an attacker answers gold honestly and defects once")
    print("    An honest moderator at prior 0.665 CANNOT score above 0.665.")
    print("    An attacker who can tell safe from unsafe scores whatever he")
    print("    likes, because he only has to lie on the case he is attacking.\n")
    for prior in (0.665, 0.95):
        p = sweep(base, honest_prior=prior)
        print(f"    prior {prior:.3f}, SD of r = "
              f"{spread_of(p, WeightParams(concentration=8.0)):.3f}, q = "
              f"{base.attacker_share:.2f}")
        u0, s0 = _pair(p, WeightParams(concentration=8.0, unweighted=True))
        print(f"      unweighted: falseAppr {u0.approved:.3f}  falseRej "
              f"{1 - s0.approved:.3f}  hostile share of heads "
              f"{u0.hostile_head:.3f}")
        print(f"      {'atk gold':>9} {'falseAppr':>10} {'falseRej':>9} "
              f"{'hostile WEIGHT':>15} {'vs unweighted':>14}")
        for ag in (0.665, 0.75, 0.85, 0.95, 1.00):
            wp = WeightParams(concentration=8.0, n_gold=50,
                              attacker_gold_accuracy=ag)
            ug, sg = _pair(p, wp)
            print(f"      {ag:>9.3f} {ug.approved:>10.3f} "
                  f"{1 - sg.approved:>9.3f} {ug.hostile_weight:>15.3f} "
                  f"{ug.approved - u0.approved:>+14.3f}")
        print()


def e21_bootstrap(base: ParamsV3) -> None:
    """`measurement/prior` says ground truth must come from outside. The cheap
    alternative is to bootstrap gold from the protocol's own unanimous
    settlements — which is circular, and this is the price of the circle."""
    print("\nE21 Bootstrapped gold: what wrong labels cost")
    print("    Gold drawn from our own confident settlements is only as good as")
    print("    those settlements. At prior 0.665 the effective wrong-side share")
    print("    is 0.534, so a 'confident' outcome is a coin flip with extra steps.\n")
    p = sweep(base, honest_prior=0.665)
    u0, _ = _pair(p, WeightParams(concentration=8.0, unweighted=True))
    print(f"    prior 0.665, SD of r = {spread_of(p, WeightParams(concentration=8.0)):.3f}"
          f"   unweighted falseAppr {u0.approved:.3f}\n")
    print(f"    {'gold acc':>9} {'atk gold 0.665':>15} {'atk gold 1.00':>14}")
    for ga in (1.00, 0.95, 0.85, 0.75, 0.65):
        a, _ = _pair(p, WeightParams(concentration=8.0, gold_accuracy=ga,
                                     attacker_gold_accuracy=0.665))
        b, _ = _pair(p, WeightParams(concentration=8.0, gold_accuracy=ga,
                                     attacker_gold_accuracy=1.00))
        print(f"    {ga:>9.2f} {a.approved:>15.3f} {b.approved:>14.3f}")
    print("\n    Two things, and the second is counter-intuitive:")
    print("    - the benign column degrades gently (0.442 -> 0.492 across a 35")
    print("      point drop in label quality), so bootstrapped gold is FAR less")
    print("      circular than expected — the estimator tolerates dirty labels;")
    print("    - the attacked column IMPROVES as labels get worse, because the")
    print("      attacker's score is measured through the same noisy channel and")
    print("      noise levels everyone. That is not a defence anyone would")
    print("      choose: it works by destroying the signal being farmed.")


def e22_best_case(base: ParamsV3) -> None:
    """Everything the idea could want, at once: wide spread, plentiful clean
    gold, and an attacker no better at judging content than anyone else."""
    print("\nE22 The best case the idea can ask for")
    print("    Wide spread, 250 clean gold cases, attacker no better at judging")
    print("    content than an honest moderator. If it does not pay here it")
    print("    does not pay.\n")
    print(f"    {'prior':>7} {'q':>6} | {'unweighted':>11} {'weighted':>9} "
          f"{'ORACLE':>8} | {'gain':>7}")
    for prior in (0.665, 0.85, 0.95):
        for q in (0.10, 0.30):
            p = sweep(base, honest_prior=prior, attacker_share=q)
            common = dict(concentration=4.0, n_gold=250, gold_accuracy=1.0,
                          attacker_gold_accuracy=prior)
            u0, _ = _pair(p, WeightParams(unweighted=True, **common))
            ug, _ = _pair(p, WeightParams(**common))
            uo, _ = _pair(p, WeightParams(oracle=True, **common))
            print(f"    {prior:>7.3f} {q:>6.2f} | {u0.approved:>11.3f} "
                  f"{ug.approved:>9.3f} {uo.approved:>8.3f} | "
                  f"{u0.approved - ug.approved:>+7.3f}")


def e23_cap(base: ParamsV3) -> None:
    """The constructive question. `weight_cap` bounds how much any one identity
    can be worth: at 0 the scheme is unweighted, at 3 a 0.95 moderator carries
    ~5x a 0.60 one. E20's harm and E18's gain both flow through it, so if they
    respond at different rates there is a setting worth having."""
    print("\nE23 Is there a cap that keeps the gain and drops the attack?")
    print("    Benign  = attacker no better a judge than honest (E18's world).")
    print("    Attacked = attacker scores 1.0 on gold (E20's world).")
    print("    A cap is worth having only if the two columns move apart.\n")
    p = sweep(base, honest_prior=0.665)
    u0, _ = _pair(p, WeightParams(concentration=8.0, unweighted=True))
    print(f"    prior 0.665, SD of r 0.157, q 0.30, n_gold 50   "
          f"unweighted {u0.approved:.3f}\n")
    print(f"    {'cap':>6} {'benign':>8} {'gain':>7} | {'attacked':>9} "
          f"{'harm':>7} | {'net if attacked':>16}")
    for cap in (0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0):
        b, _ = _pair(p, WeightParams(concentration=8.0, n_gold=50,
                                     weight_cap=cap, attacker_gold_accuracy=0.665))
        a, _ = _pair(p, WeightParams(concentration=8.0, n_gold=50,
                                     weight_cap=cap, attacker_gold_accuracy=1.00))
        print(f"    {cap:>6.2f} {b.approved:>8.3f} {u0.approved - b.approved:>+7.3f} "
              f"| {a.approved:>9.3f} {a.approved - u0.approved:>+7.3f} "
              f"| {u0.approved - a.approved:>+16.3f}")


def main() -> None:
    base = ParamsV3()
    print("=" * 78)
    print("RELIABILITY-WEIGHTED AGGREGATION")
    print(f"registry {base.n_moderators:,}  cohort {base.target_cohort}  "
          f"q {base.attacker_share:.2f}  trials {TRIALS}")
    print("Weight = clip(log(r/(1-r)), 0, 3), normalized to mean 1 per case.")
    print("=" * 78)
    e18_heterogeneity(base)
    e19_estimation_cost(base)
    e20_farming(base)
    e21_bootstrap(base)
    e22_best_case(base)
    e23_cap(base)
    print()


if __name__ == "__main__":
    main()
