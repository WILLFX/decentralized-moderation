// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";
import {ProtocolLimits as L} from "./lib/ProtocolLimits.sol";

/// @title RulesetGovernor
/// @notice Governance AUTHORING for the moderation game: proposing, validating
///         and timelocking rulesets and guidelines versions (§9.9, P6).
///
/// ## Why this is a separate contract (M2.6)
///
/// `Moderation` reached EIP-170. The seam taken is **authoring vs enforcement**,
/// and it is a real one rather than an arbitrary byte cut:
///
///   - *Authoring* is cold. A multisig proposes a ruleset, waits out a timelock,
///     executes. It runs a few times in the protocol's life, and it is where all
///     the validation lives — `_validateParams` is by far the largest cold blob
///     in the system.
///   - *Enforcement* is hot. Every case reads its pinned ruleset on every phase
///     transition, through `Moderation._cp()`.
///
/// So the authoring surface moved here and **the ruleset storage deliberately did
/// not**. Moving `rulesets` out too would have turned `_cp()` — which is on every
/// hot path — into a cross-contract call returning a nineteen-field struct. That
/// would have cost more bytes at the call sites than it saved, and a great deal
/// of gas. The governor validates, then pushes the authored result into
/// `Moderation`'s own storage via `applyRuleset`.
///
/// ## Trust
///
/// `Moderation.governor` is immutable, so this contract's authority is exactly
/// what the `governance` address held before the split — no more. The multisig
/// still rotates, through `transferGovernance` here.
///
/// `Moderation.applyRuleset` re-checks the one bound whose violation is a
/// solvency failure rather than a liveness one (`riskPerSeat` must not exceed the
/// registry's duty unit). Full validation lives here, but that single check is
/// enforced at the boundary so a governor bug cannot seat panels on collateral
/// that cannot cover them.
contract RulesetGovernor {
    address public governance; // multisig
    uint256 public immutable timelockDelay;

    /// Bound once, after `Moderation` is deployed pointing at this governor.
    /// The two references are circular at construction, so one of them has to be
    /// set afterwards; this is the side where getting it wrong is recoverable.
    Moderation public moderation;

    struct PendingParams {
        uint256 eta;
        bool exists;
        Moderation.Params p;
        uint256[] commitTargets;
        uint256[] appealWindows;
    }

    struct PendingGuidelines {
        uint256 eta;
        bool exists;
        bytes32 hash;
    }

    PendingParams internal pendingParams;
    PendingGuidelines internal pendingGuidelines;

    event ParametersProposed(uint256 eta);
    event ParametersExecuted();
    event ParametersCancelled();
    event GuidelinesProposed(bytes32 hash, uint256 eta);
    event GuidelinesExecuted(uint256 indexed version, bytes32 hash);
    event GovernanceTransferred(address indexed newGovernance);
    event ModerationBound(address indexed moderation);

    error NotGovernance();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error BadParams();
    error AlreadyBound();
    error NotBound();
    error ZeroAddress();
    /// A proposed ruleset would lock more per seat than a pledged duty unit is
    /// worth, so panels could be seated on collateral that cannot cover them.
    error RiskPerSeatExceedsDutyUnit();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(address _governance, uint256 _timelockDelay) {
        if (_governance == address(0)) revert ZeroAddress();
        governance = _governance;
        timelockDelay = _timelockDelay;
    }

    /// @notice Point this governor at the game contract it governs. One-way: the
    ///         binding is the trust relationship, and `Moderation.governor` is
    ///         immutable on the other side, so a rebind could only ever create a
    ///         governor that governs nothing.
    function bindModeration(Moderation m) external onlyGovernance {
        if (address(moderation) != address(0)) revert AlreadyBound();
        if (address(m) == address(0)) revert ZeroAddress();
        moderation = m;
        emit ModerationBound(address(m));
    }

    // --- rulesets ------------------------------------------------------------

    /// @notice Queue a full replacement of the numeric parameters (validated for
    ///         solvency/liveness sanity). Only these numbers are mutable.
    function proposeParameters(
        Moderation.Params calldata p,
        uint256[] calldata commitTargets,
        uint256[] calldata appealWindows
    ) external onlyGovernance {
        _validateParams(p, commitTargets, appealWindows);
        PendingParams storage pp = pendingParams;
        pp.eta = block.timestamp + timelockDelay;
        pp.exists = true;
        pp.p = p;
        pp.commitTargets = commitTargets;
        pp.appealWindows = appealWindows;
        emit ParametersProposed(pp.eta);
    }

    function executeParameters() external onlyGovernance {
        if (address(moderation) == address(0)) revert NotBound();
        PendingParams storage pp = pendingParams;
        if (!pp.exists) revert NoPendingProposal();
        if (block.timestamp < pp.eta) revert TimelockNotElapsed();
        moderation.applyRuleset(pp.p, pp.commitTargets, pp.appealWindows);
        delete pendingParams;
        emit ParametersExecuted();
    }

    function cancelParameters() external onlyGovernance {
        delete pendingParams;
        emit ParametersCancelled();
    }

    // --- guidelines ----------------------------------------------------------

    /// @notice Queue a new guidelines version. Execution appends a new version
    ///         entry; existing versions are never overwritten (invariant 9).
    function proposeGuidelines(bytes32 hash) external onlyGovernance {
        pendingGuidelines = PendingGuidelines({eta: block.timestamp + timelockDelay, exists: true, hash: hash});
        emit GuidelinesProposed(hash, block.timestamp + timelockDelay);
    }

    function executeGuidelines() external onlyGovernance {
        if (address(moderation) == address(0)) revert NotBound();
        PendingGuidelines storage pg = pendingGuidelines;
        if (!pg.exists) revert NoPendingProposal();
        if (block.timestamp < pg.eta) revert TimelockNotElapsed();
        uint256 version = moderation.applyGuidelines(pg.hash);
        emit GuidelinesExecuted(version, pg.hash);
        delete pendingGuidelines;
    }

    function transferGovernance(address next) external onlyGovernance {
        governance = next;
        emit GovernanceTransferred(next);
    }

    // --- validation ----------------------------------------------------------

    /// @dev Not `pure`: it consults the registry. `riskPerSeat` exists in both the
    ///      game and the stake registry by design — there it is what one DUTY UNIT
    ///      is worth (a staking-layer constant, immutable), here it is what a case
    ///      LOCKS per seat (a consensus parameter, pinned per case by H-11).
    ///      Collapsing them would either break per-case pinning or make draw
    ///      eligibility retroactively mutable.
    ///
    ///      Only one direction of divergence is harmful: a case locking MORE than
    ///      the unit reserved for it, which would seat a panel on collateral that
    ///      cannot cover it. Rejecting that here makes the dangerous desync
    ///      unrepresentable rather than merely documented. `Moderation` re-checks
    ///      this one bound when the ruleset is applied, because it is the only
    ///      validation failure that is a solvency problem rather than a liveness
    ///      one — everything else below can brick a case, but cannot seat an
    ///      uncollateralized panel.
    function _validateParams(
        Moderation.Params calldata p,
        uint256[] calldata commitTargets,
        uint256[] calldata appealWindows
    ) internal view {
        if (address(moderation) == address(0)) revert NotBound();
        if (commitTargets.length == 0 || appealWindows.length == 0) revert BadParams();
        if (commitTargets.length > L.MAX_ARRAY_LEN || appealWindows.length > L.MAX_ARRAY_LEN) revert BadParams();
        if (p.riskPerSeat == 0) revert BadParams();
        // A case must never lock more than one pledged duty unit is worth.
        if (p.riskPerSeat > moderation.stakeReg().riskPerSeat()) revert RiskPerSeatExceedsDutyUnit();
        if (p.minReveals == 0) revert BadParams();
        if (p.bondMultiplier == 0 || p.bondMultiplier > L.MAX_BOND_MULT) revert BadParams();
        if (p.freezeCap < L.WAD) revert BadParams(); // power multiplier >= 1
        if (p.trackDecay > L.WAD) revert BadParams(); // decay is a fraction
        if (p.claimBountyFrac + p.bonusFrac > L.WAD) revert BadParams(); // distributable stays >= 0

        // H-11: hard protocol caps + cross-field sanity so governance cannot brick
        // active or future cases.
        if (p.maxDepth > L.MAX_RULE_DEPTH || p.maxWiden > L.MAX_RULE_WIDEN) revert BadParams();
        if (p.maxTopics == 0 || p.maxTopics > L.MAX_RULE_TOPICS) revert BadParams();
        if (p.seedLag == 0 || p.seedLag > L.MAX_SEED_LAG) revert BadParams();
        if (p.commitTimeout == 0 || p.commitTimeout > L.MAX_WINDOW) revert BadParams();
        if (p.revealWindow == 0 || p.revealWindow > L.MAX_WINDOW) revert BadParams();
        if (p.failedRevealFreeze > L.MAX_FREEZE || p.freezeBase == 0 || p.freezeBase > L.MAX_FREEZE) {
            revert BadParams();
        }
        // minReveals must be reachable within the fully-widened depth-0 panel.
        if (p.minReveals > commitTargets[0] * (1 + p.maxWiden)) revert BadParams();

        uint256 totalDraws;
        for (uint256 i; i < commitTargets.length; ++i) {
            if (commitTargets[i] == 0 || commitTargets[i] > L.MAX_PANEL) revert BadParams();
            // every depth up to maxDepth can widen maxWiden times
            if (i <= p.maxDepth) totalDraws += (1 + p.maxWiden) * commitTargets[i];
        }
        for (uint256 i; i < appealWindows.length; ++i) {
            if (appealWindows[i] == 0 || appealWindows[i] > L.MAX_WINDOW) revert BadParams();
        }
        if (totalDraws > L.MAX_TOTAL_DRAWS) revert BadParams();
    }

    // --- views ---------------------------------------------------------------

    function pendingParamsEta() external view returns (uint256 eta, bool exists) {
        return (pendingParams.eta, pendingParams.exists);
    }

    function pendingGuidelinesEta() external view returns (uint256 eta, bool exists) {
        return (pendingGuidelines.eta, pendingGuidelines.exists);
    }
}
