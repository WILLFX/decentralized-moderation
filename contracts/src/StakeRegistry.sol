// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SortitionTree} from "./lib/SortitionTree.sol";

/// @title StakeRegistry
/// @notice Custody + bookkeeping for moderator stake, independent of the
///         moderation game's business logic (M2.5-P0-b).
///
///         The moderation protocol is expected to be improved over time. If stake
///         lived inside the game contract, every redeployment would force every
///         moderator to withdraw and re-stake — a migration that costs real money,
///         loses the moderator set, and (worse) is the kind of hassle that quietly
///         kills participation. So stake lives here, permanently, and the *game*
///         is the replaceable part: governance repoints this registry at a new
///         logic contract and nobody re-stakes.
///
///         This registry knows only: who has stake, how it is partitioned
///         (free / pending / committed / frozen / exiting), and how much draw
///         weight each moderator carries. It has no notion of cases, votes,
///         appeals or outcomes — those belong to the logic contract.
///
/// ## Trust model (the part that matters)
///
/// The authorized logic contract is powerful: it can lock, freeze and credit
/// stake. Repointing the registry at a new logic contract therefore *is* the
/// protocol's trust root, and it is deliberately constrained:
///
/// 1. **Timelocked.** A repoint must be proposed and can only be executed after
///    `timelockDelay`, so moderators always see a migration coming.
/// 2. **Exit is never gated by logic.** `requestExit`/`withdraw` are callable by
///    the owner of the stake and never consult the logic contract. A moderator who
///    dislikes an announced migration can always leave during the timelock window.
///    There is no pause, and governance cannot add one. (Invariant §9.5.)
/// 3. **Handover window.** The outgoing logic stays authorized until its open
///    cases settle, so a migration cannot strand in-flight cases: both the old and
///    the new logic are authorized during the handover.
/// 4. **No governance access to funds.** Governance can name the logic contract
///    and nothing else; it can never move, freeze, or credit a single wei itself.
contract StakeRegistry {
    using SafeTransferLib for address;
    using SortitionTree for SortitionTree.Tree;

    // --- storage -------------------------------------------------------------

    struct Moderator {
        uint256 free; // withdrawable (includes pending + exit-reserved)
        uint256 pending; // not yet past activation delay -> not draw-eligible
        uint256 committed; // locked against open cases by the logic contract
        uint256 frozen; // penalty-locked
        uint256 frozenUntil;
        uint256 activatesAt;
        uint256 exitAmount;
        uint256 exitClaimableAt; // snapshotted at request (H-11)
        uint256 track; // coherent-participation record (WAD), maintained by logic
        bool exists;
    }

    IERC20 public immutable token;

    mapping(address => Moderator) internal moderators;
    SortitionTree.Tree internal stakeTree;

    uint256 public totalFreeStake;
    uint256 public totalCommittedStake;
    uint256 public totalFrozenStake;

    // Parameters this registry needs on its own (it must not depend on the logic
    // contract for the exit path — see trust model #2).
    uint256 public minStake;
    uint256 public activationDelay;
    uint256 public exitCooldown;

    // --- authorization -------------------------------------------------------

    address public governance;
    uint256 public immutable timelockDelay;

    /// Authorized logic contracts. More than one may be authorized at a time so a
    /// migration can hand over while the outgoing logic settles its open cases.
    mapping(address => bool) public isLogic;

    struct PendingLogic {
        address logic;
        uint256 eta;
        bool exists;
    }

    PendingLogic public pendingLogic;

    // --- events --------------------------------------------------------------

    event Staked(address indexed moderator, uint256 amount, uint256 activatesAt);
    event Activated(address indexed moderator, uint256 eligibleWeight);
    event ExitRequested(address indexed moderator, uint256 amount, uint256 claimableAt);
    event Withdrawn(address indexed moderator, uint256 amount);
    event Thawed(address indexed moderator, uint256 amount);
    event StakeLocked(address indexed moderator, uint256 amount);
    event StakeReleased(address indexed moderator, uint256 amount);
    event StakeFrozen(address indexed moderator, uint256 amount, uint256 until);
    event Rewarded(address indexed moderator, uint256 amount);
    event TrackSet(address indexed moderator, uint256 track);

    event LogicProposed(address indexed logic, uint256 eta);
    event LogicAuthorized(address indexed logic);
    event LogicRevoked(address indexed logic);
    event GovernanceTransferProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    // --- errors --------------------------------------------------------------

    error NotGovernance();
    error NotLogic();
    error AmountZero();
    error BelowMinStake();
    error InsufficientFree();
    error InsufficientEligibleFree();
    error MinStakeFloor();
    error ExitPending();
    error NoExitPending();
    error CooldownNotElapsed();
    error NotFrozen();
    error NoModerator();
    error NothingPending();
    error NotYetActivatable();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error ZeroAddress();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLogic() {
        if (!isLogic[msg.sender]) revert NotLogic();
        _;
    }

    constructor(IERC20 _token, uint256 _timelockDelay, uint256 _minStake, uint256 _activationDelay, uint256 _exitCooldown) {
        if (address(_token) == address(0)) revert ZeroAddress();
        token = _token;
        timelockDelay = _timelockDelay;
        minStake = _minStake;
        activationDelay = _activationDelay;
        exitCooldown = _exitCooldown;
        governance = msg.sender;
        stakeTree.initialize(2);
    }

    // =========================================================================
    // Moderator-facing: never gated by the logic contract (trust model #2)
    // =========================================================================

    function stake(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        // Floor binds on CURRENT total, so stake -> full exit -> dust re-stake
        // cannot enter the tree below the minimum (H-07).
        if (_total(m) == 0 && amount < minStake) revert BelowMinStake();
        m.exists = true;

        address(token).safeTransferFrom(msg.sender, address(this), amount);
        m.free += amount;
        m.pending += amount;
        m.activatesAt = block.timestamp + activationDelay;
        totalFreeStake += amount;

        emit Staked(msg.sender, amount, m.activatesAt);
    }

    /// Permissionless poke: activation only ever helps its target.
    function activate(address moderator) external {
        Moderator storage m = moderators[moderator];
        if (!m.exists) revert NoModerator();
        if (m.pending == 0) revert NothingPending();
        if (block.timestamp < m.activatesAt) revert NotYetActivatable();
        m.pending = 0;
        _syncTree(moderator, m);
        emit Activated(moderator, _eligibleWeight(m));
    }

    function requestExit(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        if (m.exitAmount != 0) revert ExitPending();
        if (amount > m.free) revert InsufficientFree();
        uint256 remaining = _total(m) - amount;
        if (remaining != 0 && remaining < minStake) revert MinStakeFloor();

        m.exitAmount = amount;
        // Terms are settled now: a later parameter change can neither extend the
        // wait nor invalidate an already-valid exit (H-11).
        m.exitClaimableAt = block.timestamp + exitCooldown;
        _syncTree(msg.sender, m);
        emit ExitRequested(msg.sender, amount, m.exitClaimableAt);
    }

    /// @notice Claim a requested exit. Deliberately independent of the logic
    ///         contract and of governance: no admin gate exists on this path, and
    ///         none can be added, so a moderator can always leave — including
    ///         during the timelock of a migration it does not consent to.
    function withdraw() external {
        Moderator storage m = moderators[msg.sender];
        uint256 amount = m.exitAmount;
        if (amount == 0) revert NoExitPending();
        if (block.timestamp < m.exitClaimableAt) revert CooldownNotElapsed();

        m.free -= amount;
        totalFreeStake -= amount;
        if (m.pending > m.free) m.pending = m.free;
        m.exitAmount = 0;
        m.exitClaimableAt = 0;
        _syncTree(msg.sender, m);

        address(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// Permissionless poke: releases an already-expired freeze.
    function thaw(address moderator) external {
        Moderator storage m = moderators[moderator];
        if (m.frozen == 0) revert NotFrozen();
        if (block.timestamp < m.frozenUntil) revert NotFrozen();
        uint256 amount = m.frozen;
        m.frozen = 0;
        totalFrozenStake -= amount;
        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit Thawed(moderator, amount);
    }

    // =========================================================================
    // Logic-facing: the narrow privileged API
    // =========================================================================

    /// Move `amount` free -> committed (backing a vote in an open case).
    function lock(address moderator, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        uint256 reserved = m.pending + m.exitAmount;
        uint256 eligible = m.free > reserved ? m.free - reserved : 0;
        if (eligible < amount) revert InsufficientEligibleFree();
        m.free -= amount;
        m.committed += amount;
        totalFreeStake -= amount;
        totalCommittedStake += amount;
        _syncTree(moderator, m);
        emit StakeLocked(moderator, amount);
    }

    /// Move `amount` committed -> free (case settled coherently).
    function release(address moderator, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        m.committed -= amount;
        m.free += amount;
        totalCommittedStake -= amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit StakeReleased(moderator, amount);
    }

    /// Move `amount` committed -> frozen until `until` (penalty; never a transfer).
    function freeze(address moderator, uint256 amount, uint256 until) external onlyLogic {
        Moderator storage m = moderators[moderator];
        m.committed -= amount;
        m.frozen += amount;
        totalCommittedStake -= amount;
        totalFrozenStake += amount;
        if (until > m.frozenUntil) m.frozenUntil = until;
        _syncTree(moderator, m);
        emit StakeFrozen(moderator, amount, m.frozenUntil);
    }

    /// Credit a reward to free balance. The logic contract must have transferred
    /// the corresponding tokens to this registry (rewards are external money —
    /// fees and forfeited bonds — never another moderator's principal).
    function reward(address moderator, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit Rewarded(moderator, amount);
    }

    function setTrack(address moderator, uint256 newTrack) external onlyLogic {
        moderators[moderator].track = newTrack;
        emit TrackSet(moderator, newTrack);
    }

    /// Stake-weighted draw over the currently eligible set.
    function draw(uint256 rand) external view returns (address) {
        return stakeTree.draw(rand);
    }

    // =========================================================================
    // Governance: may name the logic contract, and nothing else
    // =========================================================================

    function proposeLogic(address logic) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        pendingLogic = PendingLogic({logic: logic, eta: block.timestamp + timelockDelay, exists: true});
        emit LogicProposed(logic, block.timestamp + timelockDelay);
    }

    /// @notice Authorize the proposed logic contract after the timelock. The
    ///         previously authorized logic is NOT revoked here: both stay
    ///         authorized so in-flight cases can settle under the old rules
    ///         (handover window, trust model #3). Governance revokes the old one
    ///         explicitly once it has drained.
    function executeLogic() external onlyGovernance {
        PendingLogic memory pl = pendingLogic;
        if (!pl.exists) revert NoPendingProposal();
        if (block.timestamp < pl.eta) revert TimelockNotElapsed();
        isLogic[pl.logic] = true;
        delete pendingLogic;
        emit LogicAuthorized(pl.logic);
    }

    function cancelLogic() external onlyGovernance {
        delete pendingLogic;
    }

    /// Revoke a drained logic contract. Immediate: revocation only ever REDUCES
    /// privilege, so it needs no timelock.
    function revokeLogic(address logic) external onlyGovernance {
        isLogic[logic] = false;
        emit LogicRevoked(logic);
    }

    // Two-step governance transfer (L-series): no accidental hand-off to a
    // mistyped or zero address.
    address public pendingGovernance;

    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernance = next;
        emit GovernanceTransferProposed(next);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotGovernance();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(msg.sender);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function moderatorInfo(address a)
        external
        view
        returns (
            uint256 free,
            uint256 pending,
            uint256 committed,
            uint256 frozen,
            uint256 frozenUntil,
            uint256 activatesAt,
            uint256 exitAmount,
            uint256 exitClaimableAt,
            uint256 track
        )
    {
        Moderator storage m = moderators[a];
        return (
            m.free, m.pending, m.committed, m.frozen, m.frozenUntil, m.activatesAt, m.exitAmount, m.exitClaimableAt, m.track
        );
    }

    function totalStakeOf(address a) external view returns (uint256) {
        return _total(moderators[a]);
    }

    function trackOf(address a) external view returns (uint256) {
        return moderators[a].track;
    }

    function eligibleWeightOf(address a) external view returns (uint256) {
        return _eligibleWeight(moderators[a]);
    }

    function totalEligibleWeight() external view returns (uint256) {
        return stakeTree.total();
    }

    /// Conservation: every token held is somebody's stake, in exactly one bucket.
    function stakeBuckets() external view returns (uint256) {
        return totalFreeStake + totalCommittedStake + totalFrozenStake;
    }

    // --- internals -----------------------------------------------------------

    function _total(Moderator storage m) internal view returns (uint256) {
        return m.free + m.committed + m.frozen;
    }

    function _eligibleWeight(Moderator storage m) internal view returns (uint256) {
        if (block.timestamp < m.frozenUntil) return 0; // fully excluded while frozen
        uint256 reserved = m.pending + m.exitAmount;
        if (m.free <= reserved) return 0;
        return m.free - reserved;
    }

    function _syncTree(address moderator, Moderator storage m) internal {
        stakeTree.set(moderator, _eligibleWeight(m));
    }
}
