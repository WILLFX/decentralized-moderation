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
/// 5. **Credits must be funded.** `reward()` pulls its own tokens and verifies the
///    measured balance delta (M2.6-P0-4). An authorized logic cannot conjure a
///    withdrawable balance, so it cannot drain other stakers' principal through the
///    ordinary exit path.
///
/// ## What this registry does NOT yet guarantee (be honest about it)
///
/// Obligations are still recorded as bare aggregates (`committed`, `frozen`,
/// `dutyReserved`, `track`) with no obligation id and no originating-logic
/// namespace. While two logics are authorized during a handover, either can
/// release, freeze, or overwrite obligations created by the other — by malice OR by
/// an ordinary bug — and the outgoing logic's honest settlement can then underflow.
/// There is also no on-chain `canRevoke(logic)`: revocation relies on governance
/// believing the old logic has drained.
///
/// So the true solvency statement today is: *principal cannot be minted, but
/// obligation bookkeeping is only correct if every authorized logic is correct and
/// stays inside its own cases.* M2.6-P0-5 (obligation-scoped accounting) is what
/// closes the remaining gap; do not describe the isolation as complete until it does.
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
        // H-07 duty pool: pledged concurrent seat capacity and how much of it is
        // held by live panels. Only available capacity is draw-eligible, so
        // selection weight equals collateral that can actually be locked, and
        // stake that never opted in is never drawable.
        uint256 dutyUnits;
        uint256 dutyReserved;
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
    /// @notice What ONE DUTY UNIT is worth: the collateral a moderator pledges
    ///         per concurrent seat it offers to serve. This is a staking-layer
    ///         constant, and it is deliberately `immutable`.
    ///
    ///         The logic contract has its own `riskPerSeat` — what a case LOCKS
    ///         per seat — which is a consensus parameter and is pinned per case
    ///         (H-11). The two are different roles and must not be collapsed:
    ///         collapsing them would either break per-case pinning or make draw
    ///         eligibility retroactively mutable.
    ///
    ///         Only one direction of divergence is harmful: a case locking MORE
    ///         than the unit reserved for it, which would let a panel be seated
    ///         on collateral that cannot cover it. `Moderation._validateParams`
    ///         rejects any ruleset with `riskPerSeat > stakeReg.riskPerSeat()`,
    ///         so that state is unrepresentable. Immutability here is what makes
    ///         that check trustworthy — a mutable value could be lowered after a
    ///         ruleset was validated against it.
    uint256 public immutable riskPerSeat;

    /// H-05: bumped whenever draw-eligible weight is ADDED, so the logic contract
    /// can detect an eligibility change between arming a seed and drawing on it
    /// and re-arm to fresh entropy. Every path that grows the drawable set must
    /// bump it — `activate` (pending becomes drawable), `thaw` (a frozen
    /// moderator re-enters), and `setDutyUnits` (capacity is pledged) — or an
    /// attacker can wait for a seed's blockhash to become public and only then
    /// reshape the tree in its favour (adaptive-activation grinding).
    uint256 public eligibilityAddVersion;

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
    event DutyUnitsSet(address indexed moderator, uint256 units, uint256 reserved);
    event NoShowPenalized(address indexed moderator, uint256 penalty, uint256 until);

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
    error RewardNotFunded(); // reward() must be funded by the caller in the same call

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLogic() {
        if (!isLogic[msg.sender]) revert NotLogic();
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _timelockDelay,
        uint256 _minStake,
        uint256 _activationDelay,
        uint256 _exitCooldown,
        uint256 _riskPerSeat
    ) {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_riskPerSeat == 0) revert AmountZero();
        token = _token;
        timelockDelay = _timelockDelay;
        minStake = _minStake;
        activationDelay = _activationDelay;
        exitCooldown = _exitCooldown;
        riskPerSeat = _riskPerSeat;
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
        eligibilityAddVersion++; // H-05: eligible weight grew
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

    /// @notice Pledge concurrent seat capacity (H-07). Each unit is backed by
    ///         `riskPerSeat` of your own stake, and only pledged, unreserved
    ///         capacity is draw-eligible. Duty is opt-in precisely so that failing
    ///         to serve can be penalized without conscripting passive stakers.
    function setDutyUnits(uint256 units) external {
        Moderator storage m = moderators[msg.sender];
        if (!m.exists) revert NoModerator();
        if (units > 0) {
            uint256 reserved = m.pending + m.exitAmount;
            uint256 usable = m.free > reserved ? m.free - reserved : 0;
            if (usable < units * riskPerSeat) revert InsufficientEligibleFree();
            eligibilityAddVersion++; // H-05
        }
        m.dutyUnits = units;
        _syncTree(msg.sender, m);
        emit DutyUnitsSet(msg.sender, units, m.dutyReserved);
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
        eligibilityAddVersion++; // H-05: eligible weight grew
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
    /// @notice Credit a reward, pulling its funding from the caller in the same
    ///         call. The logic contract must have approved this registry.
    ///
    ///         The funding is ENFORCED here, not assumed. Previously this function
    ///         only incremented balances and the requirement to transfer first lived
    ///         in a comment — so any authorized logic (buggy, superseded, or
    ///         malicious) could mint withdrawable claims from nothing and drain real
    ///         stakers via requestExit/withdraw. A safety property written in prose
    ///         is not a safety property.
    ///
    ///         The measured balance delta also catches a caller funding with the
    ///         wrong token, which would otherwise leave the registry insolvent in
    ///         the asset it actually owes.
    function reward(address moderator, uint256 amount) external onlyLogic {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[moderator];

        uint256 before = token.balanceOf(address(this));
        address(token).safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert RewardNotFunded();

        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit Rewarded(moderator, amount);
    }

    function setTrack(address moderator, uint256 newTrack) external onlyLogic {
        moderators[moderator].track = newTrack;
        emit TrackSet(moderator, newTrack);
    }

    /// Stake-weighted draw over the currently eligible set (read-only preview).
    function draw(uint256 rand) external view returns (address) {
        return stakeTree.draw(rand);
    }

    /// @notice Draw a panel of `count` seats, RESERVING one duty unit per seat
    ///         (H-07). A moderator whose pledged capacity is exhausted mid-draw
    ///         drops out of the tree for the rest of this draw (its weight is
    ///         restored before returning), so seats land only where collateral
    ///         exists — no rejection sampling, and attempts are bounded at 2×count.
    /// @return seats The drawn addresses, one entry per seat (duplicates possible).
    function drawPanel(uint256 count, bytes32 seed, uint256 offset)
        external
        onlyLogic
        returns (address[] memory seats, uint256 attempts)
    {
        seats = new address[](count);
        address[] memory excluded = new address[](count);
        uint256 nExcluded;
        uint256 drawn;
        uint256 maxAttempts = 2 * count;
        while (drawn < count && attempts < maxAttempts) {
            if (stakeTree.total() == 0) break; // no capacity left network-wide
            address seat = stakeTree.draw(uint256(keccak256(abi.encode(seed, offset + attempts))));
            attempts++;
            Moderator storage m = moderators[seat];
            if (m.dutyUnits <= m.dutyReserved) {
                if (nExcluded < count) {
                    excluded[nExcluded++] = seat;
                    stakeTree.set(seat, 0);
                }
                continue;
            }
            m.dutyReserved += 1;
            seats[drawn++] = seat;
            _syncTree(seat, m); // weight shrinks as capacity is consumed
        }
        for (uint256 j; j < nExcluded; ++j) {
            Moderator storage em = moderators[excluded[j]];
            stakeTree.set(excluded[j], _eligibleWeight(em));
        }
        if (drawn < count) {
            // Shrink to what was actually seated.
            assembly {
                mstore(seats, drawn)
            }
        }
    }

    /// Release duty capacity held by a finished round.
    function releaseDuty(address moderator, uint256 units) external onlyLogic {
        Moderator storage m = moderators[moderator];
        uint256 rel = units > m.dutyReserved ? m.dutyReserved : units;
        m.dutyReserved -= rel;
        _syncTree(moderator, m);
    }

    /// @notice Penalize a moderator that pledged capacity, was drawn on it, and
    ///         never committed: freeze `amount` of its own FREE stake until
    ///         `until`. Never a transfer — no internal attack profit exists.
    function penalizeNoShow(address moderator, uint256 amount, uint256 until) external onlyLogic {
        Moderator storage m = moderators[moderator];
        if (m.dutyUnits == 0) return; // never opted in -> was not drawable
        uint256 reserved = m.pending + m.exitAmount;
        uint256 usable = m.free > reserved ? m.free - reserved : 0;
        uint256 penalty = amount > usable ? usable : amount;
        if (penalty == 0) return;
        m.free -= penalty;
        m.frozen += penalty;
        totalFreeStake -= penalty;
        totalFrozenStake += penalty;
        if (until > m.frozenUntil) m.frozenUntil = until;
        _syncTree(moderator, m);
        emit NoShowPenalized(moderator, penalty, m.frozenUntil);
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

    function dutyOf(address a) external view returns (uint256 units, uint256 reserved) {
        Moderator storage m = moderators[a];
        return (m.dutyUnits, m.dutyReserved);
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

    /// Draw-eligible weight (H-07): free, unreserved stake CAPPED by remaining
    /// pledged duty capacity, and zero while frozen.
    function _eligibleWeight(Moderator storage m) internal view returns (uint256) {
        if (block.timestamp < m.frozenUntil) return 0; // fully excluded while frozen
        uint256 reserved = m.pending + m.exitAmount;
        if (m.free <= reserved) return 0;
        if (m.dutyUnits <= m.dutyReserved) return 0; // capacity fully in use
        uint256 usable = m.free - reserved;
        uint256 capacity = (m.dutyUnits - m.dutyReserved) * riskPerSeat;
        return usable < capacity ? usable : capacity;
    }

    function _syncTree(address moderator, Moderator storage m) internal {
        stakeTree.set(moderator, _eligibleWeight(m));
    }
}
