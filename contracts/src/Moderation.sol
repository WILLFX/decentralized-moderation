// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SortitionTree} from "./lib/SortitionTree.sol";

/// @title Moderation
/// @notice On-chain decentralized moderation contract (specs/state-machine.md).
///         The single deployed contract holds all state — moderators and their
///         stake, the stake-weighted sortition tree, cases, the index, and
///         governance — so the conservation invariant (§9.1) is over one token
///         balance (work order D3).
///
/// @dev Built incrementally per specs/m2-work-order.md. This revision implements
///      the staking layer (M2-1): the free/committed/frozen partition (§3, §9.3),
///      the activation delay, exit cooldown, and the wiring that keeps the
///      sortition tree holding exactly the draw-eligible weight (D6). Case
///      lifecycle, appeals, settlement, index, and governance land in later
///      items.
contract Moderation is ReentrancyGuard {
    using SortitionTree for SortitionTree.Tree;
    using SafeTransferLib for address;

    // --- units ---------------------------------------------------------------

    /// One xBZZ in base units. Swarm BZZ / Gnosis xBZZ uses 16 decimals.
    uint256 internal constant XBZZ = 1e16;

    // --- parameters (§1 working values; governance-settable in M2-7) ---------

    struct Params {
        uint256 minStake; // MIN_STAKE
        uint256 activationDelay; // ACTIVATION_DELAY
        uint256 exitCooldown; // EXIT_COOLDOWN
    }

    Params internal params;

    // --- moderator state (§2) ------------------------------------------------

    struct Moderator {
        uint256 free; // withdrawable balance (partition bucket; includes pending + exit-reserved)
        uint256 pending; // subset of free not yet past its activation delay (not draw-eligible)
        uint256 committed; // stake backing votes in open cases
        uint256 frozen; // stake locked as penalty
        uint256 frozenUntil; // timestamp frozen -> free becomes available; also the draw-exclusion deadline
        uint256 activatesAt; // timestamp `pending` may be activated
        uint256 exitAmount; // amount marked for withdrawal (subset of free; excluded from draws)
        uint256 exitRequestedAt; // 0 if no pending exit
        uint256 track; // decayed coherent-participation record, WAD (used from M2-5)
        bool exists; // has ever staked
    }

    mapping(address => Moderator) internal moderators;

    // --- accounting ----------------------------------------------------------

    IERC20 public immutable token;
    SortitionTree.Tree internal stakeTree;

    uint256 public totalFreeStake; // Σ free
    uint256 public totalCommittedStake; // Σ committed
    uint256 public totalFrozenStake; // Σ frozen

    // --- events --------------------------------------------------------------

    event Staked(address indexed moderator, uint256 amount, uint256 activatesAt);
    event Activated(address indexed moderator, uint256 eligibleWeight);
    event ExitRequested(address indexed moderator, uint256 amount, uint256 claimableAt);
    event Withdrawn(address indexed moderator, uint256 amount);
    event Thawed(address indexed moderator, uint256 amount);

    // --- errors --------------------------------------------------------------

    error BelowMinStake();
    error AmountZero();
    error InsufficientFree();
    error NothingPending();
    error NotYetActivatable();
    error ExitPending();
    error NoExitPending();
    error CooldownNotElapsed();
    error MinStakeFloor();
    error NotFrozen();
    error NoModerator();

    // -------------------------------------------------------------------------

    constructor(IERC20 _token) {
        token = _token;
        stakeTree.initialize(2); // binary sortition tree
        params = Params({minStake: 10 * XBZZ, activationDelay: 7 days, exitCooldown: 7 days});
    }

    // --- staking (§3) --------------------------------------------------------

    /// @notice Deposit xBZZ as stake. The first stake must be >= MIN_STAKE. New
    ///         stake enters `pending` and is not draw-eligible until its
    ///         activation delay elapses and `activate` is called — this is what
    ///         stops just-in-time staking from gaming a specific draw.
    /// @dev Topping up re-arms the activation clock for the pending bucket only;
    ///      stake already activated stays eligible (M2 deviation note, docs at
    ///      M2-10).
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];

        if (!m.exists) {
            if (amount < params.minStake) revert BelowMinStake();
            m.exists = true;
        }

        address(token).safeTransferFrom(msg.sender, address(this), amount);

        m.free += amount;
        m.pending += amount;
        m.activatesAt = block.timestamp + params.activationDelay;
        totalFreeStake += amount;
        // Not synced into the tree: new stake is pending until activation.

        emit Staked(msg.sender, amount, m.activatesAt);
    }

    /// @notice Activate a moderator's pending stake once its delay has elapsed,
    ///         making it draw-eligible. Permissionless poke (D6): activation only
    ///         helps the target, so anyone (a keeper) may call it.
    function activate(address moderator) external {
        Moderator storage m = moderators[moderator];
        if (!m.exists) revert NoModerator();
        if (m.pending == 0) revert NothingPending();
        if (block.timestamp < m.activatesAt) revert NotYetActivatable();

        m.pending = 0; // all free is now past its delay
        _syncTree(moderator, m);
        emit Activated(moderator, _eligibleWeight(m));
    }

    /// @notice Request withdrawal of `amount` free stake. The stake stays in the
    ///         `free` partition bucket during the cooldown (so conservation and
    ///         the §9.3 partition are untouched) but is immediately excluded from
    ///         draws. One pending exit at a time.
    /// @dev MIN_STAKE floor (§3): after the eventual withdrawal the moderator's
    ///      total must be either zero (full exit) or still >= MIN_STAKE.
    function requestExit(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        if (m.exitAmount != 0) revert ExitPending();
        if (amount > m.free) revert InsufficientFree();

        uint256 remaining = _total(m) - amount;
        if (remaining != 0 && remaining < params.minStake) revert MinStakeFloor();

        m.exitAmount = amount;
        m.exitRequestedAt = block.timestamp;
        _syncTree(msg.sender, m); // remove exiting stake from eligibility

        emit ExitRequested(msg.sender, amount, block.timestamp + params.exitCooldown);
    }

    /// @notice Claim a previously requested exit after the cooldown. No admin
    ///         gate exists on this path (invariant §9.5: withdrawals never
    ///         pausable).
    function withdraw() external nonReentrant {
        Moderator storage m = moderators[msg.sender];
        uint256 amount = m.exitAmount;
        if (amount == 0) revert NoExitPending();
        if (block.timestamp < m.exitRequestedAt + params.exitCooldown) revert CooldownNotElapsed();

        // Re-check the floor against current total (committed may have settled
        // back into free, or nothing changed).
        uint256 remaining = _total(m) - amount;
        if (remaining != 0 && remaining < params.minStake) revert MinStakeFloor();

        m.free -= amount;
        totalFreeStake -= amount;
        if (m.pending > m.free) m.pending = m.free; // keep pending <= free
        m.exitAmount = 0;
        m.exitRequestedAt = 0;
        _syncTree(msg.sender, m);

        address(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Release a moderator's frozen stake back to free once its freeze
    ///         has expired. Permissionless poke (D6).
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

    // --- eligibility wiring (D6) ---------------------------------------------

    /// @dev The draw-eligible weight the tree should hold for `m`: zero while the
    ///      moderator is frozen (fully excluded, however small the frozen slice),
    ///      otherwise the free balance minus the pending-activation and
    ///      exit-reserved portions.
    function _eligibleWeight(Moderator storage m) internal view returns (uint256) {
        if (block.timestamp < m.frozenUntil) return 0;
        uint256 reserved = m.pending + m.exitAmount;
        if (m.free <= reserved) return 0;
        return m.free - reserved;
    }

    function _syncTree(address moderator, Moderator storage m) internal {
        stakeTree.set(moderator, _eligibleWeight(m));
    }

    function _total(Moderator storage m) internal view returns (uint256) {
        return m.free + m.committed + m.frozen;
    }

    // --- views ---------------------------------------------------------------

    function moderatorInfo(address moderator)
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
            uint256 exitRequestedAt,
            uint256 track
        )
    {
        Moderator storage m = moderators[moderator];
        return (
            m.free,
            m.pending,
            m.committed,
            m.frozen,
            m.frozenUntil,
            m.activatesAt,
            m.exitAmount,
            m.exitRequestedAt,
            m.track
        );
    }

    function totalStakeOf(address moderator) external view returns (uint256) {
        return _total(moderators[moderator]);
    }

    function eligibleWeightOf(address moderator) external view returns (uint256) {
        return stakeTree.weightOf(moderator);
    }

    function totalEligibleWeight() external view returns (uint256) {
        return stakeTree.total();
    }

    function getParams() external view returns (Params memory) {
        return params;
    }
}
