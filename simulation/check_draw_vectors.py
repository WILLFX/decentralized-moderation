#!/usr/bin/env python3
"""The consuming half of the two-implementation differential for §5's draw.

Reads `contracts/test/vectors/draw_vectors.json`, emitted by `Draw.t.sol` from
the real `Moderation`, and re-derives every `u[i]`, ticket count and outcome in
Python. The two implementations share no code: one is Solidity compiled through
`via_ir`, the other is a pure-Python keccak that refuses to load unless it
reproduces published known-answer tests.

**Why this exists when `Draw.t.sol` already checks the rate.** The property tests
constrain how often the draw approves. They say nothing about the ticket
derivation itself — the domain-separated `u[i]` — which decides individual cases.
A domain-separation mistake still produces uniform `u`, still produces `f(a)` in
aggregate, still passes every statistical test, and silently makes two different
draws identical.

Usage
-----
    cd contracts && forge test --match-test test_emitDrawVectors
    python3 simulation/check_draw_vectors.py

Exits non-zero on any disagreement, and prints the first one in full.
"""

from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import draw as draw_mod  # noqa: E402
from draw import OUTCOME_DOMAIN, decide  # noqa: E402
from keccak import keccak256  # noqa: E402

VECTORS = (
    pathlib.Path(__file__).resolve().parent.parent
    / "contracts"
    / "test"
    / "vectors"
    / "draw_vectors.json"
)


def _compare(blob: dict) -> list[str]:
    """Returns a list of disagreements, empty if the two implementations match."""
    bad: list[str] = []
    for v in blob["vectors"]:
        entropy = bytes.fromhex(v["entropy"][2:])
        _us, tickets, verdict = decide(
            blob["chainId"],
            blob["contract"],
            v["caseId"],
            v["round"],
            entropy,
            v["approve"],
            v["reject"],
        )
        if tickets != v["tickets"] or verdict != v["verdict"]:
            bad.append(
                f"  A={v['approve']} R={v['reject']} round={v['round']} "
                f"entropy={v['entropy'][:18]}...\n"
                f"    solidity: tickets={v['tickets']} verdict={v['verdict']}\n"
                f"    python:   tickets={tickets} verdict={verdict}"
            )
    return bad


def _self_test(blob: dict) -> bool:
    """Prove the differential can FAIL, so agreement means something.

    A differential that agrees is only evidence if it would have disagreed when
    the implementations differ. This deliberately breaks the Python derivation in
    the way a real mistake would break it — dropping the ROUND from the preimage
    — and requires the comparison to notice.

    The round is the right thing to drop, because omitting it is invisible to
    every other check here. `u` stays uniform, the approval rate stays exactly
    `f(a)`, every property test in `Draw.t.sol` stays green except the one written
    for this — and every challenge round silently reuses the first round's
    tickets, so the second draw is not a draw. A challenger could then compute
    the exact tally that flips the case.

    Returns True if the sabotage was caught.
    """
    original = draw_mod.ticket_u

    def broken(chain_id, contract, case_id, round_, index, entropy):
        # same domain, same shape, same everything — minus one field
        preimage = (
            OUTCOME_DOMAIN
            + draw_mod._word(chain_id)
            + draw_mod._address_word(contract)
            + draw_mod._word(case_id)
            + draw_mod._word(index)
            + entropy
        )
        return int.from_bytes(keccak256(preimage), "big") & ((1 << 128) - 1)

    draw_mod.ticket_u = broken
    try:
        return len(_compare(blob)) > 0
    finally:
        draw_mod.ticket_u = original


def main() -> int:
    if not VECTORS.exists():
        print(f"no vectors at {VECTORS}", file=sys.stderr)
        print("run: cd contracts && forge test --match-test test_emitDrawVectors", file=sys.stderr)
        return 2

    blob = json.loads(VECTORS.read_text())
    n = len(blob["vectors"])

    if not _self_test(blob):
        print("SELF-TEST FAILED: a sabotaged derivation was NOT caught.", file=sys.stderr)
        print("The differential is not evidence of anything. Do not trust it.", file=sys.stderr)
        return 3

    bad = _compare(blob)
    if bad:
        print(f"DISAGREEMENT on {len(bad)} of {n} vectors:\n", file=sys.stderr)
        print(bad[0], file=sys.stderr)
        return 1

    print(f"ok: {n} vectors agree, and a sabotaged derivation is caught")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
