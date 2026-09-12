"""E24–E27 — staged committees: neutral on capture, buys tally-hiding.

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


def e24_neutral(p: StagedParams) -> None:
    """The comparison that decides it: the attacker commits everywhere."""
    print("\nE24 — staged vs single, attacker committing EVERYWHERE")
    print(f"     q={p.attacker_share:.0%}, prior={p.honest_prior}, "
          f"cohort={p.target_cohort}/committee")
    print(_header())
    for arch, label in ARCHES:
        m = campaign(p, arch=arch, trials=TRIALS, seed=12, selective=False)
        print(_row(label, m))
    print("\n  Staging makes no difference to capture. The tickets come from the")
    print("  COMBINED tally, so capturing either committee alone buys nothing.")
    print("  Exact confirmation in run_exact.py E31.")


def e24b_withdrawn() -> None:
    print("\nE24b, E25, E28 — WITHDRAWN.")
    print("  These reported staging as ~4-11x worse, using a model in which the")
    print("  attacker DECLINES committees that come out unfavourable and those")
    print("  cases were dropped from the denominator.")
    print()
    print("  Declining is a dominated strategy: it removes the attacker's own")
    print("  votes and leaves the honest ones in the pool. C1 = 10 attackers +")
    print("  10 honest, C2 = 2 + 18. Vote everywhere: 12/40 = 30%. Vote only in")
    print("  C1: 10/38 = 26%. And there is no 'abandon' — the fee is paid and")
    print("  the case runs either way, so the denominator was wrong too.")
    print()
    print("  `selective=True` still reproduces it; see FINDINGS-staged.md sec E.")


def e26_conformity(p: StagedParams) -> None:
    """What staging DOES buy: committee 2 cannot see committee 1's tally."""
    print("\nE26 — what a visible tally costs. Attacker commits everywhere.")
    print("      B shows committee 1's tally to committee 2; C hides it.")
    print("\n| conformity | B: visible | C: hidden |   cost |")
    print("|-----------:|-----------:|----------:|-------:|")
    for conf in (0.0, 0.15, 0.35, 0.50, 0.75):
        q = StagedParams(**{**p.__dict__, "conformity": conf})
        b = campaign(q, arch="B", trials=TRIALS, seed=13, selective=False)
        c = campaign(q, arch="C", trials=TRIALS, seed=13, selective=False)
        d = (b["admit_per_trial"] - c["admit_per_trial"]) * 100.0
        print(f"| {conf:>9.0%}  | {b['admit_per_trial']:>9.2%}  "
              f"| {c['admit_per_trial']:>8.2%}  | {d:>+5.2f}pp |")
    print("\n  0 to 10.6 points, entirely driven by conformity, which has not")
    print("  been measured. At zero conformity there is no effect — an earlier")
    print("  revision claimed 10 points there and that was the same artefact.")


def e27_censorship(p: StagedParams) -> None:
    print("\nE27 — the same four against SAFE content (censorship)")
    print(_header())
    for arch, label in ARCHES:
        m = campaign(p, arch=arch, trials=TRIALS, seed=14,
                     content_is_safe=True, selective=False)
        print(_row(label, m))


def main() -> None:
    p = StagedParams()
    print("=" * 96)
    print("Staged committees —", TRIALS, "trials per cell")
    print("=" * 96)
    e24_neutral(p)
    e24b_withdrawn()
    e26_conformity(p)
    e27_censorship(p)
    print()


if __name__ == "__main__":
    main()
