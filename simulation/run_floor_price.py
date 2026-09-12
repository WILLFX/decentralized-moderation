"""E38–E41 — pricing the per-committee minimum.

Run: ``python3 run_floor_price.py`` from ``simulation/``.
"""

from __future__ import annotations

from floor_price import (World, elig_bits, identities_for_capture, p_case_unresolved,
                         p_case_unresolved_combined, p_eligible, p_sole_committers)

REGISTRIES = (100, 250, 1000, 5000)
FLOORS = (0, 1, 2, 3, 4, 6, 8, 12, 16)


def e38_cohorts() -> None:
    print("E38 — the committee size is not a chosen parameter")
    print("      §3: eligible on N-5 leading zero bits, registry in [2^N, 2^(N+1))")
    print()
    print("| registry | bits | P(eligible) | expected committee |")
    print("|---------:|-----:|------------:|-------------------:|")
    for r in REGISTRIES:
        p = p_eligible(r)
        print(f"| {r:>8} | {elig_bits(r):>4} | {p:>10.4f}  | {r * p:>17.1f}  |")
    print()
    print("      It lands between 32 and 64 by construction, so the floors below")
    print("      are read against a committee of that order, not a free choice.")


def e39_cost() -> None:
    """The floor's price, against the quantity that actually decides it."""
    print("\nE39 — what a floor costs, against TURNOUT")
    print("      turnout = fraction of eligible moderators who commit to a case.")
    print("      It is unmeasured, and it is the only thing that matters here:")
    print("      the capture this floor exists to stop needs almost nobody to")
    print("      show up, so the floor is only ever tested in a quiet registry.")
    print()
    print("      P(a case cannot resolve), registry 1000, committee ~62 eligible")
    print()
    hdr = "| turnout | committers |"
    for k in (2, 3, 4, 6, 8, 12):
        hdr += f" k={k:<2} |"
    print(hdr)
    print("|--------:|-----------:|" + "------:|" * 6)
    for h in (0.02, 0.05, 0.10, 0.20, 0.40, 0.80):
        w = World(1000, 3, h)
        exp = w.registry * w.p_honest_commits
        row = f"| {h:>6.0%}  | {exp:>9.1f}  |"
        for k in (2, 3, 4, 6, 8, 12):
            row += f" {p_case_unresolved(w, k):>5.1%} |"
        print(row)
    print()
    print("      Both committees must clear it, so survival is SQUARED — the")
    print("      column that matters is where that squaring bites.")


def e40_benefit() -> None:
    print("\nE40 — what a floor buys, stated plainly")
    print()
    print("      A floor of k forces any clique that decides a case alone to")
    print("      field at least k identities in EACH committee, drawn")
    print("      independently. So the arithmetic is not subtle:")
    print()
    print("| floor k | identities that must commit | at registry 1000, held |")
    print("|--------:|----------------------------:|-----------------------:|")
    for k in (1, 2, 3, 4, 6, 8, 12):
        w = World(1000, 3, 0.05)
        # to place k in each of two independent committees at p_elig each
        need = int(round(2 * k / w.p_elig))
        print(f"| {k:>7} | {2 * k:>27} | {need:>21} |")
    print()
    print("      The middle column is what must land in the committees; the right")
    print("      is roughly what must be HELD for that to happen at p(elig) =")
    print(f"      {World(1000).p_elig:.4f}. Today's floor is effectively 0 in")
    print("      committee B, which is why three identities suffice.")


def e41_shape() -> None:
    print("\nE41 — per-committee against combined, at equal total")
    print("      registry 1000, turnout 5%. A combined floor of 2k versus k each.")
    print()
    print("| k | per-committee | combined (2k) | combined lets B be EMPTY |")
    print("|--:|--------------:|--------------:|:------------------------:|")
    for k in (2, 3, 4, 6, 8):
        w = World(1000, 3, 0.05)
        print(
            f"| {k} | {p_case_unresolved(w, k):>12.1%} "
            f"| {p_case_unresolved_combined(w, 2 * k):>13.1%} |"
            f"{'yes':^26}|"
        )
    print()
    print("      The combined floor is always cheaper and buys nothing: 2k")
    print("      commits in A and none in B passes it, which is precisely the")
    print("      arrangement the staged design exists to prevent.")


def main() -> None:
    print("=" * 72)
    print("Pricing the per-committee minimum — exact, no sampling")
    print("=" * 72)
    print()
    e38_cohorts()
    e39_cost()
    e40_benefit()
    e41_shape()
    print()


if __name__ == "__main__":
    main()
