// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IndexRegistry} from "../IndexRegistry.sol";
import {Moderation} from "../Moderation.sol";
import {ModerationAuthority} from "./ModerationAuthority.sol";

/// @notice Persistent topic index with explicit originating-case provenance.
contract PersistentIndexRegistry is IndexRegistry {
    struct Origin {
        address moderation;
        uint256 caseId;
        uint32 guidelinesVersion;
        bytes32 guidelinesHash;
    }
    ModerationAuthority public immutable authority;
    mapping(bytes32 => Origin) public originOf;
    mapping(address => mapping(uint256 => bool)) public applied;
    event OutcomeApplied(address indexed moderation, uint256 indexed caseId, uint8 actionType);
    error CaseScopeRequired();
    error InvalidOutcome();

    constructor(ModerationAuthority authority_) {
        authority = authority_;
    }

    function setModeration(address) external pure override {
        revert CaseScopeRequired();
    }

    function writeEntry(bytes32, bytes32, uint8, bool, bool, uint32, uint32) external pure override {
        revert CaseScopeRequired();
    }

    function removeListing(bytes32, bytes32) external pure override {
        revert CaseScopeRequired();
    }

    /// @dev Reads the originating case; the caller cannot supply a different tally
    /// or topic list. The approved immutable runtime remains a trust boundary.
    function applyOutcome(uint256 id) external {
        authority.requireCase(msg.sender, id, true);
        Moderation m = Moderation(msg.sender);
        Moderation.Case memory c = m.caseInfo(id);
        if (c.phase != uint8(Moderation.Phase.FINALIZED) || applied[msg.sender][id]) revert InvalidOutcome();
        applied[msg.sender][id] = true;
        bytes32[5] memory topics = m.topicsOf(id);
        if (c.preliminary == 1) {
            for (uint256 i; i < c.topicCount; ++i) {
                if (c.actionType == 1) {
                    _removeListing(c.claimKey, topics[i]);
                } else {
                    _writeEntry(
                        c.claimKey,
                        topics[i],
                        1,
                        c.ticketsApprove == 3,
                        c.everChallenged,
                        c.pooledApprove,
                        c.pooledReject
                    );
                    originOf[entryKeyOf(c.claimKey, topics[i])] =
                        Origin(msg.sender, id, m.guidelinesVersion(), m.guidelinesHash());
                }
            }
        }
        emit OutcomeApplied(msg.sender, id, c.actionType);
    }
}
