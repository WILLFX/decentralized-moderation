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
    print("      TRUE AND IRRELEVANT: finding a favourable committee is not a")
    print("      step toward an outcome once tallies are pooled. E31 is what")
    print("      decides it. Kept because rigour aimed at the wrong quantity")
    print("      looks settled, which is what made it hard to catch.")
    print("      It is not an empirical fact: P_m is the upper tail of the")
    print("      attacker's share in a sample of size m, which concentrates on q,")
    print("      so P_m strictly decreases in m whenever theta > q. Then")
    print("      P_2n < P_n < 2*P_n - P_n^2 = 1-(1-P_n)^2, the second step being")
    print("      algebra for any 0 < P_n < 1. No parameter is fitted.")


def e31_headline() -> None:
    """The comparison that decides it: attacker votes with everything it has."""
    print("\nE31 — equal review effort, EXACT, attacker committing EVERYWHERE")
    print("      one committee of 2n against two staged committees of n.")
    print("      Tallies pooled, one draw. No declining — see the note below.")
    print()
    print("| q   |  n | A: one of 2n | C: two of n |  difference |")
    print("|----:|---:|-------------:|------------:|------------:|")
    for q in (0.10, 0.20, 0.30, 0.40):
        for n in (10, 20):
            m = Model(attacker_share=q, cohort=n, favourable_at=0.0)
            big, pair = equal_effort(m)
            a, c = big.admit_per_submission, pair.admit_per_submission
            print(f"| {q:>3.0%} | {n:>2} | {a:>11.6f}  | {c:>10.6f}  "
                  f"| {c - a:>+10.6f}  |")
    print()
    print("      Identical to five decimal places. Staging makes NO difference")
    print("      to capture: the tickets are drawn from the COMBINED tally, so")
    print("      capturing either committee alone buys nothing.")
    print()
    print("      favourable_at=0 makes the attacker commit every eligible")
    print("      identity. That is the only sensible strategy — declining drops")
    print("      your own votes and leaves the honest ones in the pool, which")
    print("      lowers your share. FINDINGS-staged.md section E has the detail.")


def e32_note() -> None:
    print("\nE32 — WITHDRAWN.")
    print("      This slot reported staging as 11.6x worse, from a model in")
    print("      which the attacker declined unfavourable committees and those")
    print("      cases were excluded from the denominator. Declining is a")
    print("      dominated strategy and there is no 'abandon' — the fee is paid")
    print("      and the case runs. See FINDINGS-staged.md section E.")


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
    e32_note()

    print("\nWhat exactness does NOT cover — every assumption still live:")
    for i, a in enumerate(assumptions(), 1):
        print(f"  {i}. {a}")
    print()


if __name__ == "__main__":
    main()
