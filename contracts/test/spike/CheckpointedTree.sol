// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CheckpointedTree — THROWAWAY SPIKE, not production code
/// @notice A checkpointed variant of `SortitionTree`, built only to measure what
///         the work order's literal P0-3 prescription costs: "each case pins an
///         epoch root at arm time; all draws for that seed use that immutable
///         root."
///
///         Every node keeps a history of (epoch, value). `set` appends (or
///         overwrites the last entry when still inside the same epoch). `drawAt`
///         descends the tree reading each node AS OF a target epoch, which is a
///         binary search per node instead of one SLOAD.
///
///         This file exists to produce a gas number and should be deleted once
///         the design decision is recorded. It deliberately mirrors
///         `SortitionTree`'s structure so the comparison is apples to apples.
library CheckpointedTree {
    struct Checkpoint {
        uint64 epoch;
        uint192 value; // weights are token amounts; 192 bits is ample
    }

    struct Tree {
        uint256 k;
        uint256 nodeCount;
        mapping(uint256 => Checkpoint[]) history; // node index -> value history
        mapping(address => uint256) idToNode;
        mapping(uint256 => address) nodeToId;
    }

    error NotInitialized();
    error EmptyTree();

    function initialize(Tree storage tree, uint256 k) internal {
        tree.k = k;
        tree.nodeCount = 1; // root
    }

    /// @dev Value of `node` as of the end of `epoch` — the binary search that
    ///      replaces a single SLOAD in the non-checkpointed tree.
    function valueAt(Tree storage tree, uint256 node, uint256 epoch) internal view returns (uint256) {
        Checkpoint[] storage h = tree.history[node];
        uint256 n = h.length;
        if (n == 0) return 0;
        if (h[0].epoch > epoch) return 0;
        if (h[n - 1].epoch <= epoch) return h[n - 1].value;
        uint256 lo;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (h[mid].epoch <= epoch) lo = mid;
            else hi = mid - 1;
        }
        return h[lo].value;
    }

    function _latest(Tree storage tree, uint256 node) private view returns (uint256) {
        Checkpoint[] storage h = tree.history[node];
        uint256 n = h.length;
        return n == 0 ? 0 : h[n - 1].value;
    }

    function _write(Tree storage tree, uint256 node, uint256 value, uint256 epoch) private {
        Checkpoint[] storage h = tree.history[node];
        uint256 n = h.length;
        if (n != 0 && h[n - 1].epoch == uint64(epoch)) {
            h[n - 1].value = uint192(value); // same epoch: overwrite, no growth
        } else {
            h.push(Checkpoint({epoch: uint64(epoch), value: uint192(value)}));
        }
    }

    /// Spike-only `set`: leaves live at explicit absolute node indices in a
    /// complete K-ary layout, so every leaf's ancestors are genuinely internal
    /// nodes. (The real tree splits leaves lazily via a vacancy stack; that
    /// affects `set` cost, not the `drawAt` cost this spike is measuring.)
    function setLeaf(Tree storage tree, address id, uint256 leafNode, uint256 weight, uint256 epoch) internal {
        uint256 k = tree.k;
        if (tree.idToNode[id] == 0) {
            tree.idToNode[id] = leafNode;
            tree.nodeToId[leafNode] = id;
        }
        uint256 old = _latest(tree, leafNode);
        _write(tree, leafNode, weight, epoch);

        // Propagate to the root, one checkpoint write per level.
        uint256 parent = leafNode;
        while (parent != 0) {
            parent = (parent - 1) / k;
            uint256 pv = _latest(tree, parent);
            _write(tree, parent, weight >= old ? pv + (weight - old) : pv - (old - weight), epoch);
        }
    }

    function setNodeCount(Tree storage tree, uint256 n) internal {
        tree.nodeCount = n;
    }

    /// @notice Draw as of `epoch` — the immutable-root read the work order asks for.
    function drawAt(Tree storage tree, uint256 rand, uint256 epoch) internal view returns (address) {
        uint256 rootValue = valueAt(tree, 0, epoch);
        if (rootValue == 0) revert EmptyTree();
        uint256 k = tree.k;
        uint256 treeIndex = 0;
        uint256 currentDrawn = rand % rootValue;

        while ((k * treeIndex) + 1 < tree.nodeCount) {
            for (uint256 i = 1; i <= k; i++) {
                uint256 nodeIndex = (k * treeIndex) + i;
                uint256 nodeValue = valueAt(tree, nodeIndex, epoch);
                if (currentDrawn >= nodeValue) {
                    currentDrawn -= nodeValue;
                } else {
                    treeIndex = nodeIndex;
                    break;
                }
            }
        }
        return tree.nodeToId[treeIndex];
    }
}
