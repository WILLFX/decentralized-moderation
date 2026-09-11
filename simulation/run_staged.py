"""E24–E27 — staged committees against selective capture.

Run: ``python3 run_staged.py`` from ``simulation/``.
"""

from __future__ import annotations

from staged import StagedParams, attempts_for_confidence, campaign

TRIALS = 20_000
ARCHES = [
    ("A", "one committee"),
    ("B", "two, first tally visible"),
    ("C", "two, staged + hidden"),
    ("D", "staged + challenge (cap 2)"),
]


def _row(label: str, m: dict, width: int = 28) -> str:
    n = attempts_for_confidence(m["admit_per_trial"])
    n_s = "—" if n == float("inf") else f"{n:,.0f}"
    return (
        f"| {label:<{width}} | {m['proceed_rate']:>6.1%} "
        f"| {m['admit_given_proceed']:>7.2%} | {m['admit_per_trial']:>7.2%} "
        f"| {m['mean_approve']:>5.1f}/{m['mean_reject']:<5.1f} "
        f"| {m['mean_committed']:>4.2f} | {m['mean_drawn']:>4.2f} | {n_s:>7} |"
    )


def _header(width: int = 28) -> str:
    return (
        f"| {'architecture':<{width}} | procd. | admit|p | admit/try "
        f"|  A / R      | cmts | drawn | n@95% |\n"
        f"|{'-' * (width + 2)}|-------:|--------:|----------:"
        f"|-------------|-----:|------:|------:|"
    )


def e24_selective(p: StagedParams) -> None:
    print("\nE24 — unsafe content, SELECTIVE attacker (abandons bad committees)")
    print(f"     q={p.attacker_share:.0%}, prior={p.honest_prior}, "
          f"cohort={p.target_cohort}/committee, favourable at "
          f"{p.favourable_at:.0%}, conformity={p.conformity:.0%}")
    print(_header())
    for arch, label in ARCHES:
        m = campaign(p, arch=arch, trials=TRIALS, seed=11)
        print(_row(label, m))
    print("\n  procd.    = attempts the attacker did not abandon")
    print("  admit|p   = unsafe admitted, given they proceeded")
    print("  admit/try = unsafe admitted per attempt made (the campaign rate)")
    print("  cmts      = committees the attacker actually voted in")
    print("  drawn     = committees drawn — the review effort an attempt costs")
    print("  n@95%     = attempts for >=1 success with 95% probability")


def e24b_equal_effort(p: StagedParams) -> None:
    """E24 gives A one committee and C two, so C reviews twice as much content.

    That comparison flatters the staged design. Here A gets a single committee of
    ``2 * target_cohort`` so both architectures put the same expected number of
    reviewers on a case, and the only difference left is the *shape* — one pool,
    or two pools selected in sequence.
    """
    big = StagedParams(**{**p.__dict__, "target_cohort": p.target_cohort * 2})
    print("\nE24b — EQUAL REVIEW EFFORT: A at one committee of "
          f"{big.target_cohort}, C/D at two of {p.target_cohort}")
    print(_header())
    m = campaign(big, arch="A", trials=TRIALS, seed=11)
    print(_row(f"one committee of {big.target_cohort}", m))
    for arch, label in ARCHES[2:]:
        m = campaign(p, arch=arch, trials=TRIALS, seed=11)
        print(_row(label, m))


def e25_nonselective(p: StagedParams) -> None:
    print("\nE25 — control: the SAME attacker, forced to take every committee")
    print("      (isolates staging's effect from selection's)")
    print(_header())
    for arch, label in ARCHES:
        m = campaign(p, arch=arch, trials=TRIALS, seed=12, selective=False)
        print(_row(label, m))


def e26_conformity(p: StagedParams) -> None:
    print("\nE26 — what the visible tally costs (architecture B only)")
    print(f"      staged/hidden (C) is the same population with no tally to follow")
    print("\n| conformity | B: admit|p | C: admit|p |    delta |")
    print("|-----------:|-----------:|-----------:|---------:|")
    for conf in (0.0, 0.15, 0.35, 0.50, 0.75):
        q = StagedParams(**{**p.__dict__, "conformity": conf})
        b = campaign(q, arch="B", trials=TRIALS, seed=13)
        c = campaign(q, arch="C", trials=TRIALS, seed=13)
        d = (b["admit_given_proceed"] - c["admit_given_proceed"]) * 100.0
        print(f"| {conf:>9.0%}  | {b['admit_given_proceed']:>9.2%}  "
              f"| {c['admit_given_proceed']:>9.2%}  | {d:>+6.2f}pp |")


def e27_censorship(p: StagedParams) -> None:
    print("\nE27 — the same four, against SAFE content (censorship)")
    print(_header())
    for arch, label in ARCHES:
        m = campaign(p, arch=arch, trials=TRIALS, seed=14, content_is_safe=True)
        print(_row(label, m))
    print("\n  admit|p here = safe content CENSORED given the attacker proceeded")


def e28_robustness(p: StagedParams) -> None:
    """Is E24b's reversal an artefact of one cohort size and one threshold?

    Sweeps both. The comparison is always equal review effort: one committee of
    ``2n`` against two staged committees of ``n``.
    """
    print("\nE28 — robustness of E24b. Equal effort throughout; campaign rate")
    print("      (admitted per attempt made — lower is better for the defence)")
    print("\n| n/cttee | favourable at | A: one of 2n | C: two of n | D: +challenge |")
    print("|--------:|--------------:|-------------:|------------:|--------------:|")
    for n in (10, 20, 40):
        for fav in (0.40, 0.50, 0.60):
            small = StagedParams(**{**p.__dict__, "target_cohort": n,
                                    "favourable_at": fav})
            big = StagedParams(**{**p.__dict__, "target_cohort": n * 2,
                                  "favourable_at": fav})
            a = campaign(big, arch="A", trials=TRIALS, seed=15)
            c = campaign(small, arch="C", trials=TRIALS, seed=15)
            d = campaign(small, arch="D", trials=TRIALS, seed=15)
            print(f"| {n:>7} | {fav:>12.0%}  | {a['admit_per_trial']:>11.2%}  "
                  f"| {c['admit_per_trial']:>10.2%}  "
                  f"| {d['admit_per_trial']:>12.2%}  |")


def main() -> None:
    p = StagedParams()
    print("=" * 96)
    print("Staged committees vs selective capture —", TRIALS, "trials per cell")
    print("=" * 96)
    e24_selective(p)
    e24b_equal_effort(p)
    e25_nonselective(p)
    e26_conformity(p)
    e27_censorship(p)
    e28_robustness(p)
    print()


if __name__ == "__main__":
    main()
