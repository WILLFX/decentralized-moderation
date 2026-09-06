"""E9-E12 — sequential stopping against v3's fixed quorum.

The question `FINDINGS-v3.md` §E raises and cannot answer from inside v3: is the
92.2% `NO_TURNOUT` at registry 250 a property of the POPULATION or of the GATE?

Run: ``python3 run_adaptive.py``
"""

from __future__ import annotations

import random

from protocol_v3 import APPROVE, ParamsV3, sweep
from adaptive_stopping import (
    NO_WIDEN, SAFE, SAFE_WIDEN, WIDEN, AdaptiveParams, measure_adaptive,
    measure_v3, p_theta_above_half,
)

TRIALS = 3000
SEED = 11

#: `T` is calibrated once and §3.6 forbids recalibrating it, so eligibility
#: probability is held fixed and the cohort scales with the registry — the same
#: convention E2 uses.
CALIB = 1000


def _at(base: ParamsV3, n: int, **kw) -> ParamsV3:
    return sweep(base, n_moderators=n,
                 target_cohort=int(round(base.target_cohort * n / CALIB)), **kw)


def e9_liveness(base: ParamsV3) -> None:
    print("\nE9  Is the 92% NO_TURNOUT a property of the population or of the gate?")
    print("    Same registry, same eligibility, same availability. The only")
    print("    difference is that v3 asks once and stops on a COUNT, while")
    print("    adaptive asks repeatedly and stops on the EVIDENCE.\n")
    print(f"    {'registry':>9} {'E[cohort]':>10} | {'v3 unres':>9} "
          f"{'adapt':>8} {'ad+widen':>9} | {'ad windows':>11} {'ad votes':>9}")
    for n in (250, 500, 1000, 2000):
        p = _at(base, n)
        v3 = measure_v3(p, safe=False, trials=TRIALS, seed=SEED)
        ad = measure_adaptive(p, SAFE, safe=False, trials=TRIALS, seed=SEED)
        aw = measure_adaptive(p, SAFE_WIDEN, safe=False, trials=TRIALS, seed=SEED)
        print(f"    {n:>9,} {p.target_cohort:>10} | {v3.unresolved:>9.3f} "
              f"{ad.unresolved:>8.3f} {aw.unresolved:>9.3f} | "
              f"{ad.mean_windows:>11.2f} {ad.mean_votes:>9.1f}")
    print("\n    v3's MIN_COMMITS is 16 against an expected cohort of 10 at n=250.")
    print("    A gate above the mean fails most of the time by construction.")


def e10_safety(base: ParamsV3) -> None:
    print("\nE10 Does stopping earlier cost safety?")
    print("    Stopping early means deciding on fewer votes, and the attacker is")
    print("    always-on while honest turnout trickles in — so early votes are")
    print("    hostile-enriched. This is where that shows up if it does.\n")
    for prior in (0.665, 0.95):
        print(f"    honest prior {prior:.3f}, q = {base.attacker_share:.2f}")
        print(f"      {'registry':>9} {'v3 unres':>9} | {'v3 falseAppr':>13} "
              f"{'adapt':>8} {'ad+widen':>9} | {'v3 falseRej':>12} "
              f"{'adapt':>8} {'ad+widen':>9}")
        for n in (250, 1000, 2000):
            p = _at(base, n, honest_prior=prior)
            # false approval: unsafe content, attacker pushes Approve
            v3u = measure_v3(p, safe=False, trials=TRIALS, seed=SEED)
            adu = measure_adaptive(p, SAFE, safe=False, trials=TRIALS, seed=SEED)
            awu = measure_adaptive(p, SAFE_WIDEN, safe=False, trials=TRIALS, seed=SEED)
            # false rejection: safe content, attacker pushes Reject (censorship)
            v3s = measure_v3(p, safe=True, wants=not APPROVE, trials=TRIALS, seed=23)
            ads = measure_adaptive(p, SAFE, safe=True, wants=not APPROVE,
                                   trials=TRIALS, seed=23)
            aws = measure_adaptive(p, SAFE_WIDEN, safe=True, wants=not APPROVE,
                                   trials=TRIALS, seed=23)
            print(f"      {n:>9,} {v3u.unresolved:>9.3f} | "
                  f"{v3u.approved:>13.3f} {adu.approved:>8.3f} "
                  f"{awu.approved:>9.3f} | {1 - v3s.approved:>12.3f} "
                  f"{1 - ads.approved:>8.3f} {1 - aws.approved:>9.3f}")
        print()
    print("    All rates are CONDITIONAL ON THE CASE RESOLVING. At n=250 v3")
    print("    resolves 8% of cases, so its column there describes a small,")
    print("    self-selected subset — the ones that happened to draw a cohort")
    print("    of 16+ from an expected 10 — while adaptive's is over nearly")
    print("    every case. The n=250 row is not a like-for-like comparison and")
    print("    the two larger registries are.")


def e11_min_votes(base: ParamsV3) -> None:
    print("\nE11 The front-loading risk: how low can `min_votes` go?")
    print("    Attackers are present in window 1 with certainty; honest turnout")
    print("    arrives at 0.80/window, so the FIRST votes are hostile-enriched")
    print("    and a rule permitted to stop on 2 of them stops on that tally.")
    print("    Run at registry 2,000, where cases genuinely DO stop early —")
    print("    at 250 the eligible set is ~10 and `min_votes` never binds.\n")
    p = _at(base, 2000)
    print(f"    registry 2,000, q = {base.attacker_share:.2f}, prior "
          f"{base.honest_prior:.3f}, hostile share of registry 0.30\n")
    print(f"    {'min_votes':>10} {'falseAppr':>10} {'hostile@stop':>13} "
          f"{'votes':>7} {'windows':>8} {'early':>7}")
    for mv in (2, 3, 4, 6, 8, 12, 16, 24):
        ap = AdaptiveParams(min_votes=mv, min_votes_to_decide=min(3, mv))
        r = measure_adaptive(p, ap, safe=False, trials=TRIALS, seed=SEED)
        print(f"    {mv:>10} {r.approved:>10.3f} {r.hostile_share:>13.3f} "
              f"{r.mean_votes:>7.1f} {r.mean_windows:>8.2f} {r.early:>7.3f}")
    print("\n    Same table with the rule checked ONCE PER WINDOW instead, which")
    print("    is what the first version of this engine did. It cannot see the")
    print("    risk: the first check already holds ~69 votes, so `min_votes`")
    print("    never binds and every row is identical.\n")
    print(f"    {'min_votes':>10} {'falseAppr':>10} {'hostile@stop':>13} "
          f"{'votes':>7} {'windows':>8} {'early':>7}")
    for mv in (2, 8, 24):
        ap = AdaptiveParams(min_votes=mv, min_votes_to_decide=min(3, mv),
                            per_vote=False)
        r = measure_adaptive(p, ap, safe=False, trials=TRIALS, seed=SEED)
        print(f"    {mv:>10} {r.approved:>10.3f} {r.hostile_share:>13.3f} "
              f"{r.mean_votes:>7.1f} {r.mean_windows:>8.2f} {r.early:>7.3f}")


def e14_min_commits_control(base: ParamsV3) -> None:
    """The control E9 needs. If simply LOWERING `MIN_COMMITS` fixes liveness,
    then E9's result belongs to removing a badly-set gate and not to sequential
    stopping, and the honest recommendation is a one-line parameter change."""
    print("\nE14 CONTROL — is E9's win adaptive stopping, or just a bad MIN_COMMITS?")
    print("    Plain v3, unmodified, with the gate lowered. If this closes the")
    print("    gap then sequential stopping is not what earned it.\n")
    p = _at(base, 250)
    print(f"    registry 250, E[cohort] {p.target_cohort}, prior "
          f"{base.honest_prior:.3f}\n")
    print(f"    {'MIN_COMMITS':>12} {'unresolved':>11} {'falseAppr|res':>14} "
          f"{'reveals':>9}")
    for mc in (16, 12, 10, 8, 6, 4, 2):
        r = measure_v3(sweep(p, min_commits=mc), safe=False,
                       trials=TRIALS, seed=SEED)
        print(f"    {mc:>12} {r.unresolved:>11.3f} {r.approved:>14.3f} "
              f"{r.mean_votes:>9.1f}")
    ad = measure_adaptive(p, SAFE, safe=False, trials=TRIALS, seed=SEED)
    print(f"    {'adaptive':>12} {ad.unresolved:>11.3f} {ad.approved:>14.3f} "
          f"{ad.mean_votes:>9.1f}")


def e15_indifference(base: ParamsV3) -> None:
    """Wald's test has UNBOUNDED expected sample size when the true rate sits at
    the indifference point. Here that point is where the effective hostile share
    of reveals — `q + (1-q)(1-prior)`, E1's quantity — reaches 1/2. The stopping
    rule cannot fire there, so the case runs to the cap and the widening schedule
    keeps enlarging the cohort it runs to the cap with."""
    print("\nE15 Where the stopping rule STOPS FIRING, and what it costs there")
    print("    The rule is decisive about `theta`, and `theta` is driven to 1/2")
    print("    by `q + (1-q)(1-prior)` -> 0.5. At that point no amount of")
    print("    sampling separates the sides, because there is nothing to find.\n")
    print(f"    registry 2,000, q = {base.attacker_share:.2f}, "
          f"ADAPTIVE+WIDEN with E16's time floor\n")
    print(f"    {'prior':>7} {'eff hostile':>12} {'early':>7} {'votes':>7} "
          f"{'windows':>8} {'falseAppr':>10}")
    for prior in (0.60, 0.665, 0.75, 0.80, 0.85, 0.90, 0.95, 0.99):
        p = _at(base, 2000, honest_prior=prior)
        eff = base.attacker_share + (1 - base.attacker_share) * (1 - prior)
        r = measure_adaptive(p, SAFE_WIDEN, safe=False, trials=TRIALS, seed=SEED)
        print(f"    {prior:>7.3f} {eff:>12.3f} {r.early:>7.3f} "
              f"{r.mean_votes:>7.1f} {r.mean_windows:>8.2f} {r.approved:>10.3f}")
    print("\n    Cost is highest exactly where the answer is least available.")
    print("    That is correct behaviour for a sequential test and a REAL")
    print("    budget risk: an attacker who holds the tally near 1/2 makes every")
    print("    case maximally expensive without having to win any of them.")


def e12_cost(base: ParamsV3) -> None:
    print("\nE12 What a case costs when the sample size is chosen by the evidence")
    print("    Human attention per case is the scarce input. A fixed cohort")
    print("    spends the same on an obvious case and a genuinely hard one.\n")
    print(f"    {'prior':>7} {'registry':>9} | {'v3 reveals':>11} "
          f"{'adapt votes':>12} {'windows':>8} {'stopped early':>14}")
    for prior in (0.665, 0.95):
        for n in (250, 1000, 2000):
            p = _at(base, n, honest_prior=prior)
            v3 = measure_v3(p, safe=False, trials=TRIALS, seed=SEED)
            ad = measure_adaptive(p, SAFE_WIDEN, safe=False, trials=TRIALS, seed=SEED)
            print(f"    {prior:>7.3f} {n:>9,} | {v3.mean_votes:>11.1f} "
                  f"{ad.mean_votes:>12.1f} {ad.mean_windows:>8.2f} "
                  f"{ad.early:>14.3f}")
    print("\n    v3's reveal count is 0 on an UNRESOLVED case, so at n=250 its")
    print("    mean is low because most cases never ran, not because it is cheap.")


def e13_stopping_rule(_: ParamsV3) -> None:
    print("\nE13 What the stopping rule actually requires, as a table")
    print("    `P(theta > 1/2 | A, R)` under the same uniform prior `â` uses.")
    print("    epsilon = 0.05, so a tally stops when this reaches 0.950.\n")
    print(f"    {'tally':>10} {'N':>4} {'P(theta>1/2)':>14} {'stops?':>8}")
    for a, r in ((3, 0), (4, 0), (5, 0), (5, 1), (6, 1), (7, 1),
                 (7, 2), (8, 2), (9, 3), (10, 4), (12, 6)):
        post = p_theta_above_half(a, r)
        print(f"    {f'{a}-{r}':>10} {a + r:>4} {post:>14.4f} "
              f"{'yes' if post >= 0.95 else 'no':>8}")
    print("\n    4 unanimous votes decide. 6-1 decides. 12-6 does not.")
    print("    That is the whole mechanism: cheap when the answer is obvious,")
    print("    expensive exactly when it is not.")


def e16_time_floor(base: ParamsV3) -> None:
    """E11 kills naive sequential stopping. Does a floor on TIME rescue it where
    a floor on VOTES did not?

    `min_votes` fails because the attacker supplies the votes it counts.
    `min_windows` is not made of votes, and no amount of hostile stake makes a
    window elapse sooner."""
    print("\nE16 The fix E11 implies: a floor on TIME, not on votes")
    print("    An attacker can manufacture votes. He cannot manufacture the")
    print("    clock. One completed window gives honest turnout its 0.80 chance")
    print("    to arrive before anything is decided.\n")
    for n in (250, 2000):
        p = _at(base, n)
        print(f"    registry {n:,}, q = {base.attacker_share:.2f}, prior "
              f"{base.honest_prior:.3f}   (v3 for reference: "
              f"unres {measure_v3(p, safe=False, trials=TRIALS, seed=SEED).unresolved:.3f}, "
              f"falseAppr {measure_v3(p, safe=False, trials=TRIALS, seed=SEED).approved:.3f})")
        print(f"      {'min_windows':>12} {'unres':>7} {'falseAppr':>10} "
              f"{'hostile@stop':>13} {'votes':>7} {'windows':>8}")
        for mw in (0, 1, 2, 3):
            ap = AdaptiveParams(min_windows=mw)
            r = measure_adaptive(p, ap, safe=False, trials=TRIALS, seed=SEED)
            print(f"      {mw:>12} {r.unresolved:>7.3f} {r.approved:>10.3f} "
                  f"{r.hostile_share:>13.3f} {r.mean_votes:>7.1f} "
                  f"{r.mean_windows:>8.2f}")
        print()


def e17_bot_prefix(base: ParamsV3) -> None:
    """E11's whole result rests on `bot_prefix`, which is a number I chose and
    not one the project has measured. If the finding evaporates at 0.5 it is an
    artifact; if it survives, `bot_prefix` becomes something the testnet must
    measure — and it can, because arrival times are on chain."""
    print("\nE17 SENSITIVITY — how much of E11 is `bot_prefix`?")
    print("    `bot_prefix` is the fraction of a window inside which an")
    print("    always-on identity votes. 1.0 means bots are indistinguishable")
    print("    from people in arrival time and there is no front-running at all.\n")
    p = _at(base, 2000)
    print(f"    registry 2,000, q = {base.attacker_share:.2f}, "
          f"prior {base.honest_prior:.3f}\n")
    print(f"    {'bot_prefix':>11} | {'mw=0 falseAppr':>15} {'hostile@stop':>13} "
          f"| {'mw=1 falseAppr':>15} {'hostile@stop':>13}")
    for bp in (0.05, 0.10, 0.20, 0.40, 0.70, 1.00):
        r0 = measure_adaptive(p, AdaptiveParams(bot_prefix=bp, min_windows=0),
                              safe=False, trials=TRIALS, seed=SEED)
        r1 = measure_adaptive(p, AdaptiveParams(bot_prefix=bp, min_windows=1),
                              safe=False, trials=TRIALS, seed=SEED)
        print(f"    {bp:>11.2f} | {r0.approved:>15.3f} {r0.hostile_share:>13.3f} "
              f"| {r1.approved:>15.3f} {r1.hostile_share:>13.3f}")
    print("\n    v3 at these settings: falseAppr "
          f"{measure_v3(p, safe=False, trials=TRIALS, seed=SEED).approved:.3f}, "
          "hostile share of reveals "
          f"{measure_v3(p, safe=False, trials=TRIALS, seed=SEED).hostile_share:.3f}")


def main() -> None:
    base = ParamsV3()
    print("=" * 78)
    print("SEQUENTIAL STOPPING vs FIXED QUORUM")
    print("Baseline is protocol_v3.run_case, called directly and unmodified.")
    print(f"q = {base.attacker_share:.2f}, availability = "
          f"{base.honest_availability:.2f}, MIN_COMMITS = {base.min_commits}, "
          f"trials = {TRIALS}")
    print("=" * 78)
    e13_stopping_rule(base)
    e9_liveness(base)
    e14_min_commits_control(base)
    e10_safety(base)
    e11_min_votes(base)
    e16_time_floor(base)
    e17_bot_prefix(base)
    e12_cost(base)
    e15_indifference(base)
    print()


if __name__ == "__main__":
    main()
