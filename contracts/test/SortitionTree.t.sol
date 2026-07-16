// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SortitionTree} from "../src/lib/SortitionTree.sol";
import {SortitionTreeHarness} from "./harnesses/SortitionTreeHarness.sol";

contract SortitionTreeTest is Test {
    using SortitionTree for SortitionTree.Tree;

    SortitionTreeHarness internal h;

    function setUp() public {
        h = new SortitionTreeHarness(2); // binary tree
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("moderator", i)))));
    }

    // --- basic correctness ---------------------------------------------------

    function test_empty_total_zero() public view {
        assertEq(h.total(), 0);
    }

    function test_draw_empty_reverts() public {
        vm.expectRevert(SortitionTree.EmptyTree.selector);
        h.draw(0);
    }

    function test_set_get_total() public {
        h.set(_addr(1), 5);
        h.set(_addr(2), 3);
        h.set(_addr(3), 2);
        assertEq(h.weightOf(_addr(1)), 5);
        assertEq(h.weightOf(_addr(2)), 3);
        assertEq(h.weightOf(_addr(3)), 2);
        assertEq(h.total(), 10);
    }

    function test_update_weight_updates_total() public {
        h.set(_addr(1), 5);
        h.set(_addr(1), 8); // increase
        assertEq(h.weightOf(_addr(1)), 8);
        assertEq(h.total(), 8);
        h.set(_addr(1), 2); // decrease
        assertEq(h.weightOf(_addr(1)), 2);
        assertEq(h.total(), 2);
    }

    function test_remove_sets_zero_and_frees_slot() public {
        h.set(_addr(1), 5);
        h.set(_addr(2), 3);
        h.set(_addr(1), 0); // remove
        assertEq(h.weightOf(_addr(1)), 0);
        assertEq(h.total(), 3);
        // Re-add: should reuse the vacant slot and be drawable again.
        h.set(_addr(3), 7);
        assertEq(h.total(), 10);
        assertEq(h.weightOf(_addr(3)), 7);
    }

    function test_removed_id_never_drawn() public {
        h.set(_addr(1), 100);
        h.set(_addr(2), 1);
        h.set(_addr(1), 0); // only _addr(2) remains
        for (uint256 i = 0; i < 50; i++) {
            assertEq(h.draw(uint256(keccak256(abi.encode(i)))), _addr(2));
        }
    }

    function test_single_id_always_drawn() public {
        h.set(_addr(7), 42);
        for (uint256 i = 0; i < 20; i++) {
            assertEq(h.draw(i), _addr(7));
        }
    }

    // --- fuzz: total is always the sum of live weights -----------------------

    function testFuzz_total_equals_sum(uint96[10] calldata weights) public {
        uint256 expected;
        for (uint256 i = 0; i < 10; i++) {
            uint256 w = uint256(weights[i]);
            h.set(_addr(i), w);
            expected += w;
        }
        assertEq(h.total(), expected);

        // Overwrite each and re-check the running total.
        for (uint256 i = 0; i < 10; i++) {
            uint256 old = h.weightOf(_addr(i));
            h.set(_addr(i), 1000);
            expected = expected - old + 1000;
            assertEq(h.total(), expected);
        }
    }

    function testFuzz_draw_returns_live_id(uint96[8] calldata weights, uint256 rand) public {
        uint256 live;
        for (uint256 i = 0; i < 8; i++) {
            uint256 w = uint256(weights[i]) % 1_000_000;
            h.set(_addr(i), w);
            if (w > 0) live++;
        }
        if (h.total() == 0) {
            vm.expectRevert(SortitionTree.EmptyTree.selector);
            h.draw(rand);
            return;
        }
        address drawn = h.draw(rand);
        // Drawn id must be one with positive weight.
        assertGt(h.weightOf(drawn), 0);
    }

    // --- distribution property ----------------------------------------------

    /// Deterministic (fixed base seed + fixed derivation), so the tolerance is a
    /// property of the run, not a probabilistic bound: weights 50/30/20, 10k
    /// draws, empirical share within 2 percentage points of the target.
    function test_draw_distribution_matches_weights() public {
        address a = _addr(1);
        address b = _addr(2);
        address c = _addr(3);
        h.set(a, 50);
        h.set(b, 30);
        h.set(c, 20);

        uint256 n = 10_000;
        uint256 ca;
        uint256 cb;
        uint256 cc;
        for (uint256 i = 0; i < n; i++) {
            address d = h.draw(uint256(keccak256(abi.encode("dist", i))));
            if (d == a) ca++;
            else if (d == b) cb++;
            else if (d == c) cc++;
            else revert("unexpected id drawn");
        }
        assertEq(ca + cb + cc, n, "all draws accounted for");
        // within 2 percentage points (200 / 10000) of target share
        assertApproxEqAbs(ca * 100 / n, 50, 2, "A share ~50%");
        assertApproxEqAbs(cb * 100 / n, 30, 2, "B share ~30%");
        assertApproxEqAbs(cc * 100 / n, 20, 2, "C share ~20%");
    }

    // --- gas: draw over a large tree ----------------------------------------

    function test_gas_draw_1000_leaves() public {
        for (uint256 i = 0; i < 1000; i++) {
            h.set(_addr(i), (i % 97) + 1);
        }
        uint256 g0 = gasleft();
        address drawn = h.draw(uint256(keccak256("g")));
        uint256 used = g0 - gasleft();
        assertGt(h.weightOf(drawn), 0);
        // Budget: seat-draw poke over 1000 moderators is 2M for 47 seats (D9);
        // a single draw is far under that. Guard a generous per-draw ceiling.
        assertLt(used, 60_000, "single draw over 1000 leaves under 60k gas");
        emit log_named_uint("draw_gas_1000_leaves", used);
    }
}
