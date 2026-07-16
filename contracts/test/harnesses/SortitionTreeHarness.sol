// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SortitionTree} from "../../src/lib/SortitionTree.sol";

/// @notice Thin external wrapper so tests (and gas snapshots) can exercise the
///         `SortitionTree` storage library through real calls.
contract SortitionTreeHarness {
    using SortitionTree for SortitionTree.Tree;

    SortitionTree.Tree internal tree;

    constructor(uint256 k) {
        tree.initialize(k);
    }

    function set(address id, uint256 weight) external {
        tree.set(id, weight);
    }

    function draw(uint256 rand) external view returns (address) {
        return tree.draw(rand);
    }

    function total() external view returns (uint256) {
        return tree.total();
    }

    function weightOf(address id) external view returns (uint256) {
        return tree.weightOf(id);
    }
}
