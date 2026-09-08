#!/usr/bin/env python3
"""The consuming half of the two-implementation differential for §4.5's draw.

Reads `contracts/test/vectors/draw_vectors.json`, emitted by `DrawVectors.t.sol`
from the real `Moderation`, and re-derives every `u[i]`, ticket count and verdict
in Python from `simulation/v3/draw.py`. The two implementations share no code:
one is Solidity compiled through `via_ir`, the other is a pure-Python keccak that
refuses to load unless it reproduces published KATs.

Usage
-----
    cd contracts && forge test --match-test test_emitDrawVectors
    python3 simulation/v3/check_draw_vectors.py

Exits non-zero on any disagreement, and prints the first one in full.
"""

from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from v3 import draw as draw_mod  # noqa: E402
from v3.draw import OUTCOME_DOMAIN, decide  # noqa: E402
from v3.keccak import keccak256  # noqa: E402

VECTORS = (
    pathlib.Path(__file__).resolve().parent.parent.parent
    / "contracts"
    / "test"
    / "vectors"
    / "draw_vectors.json"
)


def _self_test(blob: dict) -> int:
    """Prove the differential can FAIL, so agreement means something.

    A differential that agrees is only evidence if it would have disagreed when
    the implementations differ. This deliberately breaks the Python derivation in
    the way a real mistake would break it — dropping `caseId` from the preimage —
    and requires the comparison to notice.

    `caseId` is the right thing to drop, because omitting it is INVISIBLE to every
    other check in the repository: `u` stays uniform, the approval rate stays
    exactly `f(â)`, `DrawProperties.t.sol` stays green, and two different cases
    silently share a draw. If this self-test ever passes without a disagreement,
    the differential has stopped being evidence.
    """
    original = draw_mod.ticket_u

    def broken(chain_id, contract, case_id, index, entropy):
        # Same shape, same domain, same everything — minus one field.
        preimage = (
            OUTCOME_DOMAIN
            + draw_mod._word(chain_id)
            + draw_mod._address_word(contract)
            + draw_mod._word(index)
            + entropy
        )
        return int.from_bytes(keccak256(preimage), "big") & ((1 << 128) - 1)

    draw_mod.ticket_u = broken
    try:
        disagreed = False
        for v in blob["vectors"]:
            entropy = bytes.fromhex(v["entropy"][2:])
            us, _, _ = decide(
                blob["chainId"], blob["contract"], v["caseId"], entropy, v["approve"], v["reject"]
            )
            if us != [int(x) for x in v["u"]]:
                disagreed = True
                break
    finally:
        draw_mod.ticket_u = original

    if not disagreed:
        print(
            "SELF-TEST FAILED: a derivation missing `caseId` still agreed with the "
            "contract on every vector. The differential is not discriminating and "
            "its agreement is not evidence.",
            file=sys.stderr,
        )
        return 1
    print("  self-test  a derivation missing caseId IS detected")
    return 0


def main() -> int:
    if not VECTORS.exists():
        print(f"no vectors at {VECTORS}", file=sys.stderr)
        print("run: cd contracts && forge test --match-test test_emitDrawVectors", file=sys.stderr)
        return 2

    blob = json.loads(VECTORS.read_text())
    chain_id = blob["chainId"]
    contract = blob["contract"]
    vectors = blob["vectors"]

    if not vectors:
        print("the vector file is empty; refusing to report agreement", file=sys.stderr)
        return 2

    if _self_test(blob) != 0:
        return 2

    mismatches = 0
    approve_verdicts = 0

    for v in vectors:
        entropy = bytes.fromhex(v["entropy"][2:])
        us, tickets, verdict = decide(
            chain_id, contract, v["caseId"], entropy, v["approve"], v["reject"]
        )
        expected_us = [int(x) for x in v["u"]]

        if us != expected_us or tickets != v["tickets"] or verdict != v["verdict"]:
            mismatches += 1
            if mismatches == 1:
                print("DISAGREEMENT", file=sys.stderr)
                print(f"  caseId  {v['caseId']}", file=sys.stderr)
                print(f"  entropy {v['entropy']}", file=sys.stderr)
                print(f"  tally   A={v['approve']} R={v['reject']}", file=sys.stderr)
                for i in range(3):
                    flag = "" if us[i] == expected_us[i] else "   <-- differs"
                    print(f"  u[{i}] solidity {expected_us[i]}", file=sys.stderr)
                    print(f"       python   {us[i]}{flag}", file=sys.stderr)
                print(
                    f"  tickets solidity {v['tickets']} python {tickets}", file=sys.stderr
                )
                print(
                    f"  verdict solidity {v['verdict']} python {verdict}", file=sys.stderr
                )

        if verdict == 1:
            approve_verdicts += 1

    if mismatches:
        print(f"{mismatches}/{len(vectors)} vectors disagree", file=sys.stderr)
        return 1

    # Non-vacuity: a vector set that is all one verdict would agree trivially and
    # would not exercise the ticket comparison in both directions.
    reject_verdicts = len(vectors) - approve_verdicts
    if approve_verdicts == 0 or reject_verdicts == 0:
        print(
            f"all {len(vectors)} vectors returned the same verdict; the comparison "
            "was not exercised in both directions",
            file=sys.stderr,
        )
        return 2

    print(f"{len(vectors)} vectors agree, u[0..2] and verdict, on two implementations")
    print(f"  chainId  {chain_id}")
    print(f"  contract {contract}")
    print(f"  verdicts {approve_verdicts} approve / {reject_verdicts} reject")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
