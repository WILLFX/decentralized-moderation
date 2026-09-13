"""Differential on §3's eligibility: `Moderation` against a pure-Python derivation.

Run, from the repository root:

    cd contracts && forge test --match-test test_emitEligibilityVectors
    python3 simulation/check_eligibility_vectors.py

**Why this exists.** `Integration.t.sol` checks that eligibility narrows — at 64
staked, fewer than 64 identities are eligible and roughly half are. That constrains
the COUNT and nothing else. A mutation campaign showed what hides behind it:
inverting the predicate, `h >> (256 - eligBits) == 0` to `!= 0`, survived the entire
suite. It has to. The complement of a half-sized set is also half-sized, and every
test in the repository commits *whoever is eligible* rather than a set it decided in
advance — so an inverted predicate produces a different committee of the same size
and every assertion still holds.

The same blindness covers the committee number mixed into the hash, and the
`_eligBits` loop bounds, which move the threshold by a whole bit.

This is the same instrument `check_draw_vectors.py` is for the draw, and it has the
same two parts: a comparison, and a **self-test that deliberately breaks the Python
derivation** so that agreement is evidence rather than coincidence.
"""

from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import eligibility as elig_mod  # noqa: E402
from eligibility import committee_of_phase, elig_bits, eligible  # noqa: E402
from keccak import keccak256  # noqa: E402

_V = pathlib.Path(__file__).resolve().parent.parent / "contracts" / "test" / "vectors"
VECTORS = _V / "eligibility_vectors.json"
#: The bit-width sweep, emitted as JSONL because building hundreds of records with
#: Solidity's `string.concat` is quadratic in memory and died of MemoryOOG at 512.
WIDTHS = _V / "eligibility_width_vectors.jsonl"


def _compare(blob: dict) -> list[str]:
    """Disagreements between the contract's verdict and the Python one."""
    bad: list[str] = []
    bits = blob["eligBits"]
    for v in blob["vectors"]:
        committee = committee_of_phase(v["phase"])
        got = eligible(
            blob["chainId"],
            blob["contract"],
            v["caseId"],
            committee,
            bytes.fromhex(v["seed"][2:]),
            v["moderator"],
            bits,
        )
        if got != v["eligible"]:
            bad.append(
                f"  case={v['caseId']} phase={v['phase']} committee={committee} "
                f"moderator={v['moderator']}\n"
                f"    solidity: {v['eligible']}\n"
                f"    python:   {got}"
            )
    return bad


def _load_widths() -> tuple[dict, list[dict]]:
    lines = [l for l in WIDTHS.read_text().splitlines() if l.strip()]
    header = json.loads(lines[0])
    if not header.get("header"):
        raise ValueError(f"{WIDTHS}: first line is not a header object")
    return header, [json.loads(l) for l in lines[1:]]


def _compare_widths(header: dict, recs: list[dict]) -> list[str]:
    """The same predicate at several bit widths.

    A real registry cannot supply them: `eligBits` is 1 for every size from 64 to
    127, so the narrowing shift would be compared at exactly one width. These
    vectors come from a planted case at widths 1 through 4, both committees, and the
    threshold they use is pinned separately by `test_eligBitsAcrossTheWholeRange`.
    """
    bad: list[str] = []
    seed = bytes.fromhex(header["seed"][2:])
    for r in recs:
        got = eligible(
            header["chainId"],
            header["contract"],
            r["caseId"],
            r["committee"],
            seed,
            r["moderator"],
            r["bits"],
        )
        if got != r["eligible"]:
            bad.append(
                f"  bits={r['bits']} committee={r['committee']} "
                f"moderator={r['moderator']}\n"
                f"    solidity: {r['eligible']}\n"
                f"    python:   {got}"
            )
    return bad


def _check_width_spread(recs: list[dict]) -> str | None:
    """Every width must produce a MIXED set, or it proves nothing.

    An all-false set at some width is satisfied equally by the real predicate and by
    one that always refuses, so a width with no eligible identities is not evidence
    about the shift. This refuses to treat such a sweep as a pass.
    """
    groups: dict[tuple[int, int], list[bool]] = {}
    for r in recs:
        groups.setdefault((r["bits"], r["committee"]), []).append(r["eligible"])
    for (bits, committee), vals in sorted(groups.items()):
        if not any(vals) or all(vals):
            return (
                f"  bits={bits} committee={committee}: {sum(vals)} of {len(vals)} "
                f"eligible — a uniform set cannot distinguish the predicate from a "
                f"constant, so this width is not evidence"
            )
    return None


def _check_threshold(blob: dict) -> str | None:
    """The threshold is half the predicate, so it is derived here too.

    The contract pins `eligBits` at submission from the staked count. If that number
    is wrong by one the committee doubles or halves, and the differential above would
    happily agree with it — both sides would be using the contract's bits. So the
    bits are re-derived from the registry size and compared.
    """
    want = elig_bits(blob["stakedCount"])
    if want != blob["eligBits"]:
        return (
            f"  registry {blob['stakedCount']}\n"
            f"    solidity eligBits: {blob['eligBits']}\n"
            f"    python   eligBits: {want}"
        )
    return None


def _check_committees_differ(blob: dict) -> str | None:
    """Committee A and committee B must not be the same draw.

    This is the property the staging rests on, and it is invisible to any count: a
    wrong committee number produces a set of the right size, uniformly distributed.
    Here both committees of ONE case are compared identity by identity, and they are
    required to disagree somewhere. With ~32 eligible of 64 per committee, agreeing
    everywhere by chance is out of the question.
    """
    by_phase: dict[int, dict[str, bool]] = {}
    for v in blob["vectors"]:
        by_phase.setdefault(v["phase"], {})[v["moderator"].lower()] = v["eligible"]
    if len(by_phase) < 2:
        return "  only one committee was emitted; the differential cannot see staging"

    (pa, a), (pb, b) = sorted(by_phase.items())
    shared = set(a) & set(b)
    if not shared:
        return "  the two committees share no identities to compare"
    if all(a[m] == b[m] for m in shared):
        return (
            f"  phases {pa} and {pb} produced the SAME eligible set over "
            f"{len(shared)} identities — the committee number is not separating them"
        )
    return None


def _self_test(blob: dict) -> bool:
    """Prove the differential can FAIL, so agreement means something.

    The sabotage drops the COMMITTEE from the preimage. That is the right field to
    drop because omitting it is invisible to everything else here: the hash stays
    uniform, each committee stays the right size, every count assertion in
    `Integration.t.sol` stays green — and committees A and B become the *same* draw
    whenever their seeds coincide, which destroys the staging the whole design rests
    on while looking perfectly healthy.

    Returns True if the sabotage was caught.
    """
    original = elig_mod.elig_hash

    def broken(chain_id, contract, case_id, committee, seed, moderator):
        # same domain, same shape, same everything — minus one field
        preimage = (
            elig_mod.ELIGIBILITY_DOMAIN
            + elig_mod._word(chain_id)
            + elig_mod._address_word(contract)
            + elig_mod._word(case_id)
            + seed
            + elig_mod._address_word(moderator)
        )
        return int.from_bytes(keccak256(preimage), "big")

    elig_mod.elig_hash = broken
    try:
        return len(_compare(blob)) > 0
    finally:
        elig_mod.elig_hash = original


def main() -> int:
    if not VECTORS.exists():
        print(f"no vectors at {VECTORS}", file=sys.stderr)
        print(
            "run: cd contracts && forge test --match-test test_emitEligibilityVectors",
            file=sys.stderr,
        )
        return 2

    if not WIDTHS.exists():
        print(f"no width vectors at {WIDTHS}", file=sys.stderr)
        print(
            "run: cd contracts && forge test --match-test test_emitEligibilityWidthVectors",
            file=sys.stderr,
        )
        return 2

    blob = json.loads(VECTORS.read_text())
    n = len(blob["vectors"])
    wheader, wrecs = _load_widths()

    if blob["eligBits"] == 0:
        print(
            "REFUSING TO PASS: eligBits is 0, so the contract short-circuits and the\n"
            "narrowing hash never runs. These vectors prove nothing. Emit them from a\n"
            "registry of 64 or more.",
            file=sys.stderr,
        )
        return 4

    if not _self_test(blob):
        print("SELF-TEST FAILED: a sabotaged derivation was NOT caught.", file=sys.stderr)
        print("The differential is not evidence of anything. Do not trust it.", file=sys.stderr)
        return 3

    for label, problem in (
        ("threshold", _check_threshold(blob)),
        ("committee separation", _check_committees_differ(blob)),
    ):
        if problem:
            print(f"{label.upper()} MISMATCH:\n{problem}", file=sys.stderr)
            return 1

    problem = _check_width_spread(wrecs)
    if problem:
        print(f"WIDTH SWEEP IS NOT EVIDENCE:\n{problem}", file=sys.stderr)
        return 1

    for label, bad in (("case", _compare(blob)), ("width", _compare_widths(wheader, wrecs))):
        if bad:
            print(f"DISAGREEMENT on {len(bad)} {label} vectors:\n", file=sys.stderr)
            print(bad[0], file=sys.stderr)
            return 1

    committees = len({v["phase"] for v in blob["vectors"]})
    widths = sorted({r["bits"] for r in wrecs})
    print(
        f"ok: {n} case vectors agree across {committees} committees at eligBits="
        f"{blob['eligBits']}; {len(wrecs)} width vectors agree at bits {widths}, "
        f"every width a mixed set; the threshold re-derives from a registry of "
        f"{blob['stakedCount']}; the two committees are distinct draws; and a "
        f"sabotaged derivation is caught"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
