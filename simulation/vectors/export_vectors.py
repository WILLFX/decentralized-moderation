"""Generate settlement differential-test vectors (work order D10).

Emits ``{"count": N, "v": [...]}`` where each element is a *flattened* case (all
parallel uint/bool arrays, so Solidity's JSON cheatcodes can parse it) plus the
expected payout breakdown from ``reference_int.settle``. The Foundry test
``test/Differential.t.sol`` injects each case, calls ``claim()``, and asserts
bit-exact agreement.

Vectors are deliberately dust-heavy and cover 1–4 rounds, coherent/incoherent/
failed-reveal voter mixes, winning and losing appeals with multiple contributors,
unanimous and split panels, and the forced flip-flop shape behind the WO-1 fix.

Usage:  python3 export_vectors.py > ../../contracts/test/vectors/settlement_vectors.json
"""

import json
import random
import sys

from reference_int import settle

PRIMES = [7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83]
XBZZ = 10**16


def _amt(rng):
    return rng.choice(PRIMES) * XBZZ + rng.randint(1, 9973)


def _gen_case(rng, n_rounds):
    fo = rng.choice([1, 2])
    base_fee = rng.choice(PRIMES) * XBZZ // 10 + rng.randint(1, 5000)

    rounds = []
    v = 0
    c = 0
    in_pot_total = 0
    for d in range(n_rounds):
        n_voters = rng.randint(1, 5)
        seats = []
        for _ in range(n_voters):
            s = rng.randint(1, 8)
            camt = _amt(rng)
            rc = rng.choices([0, 1, 2], weights=[1, 3, 3])[0]
            seats.append([v, s, camt, rc])
            v += 1
        is_last = d == n_rounds - 1
        bond_in_pot = not is_last
        appeal_for = 0
        contribs = []
        if bond_in_pot:
            appeal_for = rng.choice([1, 2])
            for _ in range(rng.randint(1, 3)):
                a = _amt(rng)
                contribs.append([c, a])
                in_pot_total += a
                c += 1
        rounds.append({
            "seats": seats,
            "bondInPot": bond_in_pot,
            "appealForCode": appeal_for,
            "bondContribs": contribs,
        })

    pot = base_fee + in_pot_total
    case = {"pot": pot, "finalOutcome": fo, "rounds": rounds}
    case["expected"] = settle(case)
    return case


def _flatten(case):
    seat_round, seat_voter, seat_seats, seat_camt, seat_rc = [], [], [], [], []
    round_bond, round_appeal = [], []
    contrib_round, contrib_idx, contrib_amt = [], [], []
    for d, r in enumerate(case["rounds"]):
        round_bond.append(bool(r["bondInPot"]))
        round_appeal.append(r["appealForCode"])
        for (vi, s, camt, rc) in r["seats"]:
            seat_round.append(d)
            seat_voter.append(vi)
            seat_seats.append(s)
            seat_camt.append(camt)
            seat_rc.append(rc)
        for (ci, a) in r["bondContribs"]:
            contrib_round.append(d)
            contrib_idx.append(ci)
            contrib_amt.append(a)

    exp = case["expected"]
    free = sorted(exp["free"].items())
    frozen = sorted(exp["frozen"].items())
    payout = sorted(exp["payout"].items())
    return {
        "pot": case["pot"],
        "finalOutcome": case["finalOutcome"],
        "nRounds": len(case["rounds"]),
        "seat_round": seat_round,
        "seat_voter": seat_voter,
        "seat_seats": seat_seats,
        "seat_camt": seat_camt,
        "seat_rc": seat_rc,
        "round_bondInPot": round_bond,
        "round_appealFor": round_appeal,
        "contrib_round": contrib_round,
        "contrib_idx": contrib_idx,
        "contrib_amt": contrib_amt,
        "exp_free_idx": [k for k, _ in free],
        "exp_free_amt": [x for _, x in free],
        "exp_frozen_idx": [k for k, _ in frozen],
        "exp_frozen_amt": [x for _, x in frozen],
        "exp_payout_idx": [k for k, _ in payout],
        "exp_payout_amt": [x for _, x in payout],
        "exp_claimBounty": exp["claimBounty"],
    }


def main():
    rng = random.Random(20260716)  # fixed seed: reproducible vectors
    shape_plan = ([1] * 14) + ([2] * 14) + ([3] * 12) + ([4] * 12)
    vectors = [_flatten(_gen_case(rng, n)) for n in shape_plan]
    json.dump({"count": len(vectors), "v": vectors}, sys.stdout)


if __name__ == "__main__":
    main()
