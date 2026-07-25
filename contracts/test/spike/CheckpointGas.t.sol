// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CheckpointedTree} from "./CheckpointedTree.sol";
import {SortitionTree} from "../../src/lib/SortitionTree.sol";

/// THROWAWAY SPIKE (M2.6-P0-3). Measures the 47-seat / 1000-moderator draw on a
/// checkpointed sum tree against the live one, to decide whether the work order's
/// literal prescription — "each case pins an epoch root; all draws use that
/// immutable root" — fits the 8M single-transaction ceiling.
///
/// Delete once the decision is recorded in GAS_BUDGETS.md.
contract CheckpointGasSpike is Test {
    using CheckpointedTree for CheckpointedTree.Tree;
    using SortitionTree for SortitionTree.Tree;

    CheckpointedTree.Tree internal cp;
    SortitionTree.Tree internal live;

    uint256 internal constant N = 1000;
    uint256 internal constant SEATS = 47;
    uint256 internal constant K = 4;
    uint256 internal constant XBZZ = 1e16;
    uint256 internal constant HARD_CEILING = 8_000_000;

    function setUp() public {
        cp.initialize(K);
        live.initialize(K);
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("mod", i)))));
    }

    /// Populate both trees with 1000 moderators, then age the checkpointed one
    /// across `epochs` epochs of churn so its history has realistic depth. Nodes
    /// near the root change on every `set`, so the root accumulates one
    /// checkpoint per epoch — that is what the binary search pays for.
    /// First leaf index of a complete K-ary layout holding N leaves: the smallest
    /// L with (L+N-2)/K < L, so no leaf is another node's parent.
    uint256 internal constant LEAF0 = 333; // N=1000, K=4

    function _populate(uint256 epochs) internal {
        cp.setNodeCount(LEAF0 + N);
        for (uint256 i = 0; i < N; i++) {
            cp.setLeaf(_addr(i), LEAF0 + i, 100 * XBZZ, 0);
            live.set(_addr(i), 100 * XBZZ);
        }
        for (uint256 e = 1; e <= epochs; e++) {
            // One weight change per epoch is enough to append a checkpoint at
            // every node on that leaf's path to the root, including the root.
            uint256 i = e % N;
            cp.setLeaf(_addr(i), LEAF0 + i, (100 + (e % 7)) * XBZZ, e);
        }
    }

    function _measure(uint256 epochs) internal returns (uint256 cpGas, uint256 liveGas) {
        _populate(epochs);
        uint256 target = epochs;

        uint256 g = gasleft();
        for (uint256 s = 0; s < SEATS; s++) {
            cp.drawAt(uint256(keccak256(abi.encode("seed", s))), target);
        }
        cpGas = g - gasleft();

        g = gasleft();
        for (uint256 s = 0; s < SEATS; s++) {
            live.draw(uint256(keccak256(abi.encode("seed", s))));
        }
        liveGas = g - gasleft();
    }

    function test_spike_checkpointed_draw_cost_shallow_history() public {
        (uint256 cpGas, uint256 liveGas) = _measure(50);
        emit log_named_uint("checkpointed_draw_47seats_50epochs", cpGas);
        emit log_named_uint("live_draw_47seats", liveGas);
        emit log_named_uint("ratio_pct", (cpGas * 100) / liveGas);
    }

    function test_spike_checkpointed_draw_cost_deep_history() public {
        (uint256 cpGas, uint256 liveGas) = _measure(1000);
        emit log_named_uint("checkpointed_draw_47seats_1000epochs", cpGas);
        emit log_named_uint("live_draw_47seats", liveGas);
        emit log_named_uint("ratio_pct", (cpGas * 100) / liveGas);
    }
}
