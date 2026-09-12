// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice Exposes the draw over an arbitrary tally, without walking a case to
///         it. `_decide` reads the pooled counts off the case, so the harness
///         plants them and calls through.
contract DrawHarness is Moderation {
    constructor(address t, address s, address i)
        Moderation(t, s, i, 15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, 1)
    {}

    function plant(uint256 caseId, uint32 a, uint32 r, uint8 round) external {
        Case storage c = cases[caseId];
        c.pooledApprove = a;
        c.pooledReject = r;
        c.challenges = round;
    }
}

contract DrawTest is Test {
    DrawHarness d;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    function setUp() public {
        d = new DrawHarness(address(new MockBZZ()), address(new MockStakes()), address(new MockIndex()));
    }

    function _decide(uint32 a, uint32 r, bytes32 e, uint8 round) internal returns (uint8 v, uint8 t) {
        d.plant(1, a, r, round);
        return d.decideAt(1, e);
    }

    // ------------------------------------------------------------ certainty

    /// @dev Under the raw share `A/N` a unanimous tally decides with certainty.
    ///      That is the whole difference from `(A+1)/(N+2)`, which leaves a
    ///      residue at every tally — and it is what the review objected to when
    ///      it asked how a unanimous approval could ever fail.
    function test_unanimousApproveIsCertain(bytes32 e, uint8 n) public {
        uint32 votes = uint32(bound(n, 1, 200));
        (uint8 v, uint8 t) = _decide(votes, 0, e, 0);
        assertEq(v, APPROVE);
        assertEq(t, 3, "all three tickets, every time");
    }

    function test_unanimousRejectIsCertain(bytes32 e, uint8 n) public {
        uint32 votes = uint32(bound(n, 1, 200));
        (uint8 v, uint8 t) = _decide(0, votes, e, 0);
        assertEq(v, REJECT);
        assertEq(t, 0);
    }

    /// @dev An empty tally has nothing to draw on. `_decide` must not divide by
    ///      zero, and must not approve.
    function test_emptyTallyRejects(bytes32 e) public {
        (uint8 v, uint8 t) = _decide(0, 0, e, 0);
        assertEq(v, REJECT);
        assertEq(t, 0);
    }

    // ---------------------------------------------------------- monotonicity

    /// @dev The property that makes a challenge unable to buy a re-roll: with
    ///      the entropy and round fixed, adding an Approve can only ever move
    ///      tickets up. The cross-multiplied comparison has this; `u mod N` does
    ///      not, because changing `N` reshuffles every ticket.
    function test_ticketsAreMonotoneInApprovals(bytes32 e, uint8 seed) public {
        uint32 total = uint32(bound(seed, 2, 60));
        uint8 prev;
        for (uint32 a; a <= total; ++a) {
            (, uint8 t) = _decide(a, total - a, e, 0);
            assertGe(t, prev, "an added approval lowered the ticket count");
            prev = t;
        }
    }

    /// @dev Adding a Reject can only move tickets down, for the same reason.
    function test_ticketsAreAntitoneInRejections(bytes32 e, uint8 seed) public {
        uint32 approves = uint32(bound(seed, 1, 40));
        uint8 prev = 3;
        for (uint32 r; r <= 40; ++r) {
            (, uint8 t) = _decide(approves, r, e, 0);
            assertLe(t, prev, "an added rejection raised the ticket count");
            prev = t;
        }
    }

    // ------------------------------------------------------------- the round

    /// @dev §5 draws FRESH tickets at every preliminary outcome. If the round
    ///      were not mixed into the hash, a challenge round would reuse the first
    ///      round's `u` and the second draw would not be a draw at all — the
    ///      outcome would be a pure function of the tally, and a challenger could
    ///      compute exactly how many votes flip it.
    function test_eachRoundDrawsFreshTickets(bytes32 e) public {
        d.plant(1, 5, 5, 0);
        (uint8 v0,) = d.decideAt(1, e);
        d.plant(1, 5, 5, 1);
        (uint8 v1,) = d.decideAt(1, e);
        d.plant(1, 5, 5, 2);
        (uint8 v2,) = d.decideAt(1, e);

        // the tally is identical in all three; only the round differs. over many
        // entropies these must not all agree, or the round is not in the hash
        assertTrue(true); // per-entropy they may agree by chance; see the sweep
        uint256 differ;
        for (uint256 i; i < 64; ++i) {
            bytes32 ei = keccak256(abi.encode(e, i));
            d.plant(1, 5, 5, 0);
            (uint8 a,) = d.decideAt(1, ei);
            d.plant(1, 5, 5, 1);
            (uint8 b,) = d.decideAt(1, ei);
            if (a != b) ++differ;
        }
        assertGt(differ, 0, "round 0 and round 1 never differed: round not in the hash");
        v0 = v0;
        v1 = v1;
        v2 = v2;
    }

    /// @dev Determinism: the same inputs always give the same answer. A
    ///      re-review recomputing a past draw depends on it.
    function test_isDeterministic(bytes32 e, uint8 a, uint8 r) public {
        uint32 ap = uint32(bound(a, 0, 50));
        uint32 rj = uint32(bound(r, 0, 50));
        (uint8 v1, uint8 t1) = _decide(ap, rj, e, 1);
        (uint8 v2, uint8 t2) = _decide(ap, rj, e, 1);
        assertEq(v1, v2);
        assertEq(t1, t2);
    }

    // ------------------------------------------------------------ the rate

    /// @dev The rate must track `f(a) = 3a² − 2a³`, the CDF of the median of
    ///      three uniforms. Checked at a few shares over many entropies.
    function test_rateTracksTheClosedForm() public {
        uint32[4] memory approves = [uint32(2), 5, 8, 15];
        uint32 total = 20;
        uint256 trials = 3000;

        for (uint256 k; k < approves.length; ++k) {
            uint256 hits;
            for (uint256 i; i < trials; ++i) {
                (uint8 v,) = _decide(approves[k], total - approves[k], keccak256(abi.encode("e", k, i)), 0);
                if (v == APPROVE) ++hits;
            }
            // f(a) in basis points
            uint256 a = uint256(approves[k]) * 10_000 / total;
            uint256 f = (3 * a * a) / 10_000 - (2 * a * a * a) / 100_000_000;
            uint256 got = hits * 10_000 / trials;
            assertApproxEqAbs(got, f, 250, "rate departs from 3a^2-2a^3");
        }
    }

    // ------------------------------------------------------------- vectors

    /// @dev Emits vectors for `simulation/check_draw_vectors.py`, which
    ///      re-derives every `u[i]` from a pure-Python keccak that refuses to run
    ///      unless it reproduces published KATs. The two share no code.
    ///
    ///      Tallies and entropies are swept rather than hand-picked: a
    ///      hand-picked set is a set chosen to agree.
    function test_emitDrawVectors() public {
        string memory out = "[";
        uint256 n;
        for (uint32 a; a <= 6; a += 2) {
            for (uint32 r; r <= 6; r += 2) {
                for (uint8 round; round < 3; ++round) {
                    bytes32 e = keccak256(abi.encode("vec", a, r, round));
                    (uint8 v, uint8 t) = _decide(a, r, e, round);
                    if (n > 0) out = string.concat(out, ",");
                    out = string.concat(
                        out,
                        '{"caseId":1,"round":',
                        vm.toString(round),
                        ',"approve":',
                        vm.toString(a),
                        ',"reject":',
                        vm.toString(r),
                        ',"entropy":"',
                        vm.toString(e),
                        '","tickets":',
                        vm.toString(t),
                        ',"verdict":',
                        vm.toString(v),
                        "}"
                    );
                    ++n;
                }
            }
        }
        out = string.concat(out, "]");

        string memory doc = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"contract":"',
            vm.toString(address(d)),
            '","vectors":',
            out,
            "}"
        );
        vm.writeFile("test/vectors/draw_vectors.json", doc);
        console.log("wrote vectors:", n);
    }
}
