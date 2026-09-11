"""E33–E37 — the lottery floor, exactly.

Run: ``python3 run_floor.py`` from ``simulation/``.
"""

from __future__ import annotations

from floor import (assumptions, f, lottery_enumerated, lottery_exact,
                   lottery_limit, p_approve, regime, reviewers_for,
                   separability_bound, threshold_bound, threshold_exact)

WORKING_Q = 0.30
WORKING_PRIOR = 0.665


def e33_verify() -> bool:
    """Closed form against direct enumeration. Nothing below is usable if this fails."""
    print("E33 — closed form vs direct enumeration of E[f(a_hat)]")
    print("      two derivations, no shared code path")
    print()
    print("|   N |     p |     closed form |     enumerated |      abs diff |")
    print("|----:|------:|----------------:|---------------:|--------------:|")
    worst = 0.0
    for n in (1, 4, 16, 64, 256):
        for p in (0.216, 0.3, 0.5345, 0.75):
            a = lottery_exact(n, p)
            b = lottery_enumerated(n, p)
            d = abs(a - b)
            worst = max(worst, d)
            if n in (1, 64) and p in (0.3, 0.5345):
                print(f"| {n:>3} | {p:>5.4f} | {a:>15.12f} | {b:>14.12f} "
                      f"| {d:>13.2e} |")
    ok = worst < 1e-9
    print()
    print(f"      worst disagreement over 20 cells: {worst:.2e} — "
          f"{'agree to machine precision' if ok else '*** MISMATCH ***'}")
    return ok


def e34_floor() -> None:
    """The floor: does more review help?"""
    print("\nE34 — unsafe content: does adding honest reviewers drive admission down?")
    print(f"      q={WORKING_Q:.0%}. Two accuracy assumptions.")
    print()

    for prior, label in ((1.0, "perfect moderators (the review's assumption)"),
                         (WORKING_PRIOR, f"prior = {WORKING_PRIOR} (this design's working value)")):
        p = p_approve(WORKING_Q, prior, content_is_safe=False)
        print(f"  {label}")
        print(f"  P(a revealed vote is Approve) = {p:.4f}")
        print()
        print("  |      N | P(unsafe admitted) | gap to the limit |")
        print("  |-------:|-------------------:|-----------------:|")
        lim = lottery_limit(p)
        for n in (4, 16, 64, 256, 1024, 4096):
            v = lottery_exact(n, p)
            print(f"  | {n:>6} | {v:>17.5%}  | {abs(v - lim):>15.2e}  |")
        print(f"  | {'inf':>6} | {lim:>17.5%}  | {'0':>15}  |")
        print()

    print("      The 21.6% in the review is f(0.30) — correct, and it is the")
    print("      PERFECT-moderator case. At prior 0.665 the floor is 55.2%.")
    print("      Neither falls with N. The limit is f(p), a constant.")


def e35_threshold() -> None:
    """The same review effort under a threshold rule."""
    print("\nE35 — the same reviewers, spent on an absolute threshold instead")
    print("      admit iff (approvals / preselected positions) >= theta")
    print()
    for prior in (1.0, 0.85):
        p = p_approve(WORKING_Q, prior, content_is_safe=False)
        theta = 0.75
        if theta <= p:
            print(f"  prior={prior}: p_unsafe={p:.4f} >= theta={theta} — "
                  f"no threshold works here, see E36")
            continue
        print(f"  prior = {prior}, p_unsafe = {p:.4f}, theta = {theta}")
        print()
        print("  |      N |   lottery |  threshold (exact) | Hoeffding bound |")
        print("  |-------:|----------:|-------------------:|----------------:|")
        for n in (16, 32, 64, 128, 256):
            print(f"  | {n:>6} | {lottery_exact(n, p):>8.4%}  "
                  f"| {threshold_exact(n, p, theta):>17.3e}  "
                  f"| {threshold_bound(n, p, theta):>14.3e}  |")
        print()
        print(f"      lottery: Theta(1) — flat. threshold: exp(-Theta(N)) — "
              f"falls off a cliff.")
        print(f"      reviewers for 1e-9 error under the threshold: "
              f"{reviewers_for(1e-9, p, theta):.0f}")
        print(f"      reviewers for 1e-9 error under the lottery:   "
              f"infinite (floor is {lottery_limit(p):.4%})")
        print()


def e36_separability() -> None:
    """The bound that outranks both rules."""
    print("\nE36 — separability: is there ANY rule that works?")
    print("      A threshold needs p_unsafe < theta < p_safe. That requires")
    print("      prior > (1 + q/(1-q)) / 2.")
    print()
    print("|   q | prior needed | p_unsafe | p_safe | separable at prior=0.665 | at 0.95 |")
    print("|----:|-------------:|---------:|-------:|:------------------------:|:-------:|")
    for q in (0.05, 0.10, 0.20, 0.30, 0.40):
        r = regime(q, WORKING_PRIOR)
        r95 = regime(q, 0.95)
        print(f"| {q:>3.0%} | {separability_bound(q):>11.4f}  "
              f"| {r.p_unsafe:>7.4f}  | {r.p_safe:>5.4f}  "
              f"| {'YES' if r.separable else 'no':^24} "
              f"| {'YES' if r95.separable else 'no':^7} |")
    print()
    r = regime(WORKING_Q, WORKING_PRIOR)
    print(f"      At the working point q={WORKING_Q:.0%}, prior={WORKING_PRIOR}:")
    print(f"      p_unsafe = {r.p_unsafe:.4f}, p_safe = {r.p_safe:.4f}")
    print(f"      p_unsafe > p_safe, so a revealed vote is MORE likely to be")
    print(f"      Approve on unsafe content than on safe content. The tally is")
    print(f"      anti-correlated with the truth. No rule over it can separate")
    print(f"      them — not the lottery, not a threshold, not unanimity.")
    print(f"      Required prior at q={WORKING_Q:.0%}: {separability_bound(WORKING_Q):.4f}")


def e37_what_it_takes() -> None:
    """Where the design has to sit for any of this to work."""
    print("\nE37 — the region where a threshold certificate is possible at all")
    print("      cell: reviewers needed for 1e-6 unsafe admission, theta at the")
    print("      midpoint of p_unsafe and p_safe. '—' means not separable.")
    print()
    hdr = "| q \\ prior |"
    priors = (0.665, 0.75, 0.80, 0.85, 0.95)
    for pr in priors:
        hdr += f" {pr:>6.3f} |"
    print(hdr)
    print("|----------:|" + "--------:|" * len(priors))
    for q in (0.05, 0.10, 0.20, 0.30, 0.40):
        row = f"| {q:>8.0%}  |"
        for pr in priors:
            r = regime(q, pr)
            if not r.separable:
                row += f" {'—':>6} |"
                continue
            theta = 0.5 * (r.p_unsafe + r.p_safe)
            n = reviewers_for(1e-6, r.p_unsafe, theta)
            row += f" {n:>6.0f} |"
        print(row)
    print()
    print("      These counts are the Hoeffding bound, so they are conservative:")
    print("      the exact tail needs fewer. They say what SHAPE the answer has —")
    print("      review effort converts into error exponentially, once separable.")


def main() -> None:
    print("=" * 76)
    print("The lottery floor — exact")
    print("=" * 76)
    print()
    if not e33_verify():
        print("\nStopping: the two derivations disagree.")
        return
    e34_floor()
    e35_threshold()
    e36_separability()
    e37_what_it_takes()
    print("\nAssumptions — none of these is removed by exactness:")
    for i, a in enumerate(assumptions(), 1):
        print(f"  {i}. {a}")
    print()


if __name__ == "__main__":
    main()
