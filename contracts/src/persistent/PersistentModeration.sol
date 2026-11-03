// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../Moderation.sol";
import {ModerationAuthority} from "./ModerationAuthority.sol";
import {PersistentStakeRegistry} from "./PersistentStakeRegistry.sol";
import {PersistentIndexRegistry} from "./PersistentIndexRegistry.sol";
import {ModerationRules} from "./ModerationRules.sol";

/// @notice The existing moderation state machine, using case-scoped registries.
contract PersistentModeration is Moderation {
    ModerationAuthority public immutable authority;
    bytes32 public immutable rulesHash;
    mapping(uint256 => address) public removalTargetModeration;
    event CrossVersionRemovalSubmitted(
        uint256 indexed caseId, address indexed targetModeration, uint256 indexed targetCaseId
    );
    error PersistentConfigurationMismatch();

    constructor(Config memory cfg, ModerationAuthority authority_) Moderation(cfg) {
        authority = authority_;
        rulesHash = rulesHashOf(cfg);
        if (
            cfg.token != authority_.token()
                || address(PersistentStakeRegistry(cfg.stakes).authority()) != address(authority_)
                || address(PersistentIndexRegistry(cfg.index).authority()) != address(authority_)
        ) {
            revert PersistentConfigurationMismatch();
        }
    }

    /// @notice Identifies the parameters/guidelines reviewed for this version.
    /// This fingerprint does not prove the behavior of arbitrarily supplied code.
    function rulesHashOf(Config memory cfg) public pure returns (bytes32) {
        return ModerationRules.hash(cfg);
    }

    function _open(uint256 id, uint256 fee) internal override {
        super._open(id, fee);
        authority.registerCase(id, removalTargetModeration[id], cases[id].targetCaseId);
    }

    function _noteCommit(uint256 id, address voter) internal override {
        PersistentStakeRegistry(address(stakes)).noteCommit(id, voter);
    }

    function _settleVote(uint256 id, address voter, bool) internal override {
        PersistentStakeRegistry(address(stakes)).settle(id, voter);
    }

    function _applyOutcome(uint256 id) internal override {
        PersistentIndexRegistry(address(index)).applyOutcome(id);
        if (cases[id].actionType == ACTION_REMOVE && cases[id].preliminary == uint8(Outcome.APPROVE)) {
            emit Removed(cases[id].targetCaseId, id);
        }
    }

    function _completeCase(uint256 id) internal override {
        authority.completeCase(id);
    }

    function submitRemoval(uint256 targetId, uint256 fee) external override nonReentrant returns (uint256 id) {
        return _submitRemoval(address(this), targetId, fee);
    }

    function submitRemoval(address target, uint256 targetId, uint256 fee) external nonReentrant returns (uint256 id) {
        return _submitRemoval(target, targetId, fee);
    }

    function _submitRemoval(address target, uint256 targetId, uint256 fee) internal returns (uint256 id) {
        if (fee < feeMin) revert FeeTooLow();
        authority.requireCase(target, targetId, false);
        Moderation.Case memory t = Moderation(target).caseInfo(targetId);
        if (t.phase != uint8(Phase.FINALIZED) || t.actionType != ACTION_LIST || t.preliminary != uint8(Outcome.APPROVE))
        {
            revert NotARemovableListing();
        }
        id = nextCaseId++;
        Case storage c = cases[id];
        c.contentHash = t.contentHash;
        c.metaHash = t.metaHash;
        c.claimKey = t.claimKey;
        c.submitter = msg.sender;
        c.topicCount = t.topicCount;
        c.actionType = ACTION_REMOVE;
        c.targetCaseId = targetId;
        removalTargetModeration[id] = target;
        caseTopics[id] = Moderation(target).topicsOf(targetId);
        _open(id, fee);
        emit RemovalSubmitted(id, targetId, msg.sender);
        emit CrossVersionRemovalSubmitted(id, target, targetId);
    }
}
