// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";

interface IModerationVersion {
    function authority() external view returns (address);
    function stakes() external view returns (address);
    function index() external view returns (address);
    function token() external view returns (address);
    function rulesHash() external view returns (bytes32);
}

interface IAuthorityRegistry {
    function authority() external view returns (address);
}

interface IAuthorityCustody is IAuthorityRegistry {
    function token() external view returns (address);
    function stakeAmount() external view returns (uint256);
}

/// @notice One active case opener, with permanent case-scoped completion rights.
/// @dev The authorizer is an explicitly supplied account (normally a multisig).
/// It cannot edit cases, move custody funds or revoke completion rights. Runtime
/// pins identify reviewed code; they are not a proof that arbitrary code is honest.
contract ModerationAuthority {
    struct Proposal {
        address candidate;
        bytes32 codeHash;
        bytes32 rulesHash;
        uint256 activateAfter;
    }

    struct CaseRef {
        address moderation;
        uint256 caseId;
    }

    struct Registration {
        bool exists;
        bool terminal;
        address targetModeration;
        uint256 targetCaseId;
    }

    address public immutable authorizer;
    uint256 public immutable noticePeriod;
    address public immutable token;
    uint256 public immutable stakeAmount;
    address public stakes;
    address public index;
    address public active;
    Proposal public proposal;
    mapping(address => bytes32) public codeHashOf;
    mapping(address => bytes32) public rulesHashOf;
    mapping(address => mapping(uint256 => Registration)) public registration;
    mapping(bytes32 => CaseRef) public openRemoval;
    mapping(bytes32 => bool) public removed;

    event RegistriesBound(address indexed stakes, address indexed index);
    event ReplacementProposed(address indexed candidate, bytes32 codeHash, bytes32 rulesHash, uint256 activateAfter);
    event ReplacementCancelled(address indexed candidate);
    event ReplacementActivated(address indexed previous, address indexed current);
    event CaseRegistered(address indexed moderation, uint256 indexed caseId, address target, uint256 targetCaseId);
    event CaseCompleted(address indexed moderation, uint256 indexed caseId);

    error NotAuthorizer();
    error BadConfiguration();
    error AlreadyBound();
    error PendingProposal();
    error NoProposal();
    error NoticeNotElapsed();
    error InvalidVersion();
    error NotActive();
    error UnknownCase();
    error CaseClosed();
    error RemovalUnavailable();

    constructor(address authorizer_, uint256 noticePeriod_, address token_, uint256 stakeAmount_) {
        if (authorizer_ == address(0) || noticePeriod_ == 0 || token_.code.length == 0 || stakeAmount_ == 0) {
            revert BadConfiguration();
        }
        authorizer = authorizer_;
        noticePeriod = noticePeriod_;
        token = token_;
        stakeAmount = stakeAmount_;
    }

    modifier onlyAuthorizer() {
        if (msg.sender != authorizer) revert NotAuthorizer();
        _;
    }

    function bindRegistries(address stakes_, address index_) external onlyAuthorizer {
        if (stakes != address(0)) revert AlreadyBound();
        if (stakes_ == index_ || stakes_.code.length == 0 || index_.code.length == 0) {
            revert BadConfiguration();
        }
        if (
            IAuthorityCustody(stakes_).authority() != address(this)
                || IAuthorityRegistry(index_).authority() != address(this)
                || IAuthorityCustody(stakes_).token() != token
                || IAuthorityCustody(stakes_).stakeAmount() != stakeAmount
        ) revert BadConfiguration();
        stakes = stakes_;
        index = index_;
        emit RegistriesBound(stakes_, index_);
    }

    function propose(address candidate, bytes32 runtimeHash, bytes32 expectedRulesHash) external onlyAuthorizer {
        if (proposal.candidate != address(0)) revert PendingProposal();
        if (codeHashOf[candidate] != bytes32(0)) revert InvalidVersion();
        _validate(candidate, runtimeHash, expectedRulesHash);
        proposal = Proposal(candidate, runtimeHash, expectedRulesHash, block.timestamp + noticePeriod);
        emit ReplacementProposed(candidate, runtimeHash, expectedRulesHash, proposal.activateAfter);
    }

    function cancel() external onlyAuthorizer {
        address candidate = proposal.candidate;
        if (candidate == address(0)) revert NoProposal();
        delete proposal;
        emit ReplacementCancelled(candidate);
    }

    /// @notice Anyone can execute the exact approved proposal after its delay.
    function activate() external {
        Proposal memory p = proposal;
        if (p.candidate == address(0)) revert NoProposal();
        if (block.timestamp < p.activateAfter) revert NoticeNotElapsed();
        _validate(p.candidate, p.codeHash, p.rulesHash);
        address previous = active;
        active = p.candidate;
        codeHashOf[p.candidate] = p.codeHash;
        rulesHashOf[p.candidate] = p.rulesHash;
        delete proposal;
        emit ReplacementActivated(previous, active);
    }

    function _validate(address candidate, bytes32 runtimeHash, bytes32 expectedRulesHash) internal view {
        if (
            stakes == address(0) || candidate.code.length == 0 || runtimeHash == bytes32(0)
                || candidate.codehash != runtimeHash
        ) revert InvalidVersion();
        IModerationVersion c = IModerationVersion(candidate);
        if (
            c.authority() != address(this) || c.stakes() != stakes || c.index() != index || c.token() != token
                || expectedRulesHash == bytes32(0) || c.rulesHash() != expectedRulesHash
        ) revert InvalidVersion();
    }

    function targetKey(address controller, uint256 id) public pure returns (bytes32) {
        return keccak256(abi.encode(controller, id));
    }

    function requireCase(address controller, uint256 id, bool mustBeOpen) public view {
        Registration storage r = registration[controller][id];
        if (!r.exists || codeHashOf[controller] == bytes32(0) || controller.codehash != codeHashOf[controller]) {
            revert UnknownCase();
        }
        if (mustBeOpen && r.terminal) revert CaseClosed();
    }

    function registerCase(uint256 id, address target, uint256 targetId) external {
        if (msg.sender != active) revert NotActive();
        if (id == 0 || registration[msg.sender][id].exists) revert BadConfiguration();
        if (msg.sender.codehash != codeHashOf[msg.sender]) revert InvalidVersion();
        Moderation.Case memory c = Moderation(msg.sender).caseInfo(id);
        if (c.phase != uint8(Moderation.Phase.COMMIT_A)) revert BadConfiguration();
        if (c.actionType == 1) {
            requireCase(target, targetId, false);
            Moderation.Case memory t = Moderation(target).caseInfo(targetId);
            bytes32 key = targetKey(target, targetId);
            if (
                t.phase != uint8(Moderation.Phase.FINALIZED) || t.actionType != 0 || t.preliminary != 1 || removed[key]
                    || openRemoval[key].moderation != address(0) || c.targetCaseId != targetId
                    || c.claimKey != t.claimKey || c.contentHash != t.contentHash || c.metaHash != t.metaHash
                    || c.topicCount != t.topicCount
            ) revert RemovalUnavailable();
            if (
                keccak256(abi.encode(Moderation(msg.sender).topicsOf(id)))
                    != keccak256(abi.encode(Moderation(target).topicsOf(targetId)))
            ) revert RemovalUnavailable();
            openRemoval[key] = CaseRef(msg.sender, id);
        } else if (c.actionType != 0 || target != address(0) || targetId != 0) {
            revert BadConfiguration();
        }
        registration[msg.sender][id] = Registration(true, false, target, targetId);
        emit CaseRegistered(msg.sender, id, target, targetId);
    }

    function completeCase(uint256 id) external {
        requireCase(msg.sender, id, true);
        Moderation.Case memory c = Moderation(msg.sender).caseInfo(id);
        if (c.phase != uint8(Moderation.Phase.FINALIZED) && c.phase != uint8(Moderation.Phase.UNRESOLVED)) {
            revert CaseClosed();
        }
        Registration storage r = registration[msg.sender][id];
        r.terminal = true;
        if (r.targetModeration != address(0)) {
            bytes32 key = targetKey(r.targetModeration, r.targetCaseId);
            CaseRef memory owner = openRemoval[key];
            if (owner.moderation != msg.sender || owner.caseId != id) revert RemovalUnavailable();
            delete openRemoval[key];
            if (c.phase == uint8(Moderation.Phase.FINALIZED) && c.preliminary == 1) removed[key] = true;
        }
        emit CaseCompleted(msg.sender, id);
    }

}

function moderationRulesHash(Moderation.Config memory cfg) pure returns (bytes32) {
        return keccak256(
            abi.encode(
                cfg.token,
                cfg.commitWindow,
                cfg.revealWindow,
                cfg.challengeWindow,
                cfg.maxWaitForThird,
                cfg.freezePerLoss,
                cfg.seedLag,
                cfg.feeMin,
                cfg.minRevealsPerCommittee,
                cfg.guidelinesVersion,
                cfg.guidelinesHash
            )
        );
    }
