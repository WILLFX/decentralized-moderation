// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";
import {ProtocolLimits as L} from "./lib/ProtocolLimits.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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
/// still rotates, through `proposeGovernance`/`acceptGovernance` here — two-step
/// and zero-checked, matching both registries.
///
/// `Moderation.applyRuleset` re-checks the one bound whose violation is a
/// solvency failure rather than a liveness one (`riskPerSeat` must not exceed the
/// registry's duty unit). Full validation lives here, but that single check is
/// enforced at the boundary so a governor bug cannot seat panels on collateral
/// that cannot cover them.
contract RulesetGovernor {
    address public governance; // multisig
    /// Nominated successor, pending its own acceptance (L-series two-step).
    address public pendingGovernance;
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
    event GovernanceTransferProposed(address indexed next);
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

    /// @notice Nominate the next governance address. Two-step and zero-checked, to
    ///         match both registries.
    /// @dev The old one-step `transferGovernance` accepted any address, including
    ///      `address(0)`, and took effect immediately. This contract holds the
    ///      protocol's entire ruleset authority — a typo handed it to an address
    ///      nobody controls, and `address(0)` bricked ruleset and guidelines
    ///      governance permanently, with no recovery path because `Moderation.governor`
    ///      is immutable and cannot be repointed at a replacement governor.
    ///      `StakeRegistry` and `IndexRegistry` have had propose/accept since the
    ///      L-series; the governor was left behind when it was split out of
    ///      `Moderation` in M2.6, which is the one place it mattered most.
    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernance = next;
        emit GovernanceTransferProposed(next);
    }

    /// @notice Claim nominated governance. Only the nominee can, which is what
    ///         proves the address is controlled before it holds the authority.
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotGovernance();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(msg.sender);
    }

    function cancelGovernanceTransfer() external onlyGovernance {
        pendingGovernance = address(0);
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
        // M2.6-P0-8: both ends. The lower bound alone let an accepted ruleset
        // overflow `FreezeMath` inside `_settleInit`, which runs before the case
        // reaches a recoverable state — every settlement attempt would revert,
        // permanently, and H-11 pins the ruleset per case.
        if (p.freezeCap < L.WAD || p.freezeCap > L.MAX_FREEZE_MULTIPLIER) revert BadParams();
        // M2.6-P1-3 residual: STRICTLY less than WAD. `> L.WAD` accepted
        // `trackDecay == WAD`, which is not a decay at all — `_touchTrack` computes
        // `t = track * trackDecay / WAD` and then adds a whole WAD for a coherent
        // undisputed participation, so at parity every case adds 1 and nothing ever
        // comes off. Track grows without bound on repeated coherent participation,
        // which is the farming vector WO-6 recalibrated against; below parity it
        // converges to `1 / (1 - trackDecay)` (20 WAD at the shipped 0.95). The
        // `Params` comment already said `< 1e18` — the check was the thing that
        // disagreed with it.
        if (p.trackDecay >= L.WAD) revert BadParams(); // decay is a fraction, strictly
        // M2.6-K-5: and inside the REGISTRY's immutable envelope. Same shape as the
        // `riskPerSeat` check above and for the same reason — H-11 pins a ruleset
        // per case, so a decay the registry will reject is not a bad parameter that
        // gets noticed later, it is a case that can never settle. Checked against
        // the live registry through the game contract, as `riskPerSeat` is.
        if (p.trackDecay < moderation.stakeReg().minTrackDecay()) revert BadParams();
        if (p.claimBountyFrac + p.bonusFrac > L.WAD) revert BadParams(); // distributable stays >= 0

        // H-11: hard protocol caps + cross-field sanity so governance cannot brick
        // active or future cases.
        if (p.maxDepth > L.MAX_RULE_DEPTH || p.maxWiden > L.MAX_RULE_WIDEN) revert BadParams();
        if (p.maxTopics == 0 || p.maxTopics > L.MAX_RULE_TOPICS) revert BadParams();
        if (p.seedLag == 0 || p.seedLag > L.MAX_SEED_LAG) revert BadParams();
        if (p.commitTimeout == 0 || p.commitTimeout > L.MAX_WINDOW) revert BadParams();
        if (p.revealWindow == 0 || p.revealWindow > L.MAX_WINDOW) revert BadParams();
        // M2.6-item-8: `failedRevealFreeze` was bounded here too and is deleted with
        // the parameter. `freezeBase` is now the ONLY freeze duration a ruleset sets,
        // which is the point — there is no second one to keep in step with it.
        if (p.freezeBase == 0 || p.freezeBase > L.MAX_FREEZE) revert BadParams();
        // M2.6-P0-8: and the AMPLIFIED result, which is what settlement actually
        // computes. `MAX_FREEZE` bounded the base and the failed-reveal freeze but
        // never `freezeBase * freezeCap`.
        if (FixedPointMathLib.fullMulDiv(p.freezeBase, p.freezeCap, L.WAD) > L.MAX_FREEZE) revert BadParams();
        // The per-depth SEAT-DRAWING ATTEMPT BUDGET: how many times one depth can
        // seek a target's worth of seats. Named once and used everywhere below,
        // because it is the quantity the aggregate bound is a function of — and the
        // quantity a new retry axis has to enter. `maxWiden` is its only term today.
        uint256 attempts = 1 + p.maxWiden;

        // M2.6-item-2b(3a): full quorum must be achievable WITHOUT the failure
        // path. This was `minReveals <= attempts * commitTargets[0]` —
        // reachability once the widen budget is spent — which admits 20 against a
        // five-seat depth-0 target. Above the un-widened target, perfect
        // participation on a full panel still leaves `revealedSeats < minReveals`,
        // so every round at that depth must widen to reach quorum, every decision
        // there is marked `underQuorum`, and by H-09 no such decision can ever
        // reach the supersafe view AT ANY PARTICIPATION RATE. The parameter would
        // silently disable a product guarantee rather than tighten a quorum.
        //
        // Strictly tighter than the check it replaces, so it is a replacement and
        // not a second knob. Reads the runtime-clamped target, so it composes with
        // P1-3 instead of reintroducing the array-versus-runtime gap one field
        // over. Collaterally it keeps a banked tally smaller than the panel that
        // follows it, which item 2b's residual argument had been ASSUMING.
        uint256 minTarget = type(uint256).max;
        for (uint256 d; d <= p.maxDepth; ++d) {
            uint256 t = _runtimeTarget(commitTargets, d);
            if (t < minTarget) minTarget = t;
        }
        if (p.minReveals > minTarget) revert BadParams();

        // Every supplied entry must be individually sane, whatever depth it serves.
        for (uint256 i; i < commitTargets.length; ++i) {
            if (commitTargets[i] == 0 || commitTargets[i] > L.MAX_PANEL) revert BadParams();
        }
        for (uint256 i; i < appealWindows.length; ++i) {
            if (appealWindows[i] == 0 || appealWindows[i] > L.MAX_WINDOW) revert BadParams();
        }

        // M2.6-P1-3: aggregate reachability, iterating DEPTHS rather than the array.
        //
        // This loop used to run `i < commitTargets.length` and add only when
        // `i <= maxDepth`. `Moderation._commitTarget` CLAMPS to the last entry at
        // deeper depths, so a ruleset supplying fewer targets than `maxDepth + 1`
        // was validated over the entries given and then run over more depths than
        // that — every uncounted depth silently drawing the last entry's worth.
        // `MAX_TOTAL_DRAWS` bounded something the runtime does not do.
        //
        // It is reachable with no attacker and no exotic choice: `commitTargets =
        // [128]`, `maxDepth = 8`, `maxWiden = 8` validated at 9 x 128 = 1,152 draws
        // and runs at 9 x 9 x 128 = 10,368. H-11 pins a ruleset per case, so every
        // case opened under one was bounded by a number that did not apply to it.
        //
        // The shape is what keeps it fixed. `totalDraws` is now
        // `Σ_{d=0..maxDepth} attempts × runtimeTarget(d)`, so it is a function of
        // the two things that actually determine the work — the depths a case can
        // reach and the target each of those depths will really use — and of one
        // attempt budget. A retry axis added later multiplies into `attempts` and
        // needs no new term, no second loop, and no second place to forget.
        uint256 totalDraws;
        for (uint256 d; d <= p.maxDepth; ++d) {
            totalDraws += attempts * _runtimeTarget(commitTargets, d);
        }
        if (totalDraws > L.MAX_TOTAL_DRAWS) revert BadParams();
    }

    /// @dev The value `Moderation._commitTarget` will ACTUALLY return at `depth`,
    ///      clamping to the last entry exactly as it does. Validation and runtime
    ///      reading a target differently is the whole of M2.6-P1-3, so this mirrors
    ///      that one line and nothing else.
    function _runtimeTarget(uint256[] calldata commitTargets, uint256 depth) private pure returns (uint256) {
        uint256 len = commitTargets.length;
        return commitTargets[depth < len ? depth : len - 1];
    }

    // --- views ---------------------------------------------------------------

    function pendingParamsEta() external view returns (uint256 eta, bool exists) {
        return (pendingParams.eta, pendingParams.exists);
    }

    function pendingGuidelinesEta() external view returns (uint256 eta, bool exists) {
        return (pendingGuidelines.eta, pendingGuidelines.exists);
    }
}
