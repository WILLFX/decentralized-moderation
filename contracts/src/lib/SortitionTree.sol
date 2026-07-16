// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title SortitionTree
/// @notice Stake-weighted sortition over a set of addresses, backed by a sum
///         tree: internal nodes hold the sum of their children, leaves hold each
///         address's weight, and a draw descends the tree in `O(K·log_K n)`.
///
/// @dev Design after Kleros' `SortitionSumTreeFactory` (MIT,
///      github.com/kleros/kleros), reimplemented for Solidity 0.8.x as a single
///      storage-struct library (one tree, not a factory keyed by bytes32) with
///      `address` IDs. The vacant-leaf stack keeps the node array compact across
///      removals without moving nodes, so the tree stays balanced and draws stay
///      cheap. Weight semantics (spec §5.2): the tree holds exactly the
///      draw-eligible weight — a moderator's activated free stake, and 0 while
///      frozen — so `draw` never has to filter or reject-sample.
library SortitionTree {
    struct Tree {
        uint256 k; // children per node (K >= 2); 0 means uninitialized
        uint256[] stack; // vacant leaf indexes available for reuse
        uint256[] nodes; // nodes[0] is the root sum; leaves hold weights
        mapping(address => uint256) idToNode; // id -> leaf index (0 = absent)
        mapping(uint256 => address) nodeToId; // leaf index -> id
    }

    error NotInitialized();
    error AlreadyInitialized();
    error BadK();
    error EmptyTree();

    /// @dev Must be called once before use (e.g. in the contract constructor).
    function initialize(Tree storage tree, uint256 k) internal {
        if (tree.k != 0) revert AlreadyInitialized();
        if (k < 2) revert BadK();
        tree.k = k;
        tree.nodes.push(0); // root
    }

    /// @notice Insert, update, or (weight == 0) remove `id`'s weight.
    /// @dev Faithful port of Kleros `set`: append into a vacant slot or a fresh
    ///      leaf, splitting a former leaf into an internal node when the new leaf
    ///      is a first child, then propagate the delta to the root.
    function set(Tree storage tree, address id, uint256 weight) internal {
        if (tree.k == 0) revert NotInitialized();
        uint256 k = tree.k;
        uint256 treeIndex = tree.idToNode[id];

        if (treeIndex == 0) {
            // No existing node for this id.
            if (weight != 0) {
                if (tree.stack.length == 0) {
                    // No vacant spot: append a new leaf.
                    treeIndex = tree.nodes.length;
                    tree.nodes.push(weight);

                    // If the new node is a first child, its parent was a leaf and
                    // must become an internal sum node: move the parent's id/value
                    // down into a fresh sibling leaf.
                    if (treeIndex != 1 && (treeIndex - 1) % k == 0) {
                        uint256 parentIndex = treeIndex / k;
                        address parentId = tree.nodeToId[parentIndex];
                        uint256 newIndex = treeIndex + 1;
                        tree.nodes.push(tree.nodes[parentIndex]);
                        delete tree.nodeToId[parentIndex];
                        tree.idToNode[parentId] = newIndex;
                        tree.nodeToId[newIndex] = parentId;
                    }
                } else {
                    // Reuse a vacant leaf.
                    treeIndex = tree.stack[tree.stack.length - 1];
                    tree.stack.pop();
                    tree.nodes[treeIndex] = weight;
                }

                tree.idToNode[id] = treeIndex;
                tree.nodeToId[treeIndex] = id;
                _updateParents(tree, treeIndex, true, weight);
            }
            // weight == 0 for an absent id is a no-op.
        } else {
            // Existing node.
            if (weight == 0) {
                // Remove: zero the leaf, free the slot, propagate the decrease.
                uint256 value = tree.nodes[treeIndex];
                tree.nodes[treeIndex] = 0;
                tree.stack.push(treeIndex);
                delete tree.idToNode[id];
                delete tree.nodeToId[treeIndex];
                _updateParents(tree, treeIndex, false, value);
            } else if (weight != tree.nodes[treeIndex]) {
                // Update: propagate the signed delta.
                bool plus = tree.nodes[treeIndex] <= weight;
                uint256 delta = plus ? weight - tree.nodes[treeIndex] : tree.nodes[treeIndex] - weight;
                tree.nodes[treeIndex] = weight;
                _updateParents(tree, treeIndex, plus, delta);
            }
            // weight unchanged is a no-op.
        }
    }

    /// @notice Draw an id with probability proportional to its weight.
    /// @param rand An arbitrary number; only `rand % total` is used.
    /// @dev Reverts if the tree is empty (total weight 0). Deterministic in
    ///      `rand`: the same `rand` and tree state always return the same id.
    function draw(Tree storage tree, uint256 rand) internal view returns (address) {
        if (tree.k == 0) revert NotInitialized();
        uint256 rootValue = tree.nodes[0];
        if (rootValue == 0) revert EmptyTree();

        uint256 k = tree.k;
        uint256 treeIndex = 0;
        uint256 currentDrawn = rand % rootValue;

        while ((k * treeIndex) + 1 < tree.nodes.length) {
            for (uint256 i = 1; i <= k; i++) {
                uint256 nodeIndex = (k * treeIndex) + i;
                uint256 nodeValue = tree.nodes[nodeIndex];
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

    /// @notice Total eligible weight (the root sum).
    function total(Tree storage tree) internal view returns (uint256) {
        if (tree.nodes.length == 0) return 0;
        return tree.nodes[0];
    }

    /// @notice The weight currently recorded for `id` (0 if absent).
    function weightOf(Tree storage tree, address id) internal view returns (uint256) {
        uint256 treeIndex = tree.idToNode[id];
        if (treeIndex == 0) return 0;
        return tree.nodes[treeIndex];
    }

    /// @dev Propagate a weight change from a leaf up to the root.
    function _updateParents(Tree storage tree, uint256 treeIndex, bool plus, uint256 value) private {
        uint256 k = tree.k;
        uint256 parentIndex = treeIndex;
        while (parentIndex != 0) {
            parentIndex = (parentIndex - 1) / k;
            tree.nodes[parentIndex] = plus ? tree.nodes[parentIndex] + value : tree.nodes[parentIndex] - value;
        }
    }
}
