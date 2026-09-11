"""E29–E32 — the staged-committee comparison, computed exactly.

Run: ``python3 run_exact.py`` from ``simulation/``.

E29 cross-checks the exact engine against the Monte Carlo one. They share no
code: one enumerates a state space, the other samples a behavioural model. If
they agree the odds of the same bug in both are small; if they disagree, one is
wrong and the disagreement locates it. That check runs first and everything
after it is conditional on it passing.
"""

from __future__ import annotations

from dataclasses import replace

from exact import (Model, assumptions, equal_effort, lemma_holds, one_committee,
                   p_favourable, staged_pair)


def e29_crosscheck() -> bool:
    """Exact vs Monte Carlo, same configuration, independent implementations."""
    from staged import StagedParams, campaign

    print("E29 — cross-check: exact enumeration vs Monte Carlo (20k trials)")
    print("      staged.py judges favourability on ATTENDANCE, so the exact")
    print("      engine is put in that mode here to make them comparable.")
    print()
    print("| config        | quantity          |    exact | Monte Carlo |  gap |")
    print("|---------------|-------------------|---------:|------------:|-----:|")

    from math import sqrt

    trials = 20_000
    ok = True
    for cohort in (20, 40):
        m = Model(cohort=cohort, favourable_on_attendance=True)
        mc_p = StagedParams(target_cohort=cohort)

        ex = one_committee(m)
        mc = campaign(mc_p, arch="A", trials=trials, seed=11)

        # The conditional rate is estimated from only the trials that proceeded,
        # so its standard error is much larger than the unconditional one. A
        # blanket tolerance would pass the easy cell and fail the hard one for
        # the wrong reason; each is tested against its own SE.
        n_proceed = max(1, int(round(trials * mc["proceed_rate"])))
        for label, e, c, n in (
            ("P(proceed)", ex.proceed, mc["proceed_rate"], trials),
            ("P(admit|proceed)", ex.admit_given_proceed,
             mc["admit_given_proceed"], n_proceed),
        ):
            se = sqrt(max(c * (1.0 - c), 1e-12) / n)
            d = abs(e - c)
            sigma = d / se if se else 0.0
            flag = "" if sigma <= 3.0 else "  <-- DISAGREE"
            if sigma > 3.0:
                ok = False
            print(f"| A, cohort {cohort:<3} | {label:<17} | {e:>7.4f}  "
                  f"| {c:>10.4f}  | {sigma:>4.1f}σ{flag} |")

    print()
    print("      every cell within 3 standard errors of the Monte Carlo estimate,"
          "\n      where the SE is computed per cell from its own effective n"
          if ok else "      *** ENGINES DISAGREE — do not use the numbers below ***")
    return ok


def e30_lemma() -> None:
    """The inequality the whole result rests on, checked over a grid."""
    print("\nE30 — the lemma: splitting a committee raises P(some committee is")
    print("      favourable). Exact, for every cell. theta > q throughout.")
    print()
    print("|    q | theta | cohort | P(fav, one of 2n) | P(fav, either of two n) | holds |")
    print("|-----:|------:|-------:|------------------:|------------------------:|:-----:|")

    all_hold = True
    for q in (0.10, 0.20, 0.30, 0.40):
        for theta in (0.50, 0.60):
            for cohort in (10, 20):
                m = Model(attacker_share=q, favourable_at=theta, cohort=cohort)
                p2n, pn, either, holds = lemma_holds(m)
                all_hold &= holds
                print(f"| {q:>4.0%} | {theta:>4.0%}  | {cohort:>6} "
                      f"| {p2n:>16.6f}  | {either:>22.6f}  "
                      f"| {'yes' if holds else 'NO':^5} |")

    print()
    print("      holds in every cell" if all_hold else "      *** FAILS SOMEWHERE ***")
    print("      It is not an empirical fact: P_m is the upper tail of the")
    print("      attacker's share in a sample of size m, which concentrates on q,")
    print("      so P_m strictly decreases in m whenever theta > q. Then")
    print("      P_2n < P_n < 2*P_n - P_n^2 = 1-(1-P_n)^2, the second step being")
    print("      algebra for any 0 < P_n < 1. No parameter is fitted.")


def e31_headline() -> None:
    """The comparison, exact, at equal review effort."""
    print("\nE31 — equal review effort, EXACT (no sampling error)")
    print("      one committee of 2n against two staged committees of n")
    print("      favourability judged on the ELIGIBLE set — what an attacker")
    print("      can actually observe (staged.py used attendance; see E29)")
    print()
    print("| n  | architecture      | P(proceed) | P(admit|proceed) | admit/submission |")
    print("|---:|-------------------|-----------:|-----------------:|-----------------:|")

    for n in (10, 20):
        m = Model(cohort=n)
        big, pair = equal_effort(m)
        print(f"| {n:>2} | one committee of {2*n:<2}| {big.proceed:>9.5f}  "
              f"| {big.admit_given_proceed:>15.5f}  "
              f"| {big.admit_per_submission:>15.5f}  |")
        print(f"| {n:>2} | two staged of {n:<5}| {pair.proceed:>9.5f}  "
              f"| {pair.admit_given_proceed:>15.5f}  "
              f"| {pair.admit_per_submission:>15.5f}  |")
        ratio = (pair.admit_per_submission / big.admit_per_submission
                 if big.admit_per_submission else float("inf"))
        print(f"| {'':>2} | {'ratio':<17} | {'':>10} | {'':>16} "
              f"| {ratio:>14.2f}x  |")

    print()
    print("      admit/submission is the campaign rate: one submission buys one")
    print("      committee under A and TWO draws at a favourable committee under")
    print("      C, because committee 2 is selected after committee 1 closes.")


def e32_sweep() -> None:
    """Is there ANY region where splitting wins? Swept densely, exactly."""
    print("\nE32 — does splitting ever win? Ratio C/A of admit-per-submission.")
    print("      Above 1.00 means the staged pair is worse. Exact throughout.")
    print()
    hdr = "| q \\ prior |"
    for prior in (0.60, 0.665, 0.75, 0.85, 0.95):
        hdr += f" {prior:>6.3f} |"
    print(hdr)
    print("|----------:|" + "--------:|" * 5)

    worst = (None, float("inf"))
    for q in (0.10, 0.20, 0.30, 0.40, 0.50):
        row = f"| {q:>8.0%}  |"
        for prior in (0.60, 0.665, 0.75, 0.85, 0.95):
            m = Model(attacker_share=q, prior=prior, cohort=10)
            big, pair = equal_effort(m)
            if big.admit_per_submission <= 0.0:
                row += f" {'—':>6} |"
                continue
            ratio = pair.admit_per_submission / big.admit_per_submission
            if ratio < worst[1]:
                worst = ((q, prior), ratio)
            row += f" {ratio:>6.2f} |"
        print(row)

    print()
    if worst[0] is not None:
        (q, pr), r = worst
        print(f"      best case for the staged pair anywhere in this grid:")
        print(f"      q={q:.0%}, prior={pr:.3f} -> ratio {r:.2f}x")
        print("      " + ("splitting still loses everywhere" if r > 1.0
                          else "*** splitting WINS in at least one cell ***"))


def main() -> None:
    print("=" * 78)
    print("Exact enumeration — one committee vs staged pair")
    print("=" * 78)
    print()

    if not e29_crosscheck():
        print("\nStopping: the engines disagree, so neither result is usable.")
        return

    e30_lemma()
    e31_headline()
    e32_sweep()

    print("\nWhat exactness does NOT cover — every assumption still live:")
    for i, a in enumerate(assumptions(), 1):
        print(f"  {i}. {a}")
    print()


if __name__ == "__main__":
    main()
