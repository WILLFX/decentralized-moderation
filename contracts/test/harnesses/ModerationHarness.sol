// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../../src/Moderation.sol";
import {SortitionTree} from "../../src/lib/SortitionTree.sol";

/// @notice Test-only subclass exposing internal state and injectors for state
///         that later M2 items (freezing in M2-5, committing in M2-3) will
///         produce. The injectors mirror exactly what those items' real code
///         paths do, so tests exercise the contract's own accounting, not a
///         parallel model.
contract ModerationHarness is Moderation {
    using SortitionTree for SortitionTree.Tree;

    constructor(IERC20 _token) Moderation(_token) {}

    /// Move `amount` of a moderator's committed stake into the frozen bucket
    /// until `until` — exactly the transition a settlement freeze (§6.4, D6)
    /// makes (committed -> frozen, never touching free/pending).
    function __freeze(address moderator, uint256 amount, uint256 until) external {
        Moderator storage m = moderators[moderator];
        require(m.committed >= amount, "harness: committed < amount");
        m.committed -= amount;
        m.frozen += amount;
        totalCommittedStake -= amount;
        totalFrozenStake += amount;
        if (until > m.frozenUntil) m.frozenUntil = until;
        _syncTree(moderator, m);
    }

    /// Move `amount` of free stake into the committed bucket — the state a
    /// commitVote (§5.3, D5) will create.
    function __commit(address moderator, uint256 amount) external {
        Moderator storage m = moderators[moderator];
        require(m.free - m.pending - m.exitAmount >= amount, "harness: not enough eligible free");
        m.free -= amount;
        m.committed += amount;
        totalFreeStake -= amount;
        totalCommittedStake += amount;
        _syncTree(moderator, m);
    }

    function eligibleWeightInternal(address moderator) external view returns (uint256) {
        return _eligibleWeight(moderators[moderator]);
    }
}
