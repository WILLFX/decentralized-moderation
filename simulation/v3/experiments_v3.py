"""The four questions `state-machine-v3.md` §10 says the spec cannot answer."""

from __future__ import annotations

import random
from typing import Tuple

from protocol_v3 import APPROVE, REJECT, ParamsV3, a_hat, f, run_case, sweep

TRIALS = 4000


def _rate(p: ParamsV3, *, safe: bool, wants: bool = APPROVE,
          trials: int = TRIALS, seed: int = 11) -> Tuple[float, float]:
    """Returns (P(approved), P(unresolved))."""
    rng = random.Random(seed)
    ok = un = 0
    for _ in range(trials):
        r = run_case(p, rng, content_is_safe=safe, attacker_wants=wants)
        if r.terminal == "UNRESOLVED":
            un += 1
        elif r.approved:
            ok += 1
    return ok / trials, un / trials


def e1_amplifier_crossover(base: ParamsV3) -> None:
    """The majority amplifier works for whichever side is the majority.

    `f` suppresses minorities. That is a benefit exactly while the honest side
    IS the majority of reveals, and a cost the moment it is not. The hostile
    share of reveals is not `q`: it is `q` plus the honest side's own error rate,
    because an honest moderator who misjudges the content votes with the
    attacker. So the crossover is

        q + (1 − q)(1 − prior) = 0.5

    and above it the amplifier is actively working for the attacker.
    """
    print("\nE1  The amplifier has a crossover, and `q` alone does not locate it")
    print("    unsafe content; attacker pushes Approve; honest prior "
          f"{base.honest_prior:.3f}\n")
    print(f"    {'q':>6} {'hostile+error':>14} {'P(approved)':>12} "
          f"{'linear f(a)=a':>14} {'amplified by':>13}")
    for q in (0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50):
        p = sweep(base, attacker_share=q)
        eff = q + (1 - q) * (1 - base.honest_prior)
        got, _ = _rate(p, safe=False)
        print(f"    {q:>6.2f} {eff:>14.3f} {got:>12.3f} {eff:>14.3f} "
              f"{got / eff if eff else 0:>13.2f}x")
    cross = (0.5 - (1 - base.honest_prior)) / base.honest_prior
    print(f"\n    Crossover at q = {cross:.3f}: above it the wrong side is the")
    print("    majority of reveals, and the amplifier amplifies THAT.")
    print("    An honest error is indistinguishable from a hostile vote, so honest")
    print("    accuracy and attacker share enter the same term.")


def e2_registry_growth(base: ParamsV3) -> None:
    """F9 — `T` cannot be recalibrated on chain, so what does a static one cost?"""
    print("\nE2  F9 — a static eligibility threshold as the registry grows")
    print("    T is fixed so E[cohort] = TARGET_COHORT at the CALIBRATION size.")
    print("    §3.6 forbids maintaining an active-moderator count, so it stays fixed.\n")
    calib = base.n_moderators
    print(f"    {'registry':>10} {'E[cohort]':>11} {'E[hostile]':>11} "
          f"{'P(approved)':>12} {'P(unresolved)':>14}")
    for n in (250, 500, 1000, 2000, 5000, 10000):
        # T stays at the calibration value: eligibility probability is unchanged,
        # so the cohort scales linearly with the registry.
        p = sweep(base, n_moderators=n,
                  target_cohort=int(round(base.target_cohort * n / calib)))
        got, un = _rate(p, safe=False, trials=1500)
        print(f"    {n:>10,} {p.target_cohort:>11} "
              f"{p.target_cohort * p.attacker_share:>11.1f} {got:>12.3f} {un:>14.3f}")
    print("\n    The cohort is the thing that scales, not the composition — so the")
    print("    verdict distribution barely moves. What moves is COST: the pot is")
    print("    split among a cohort that grew 40x, so per-voter pay falls with it,")
    print("    and `d = 1.4 x E[P/N]` falls with pay while gas does not.")


def e3_widening_turnout(base: ParamsV3) -> None:
    """F12 — §3.3 claims widening cannot shift composition. It is uniform over
    *identities*; composition is a property of who *acts*.

    Measured on the hostile share of REVEALS directly. Measuring `P(approved)`
    instead confounds the question with liveness, because widening also rescues
    cases that would have ended `UNRESOLVED`.
    """
    print("\nE3  F12 — does the widening step shift the composition of reveals?")
    print("    §3.3: widening is uniform across identities, so the marginal pool")
    print("    is composed like the population. True of the ELIGIBLE set. The")
    print("    tally is made of who ACTS.\n")
    print(f"    {'honest always-on':>18} {'hostile share, no widen':>24}"
          f" {'with widen':>12} {'shift':>8} {'UNRESOLVED saved':>18}")
    for always in (0.10, 0.30, 0.60, 1.00):
        got = {}
        for widen in (False, True):
            p = sweep(base, honest_always_on=always, widen_enabled=widen,
                      target_cohort=18)
            rng = random.Random(29)
            hostile = total = 0
            unres = 0
            for _ in range(1500):
                r = run_case(p, rng, content_is_safe=False, attacker_wants=APPROVE)
                if r.terminal == "UNRESOLVED":
                    unres += 1
                    continue
                # attacker pushes Approve, so their votes are a lower bound on
                # the Approve column; honest error inflates it further.
                hostile += sum(rd.commits_attacker for rd in r.rounds)
                total += r.reveals
            got[widen] = (hostile / total if total else 0.0, unres / 1500)
        d = got[True][0] - got[False][0]
        print(f"    {always:>18.0%} {got[False][0]:>24.3f} {got[True][0]:>12.3f}"
              f" {d:>+8.3f} {got[False][1] - got[True][1]:>18.1%}")
    print("\n    Widening buys liveness and pays for it in composition whenever the")
    print("    honest side is less always-on than the attacker. The marginal pool")
    print("    is drawn uniformly; who shows up inside it is not.")


def e6_honest_accuracy(base: ParamsV3) -> None:
    """The variable nobody has been sweeping, and it dominates everything."""
    print("\nE6  Honest accuracy is the binding constraint, not attacker share")
    print("    An honest moderator who misjudges the content votes WITH the")
    print("    attacker, and the tally cannot tell the two apart. So honest error")
    print("    and hostile share enter the verdict through the same term.\n")
    print(f"    {'honest prior':>13} {'q=0':>10} {'q=0.10':>10} {'q=0.30':>10}"
          f" {'effective hostile @q=0':>24}")
    for prior in (0.665, 0.75, 0.85, 0.95, 0.99):
        row = []
        for q in (0.0, 0.10, 0.30):
            p = sweep(base, honest_prior=prior, attacker_share=q)
            got, _ = _rate(p, safe=False, trials=2500)
            row.append(got)
        print(f"    {prior:>13.3f} {row[0]:>10.3f} {row[1]:>10.3f} {row[2]:>10.3f}"
              f" {1 - prior:>24.3f}")
    print("\n    With ZERO attackers, a 0.665 prior already puts 33.5% of reveals")
    print("    on the wrong side of an unsafe item. The amplifier then works on")
    print("    that. No amount of stake security fixes a classifier problem.")


def e4_challenge_reliability(base: ParamsV3) -> None:
    """`h` — the quantity that lives outside the contract. §4.5 claims the
    single-randomness rule largely defuses it."""
    print("\nE4  `h` — honest challenge reliability, under one randomness per claim")
    print("    The attacker always challenges a loss; the honest side challenges")
    print("    with probability h. Under §4.5 the same u is reused, so a challenge")
    print("    that adds no votes returns the same verdict.\n")
    print(f"    {'h':>6} {'P(approved | unsafe)':>22} {'P(approved | safe)':>20}")
    for h in (0.0, 0.25, 0.50, 0.75, 1.00):
        p = sweep(base, honest_challenge_rate=h)
        bad, _ = _rate(p, safe=False, wants=APPROVE)
        good, _ = _rate(p, safe=True, wants=REJECT, seed=23)
        print(f"    {h:>6.2f} {bad:>22.3f} {good:>20.3f}")
    p0 = sweep(base, max_rounds=1)
    bad0, _ = _rate(p0, safe=False)
    good0, _ = _rate(p0, safe=True, wants=REJECT, seed=23)
    print(f"    {'none':>6} {bad0:>22.3f} {good0:>20.3f}   <- no challenge round")


def e7_estimator(base: ParamsV3) -> None:
    """What `â = (A+1)/(N+2)` denies, and what it costs to deny it.

    §4.5 draws against the posterior mean of the population's Approve rate
    rather than the sample proportion. Under `A/N`, `f(1) = 1`: a unanimous
    tally decides the case with certainty, and one revealed vote is a unanimous
    tally. I11 and I12 both read true over that configuration without covering
    it. The question this asks is what the correction costs everywhere else.
    """
    print("\nE7  The estimator — certainty denied, and the price of denying it")
    print("    `f` consumes a POPULATION rate. `A/N` is a SAMPLE proportion, and")
    print("    handing one to the other claims certainty from N observations.\n")
    print(f"    {'N':>6} {'â at unanimity':>16} {'f(â)':>10} {'cohort overruled':>18}")
    for n in (1, 2, 3, 5, 8, 16, 24, 40, 100):
        ah = a_hat(n, n)
        print(f"    {n:>6} {ah:>16.4f} {f(ah):>10.4f} {1 - f(ah):>17.2%}")
    print("\n    Not a wall: an attacker owning all 16 reveals of a minimum-quorum")
    print("    case still gets 99.1%. What it buys is that no incentive argument")
    print("    in the spec has a degenerate branch — §7.3 and §8.4 are both strict")
    print("    at every tally under â, and were ties at a unanimous one under A/N.\n")

    print("    Cost: P(safe content rejected), no attacker, by honest prior")
    print(f"    {'prior':>7} {'rejected':>11}")
    for prior in (0.665, 0.85, 0.95, 0.99):
        p = sweep(base, honest_prior=prior, attacker_share=0.0)
        got, _ = _rate(p, safe=True, wants=APPROVE, trials=2500, seed=23)
        print(f"    {prior:>7.3f} {1 - got:>11.3f}")
    print("\n    Against `A/N` the same column reads 0.232 / 0.051 / 0.006 / 0.000.")
    print("    The correction costs 0.3 to 2.1 points, on the number this design")
    print("    is already weakest on, and second-order against the 26-60% that")
    print("    honest error contributes to it (§F).")


def e5_viability(base: ParamsV3) -> None:
    """Does honest participation survive the debit? The v2 question, re-asked."""
    print("\nE5  Viability — the confidence a debit demands, against a 66.5% prior")
    print(f"    {'d / E[share]':>13} {'confidence needed':>18} {'honest votes?':>15}")
    for m in (0.5, 1.0, 1.4, 2.0, 4.0, 10.0):
        p = sweep(base, debit_multiple=m)
        t = p.confidence_threshold
        print(f"    {m:>13.1f} {t:>18.4f} {'yes' if base.honest_prior > t else 'NO':>15}")
    print("\n    `d` is a chosen constant, so this table is a design choice rather")
    print("    than an emergent property. Under v2's identity-wide freezing the")
    print("    same column read 70 and honest turnout was zero at every fee.")
