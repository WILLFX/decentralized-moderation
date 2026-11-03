// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakeRegistry} from "../StakeRegistry.sol";
import {Moderation} from "../Moderation.sol";
import {ModerationAuthority} from "./ModerationAuthority.sol";

/// @notice Shared custody, with one obligation per controller/case/voter.
contract PersistentStakeRegistry is StakeRegistry {
    ModerationAuthority public immutable authority;
    // 0 = absent, 1 = outstanding, 2 = settled. Settled records are never erased.
    mapping(address => mapping(uint256 => mapping(address => uint8))) public obligation;
    error CaseScopeRequired();
    error InvalidObligation();

    constructor(ModerationAuthority authority_) StakeRegistry(authority_.token(), authority_.stakeAmount()) {
        authority = authority_;
    }

    // Unscoped write interfaces must never grant completion authority.
    function setModeration(address) external pure override {
        revert CaseScopeRequired();
    }

    function noteCommit(address) external pure override {
        revert CaseScopeRequired();
    }

    function settle(address, bool, uint256) external pure override {
        revert CaseScopeRequired();
    }

    function noteCommit(uint256 id, address voter) external {
        authority.requireCase(msg.sender, id, true);
        Moderation.Vote memory v = Moderation(msg.sender).voteOf(id, voter);
        if (
            obligation[msg.sender][id][voter] != 0 || v.commitment == bytes32(0) || v.settled || !mods[voter].staked
                || mods[voter].frozenUntil > block.timestamp
        ) {
            revert InvalidObligation();
        }
        obligation[msg.sender][id][voter] = 1;
        ++mods[voter].openVotes;
    }

    function settle(uint256 id, address voter) external {
        authority.requireCase(msg.sender, id, false);
        Moderation.Case memory c = Moderation(msg.sender).caseInfo(id);
        Moderation.Vote memory v = Moderation(msg.sender).voteOf(id, voter);
        bool resolved = c.phase == uint8(Moderation.Phase.FINALIZED);
        if (
            (!resolved && c.phase != uint8(Moderation.Phase.UNRESOLVED)) || obligation[msg.sender][id][voter] != 1
                || !v.settled || v.commitment == bytes32(0) || mods[voter].openVotes == 0
        ) revert InvalidObligation();
        obligation[msg.sender][id][voter] = 2;
        bool frozen = v.revealed == 0 || (resolved && v.revealed != c.preliminary);
        _settle(voter, frozen, Moderation(msg.sender).freezePerLoss());
    }
}
