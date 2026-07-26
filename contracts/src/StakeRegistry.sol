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
        // M2.6-P0-2: collateral ESCROWED against outstanding draw assignments,
        // `riskPerSeat` per reserved seat. Before this bucket existed, `drawPanel`
        // incremented `dutyReserved` but moved no tokens: the seat's backing stayed
        // in `free`, and therefore stayed user-controlled. A selected moderator
        // escaped the no-show penalty entirely by calling `setDutyUnits(0)` or
        // `requestExit(free)` — the exit did not even have to complete, since
        // `penalizeNoShow` subtracted `exitAmount` from what it could reach. The
        // penalty is the stated defence against appeal-panel obstruction (H-10)
        // and it cost nothing.
        //
        // Bonded stake is not free, not exitable, not reducible by
        // `setDutyUnits`, and not available to another case. It leaves only by
        // being committed (a vote), frozen (a no-show penalty), or released (the
        // case ended).
        uint256 dutyBonded;
        bool exists;
    }

    IERC20 public immutable token;

    mapping(address => Moderator) internal moderators;
    SortitionTree.Tree internal stakeTree;

    uint256 public totalFreeStake;
    uint256 public totalCommittedStake;
    uint256 public totalFrozenStake;
    /// M2.6-P0-2: escrowed against outstanding draw assignments. A fourth bucket,
    /// so conservation still accounts for every token exactly once.
    uint256 public totalDutyBondedStake;

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

    // --- eligibility epochs (M2.6-P0-3) --------------------------------------
    //
    // H-05 was defended by `eligibilityAddVersion`, a counter the logic contract
    // compared before drawing and re-armed on. It failed in both directions:
    // `setDutyUnits(sameValue)` bumped it with no change, so any pledged
    // moderator could re-arm EVERY pending case forever for gas; while `release`,
    // `reward` and `releaseDuty` added draw-eligible weight and never bumped it
    // at all, leaving the grind it existed to stop wide open. Weight REMOVALS
    // (`setDutyUnits(0)`, `requestExit`, freezing) never bumped either, and those
    // remap the whole weighted tree — grinding over tree states, not
    // self-exclusion.
    //
    // Replaced by something structural. Draw-eligible weight now changes only at
    // EPOCH BOUNDARIES, on a fixed block cadence nobody can influence: a change
    // made during epoch `e` is staged and takes effect in `e + 1`. Within an
    // epoch the eligible set is constant, so a draw armed and realized inside one
    // epoch cannot be reshaped after its entropy becomes public — by anyone, in
    // either direction. There is no change to detect and nothing to re-arm on,
    // which is why the counter is gone rather than fixed.
    uint256 public immutable epochBlocks;
    /// Epochs up to and including this one have had their staged changes applied.
    uint256 public appliedEpoch;
    /// Moderators whose weight changed during epoch `e`, applied at the start of
    /// `e + 1`. Keyed by epoch so changes staged mid-drain are not swept early.
    mapping(uint256 => address[]) internal stagedByEpoch;
    mapping(uint256 => mapping(address => bool)) internal isStaged;
    uint256 internal drainCursor;
    /// The weight each moderator's leaf carries for the CURRENT epoch. Written
    /// only at drain time, and used to restore leaves a draw excluded transiently.
    mapping(address => uint256) internal epochWeight;

    // --- obligation handles (M2.6-P0-5) --------------------------------------
    //
    // `lock`, `release`, `freeze` and `settleDuty` carried no obligation identity
    // — only per-moderator aggregates. Two distinct failures followed.
    //
    // ACROSS LOGICS: during a handover both are authorized, so logic B could
    // release stake logic A had committed, freeze A's committed stake under B's
    // case, or discharge A's duty reservations. A's later honest settlement then
    // underflowed and reverted, stranding the case. Malice was never needed; an
    // ordinary bug in either contract did it.
    //
    // ACROSS CASES, within ONE logic: `dutyBonded` was a single pool per
    // moderator, so a case settling one seat could hand back escrow belonging to
    // a different case's outstanding seat, silently un-bonding it — that case's
    // no-show penalty then became a no-op. Nothing was minted, so conservation
    // still held and the leak was invisible. It was written once in P0-2 and
    // caught by reading, not by a test.
    //
    // Keying every obligation by (authorization epoch, logic, moderator, case)
    // makes both unrepresentable rather than merely absent from today's call
    // sites. The per-moderator aggregates remain as the ACCOUNTING layer —
    // conservation and draw weight are computed from them — while these handles
    // are the AUTHORIZATION layer.
    /// Packed into ONE storage slot deliberately. `drawPanel` touches an
    /// obligation for every seated moderator, so the difference between one cold
    /// SSTORE and three is ~40,000 gas per seat on the most expensive transaction
    /// in the protocol — it moves `MAX_PANEL` directly.
    ///
    /// Ranges: xBZZ has 16 decimals and a supply around 6.25e23 base units, so
    /// `uint112` (~5.2e33) cannot be reached by any real amount; seats per case
    /// are bounded by `MAX_PANEL`, far inside `uint32`.
    struct Obligation {
        uint112 committed; // stake locked against this specific case
        uint112 dutyBonded; // escrow posted for its seats
        uint32 dutyUnits; // seats outstanding for it
    }

    mapping(bytes32 => Obligation) internal obligations;
    /// Bumped each time a logic is authorized, so a contract re-authorized after
    /// revocation cannot inherit handles from its previous life.
    mapping(address => uint256) public authEpoch;
    /// Per-logic totals: a real on-chain drain signal. `openPotsTotal` in the game
    /// contract is not one — it is decremented at settlement INIT.
    mapping(address => uint256) public logicCommitted;
    mapping(address => uint256) public logicDutyReserved;
    /// Staged changes applied automatically per draw before a keeper is needed.
    uint256 internal constant DRAIN_BUDGET = 64;

    // --- authorization -------------------------------------------------------

    address public governance;
    uint256 public immutable timelockDelay;

    /// Authorized logic contracts. More than one may be authorized at a time so a
    /// migration can hand over while the outgoing logic settles its open cases.

    /// M2.6-P0-5: a logic contract's authorization has three states, not two.
    ///
    /// With only on/off, revoking a live logic STRANDED its cases — its pot, its
    /// committed stake, its duty reservations and its unpaid appeal contributors
    /// all sat in a contract that could no longer touch the registries, and the
    /// replacement could not settle them because the case storage lives in the old
    /// contract. Governance's only alternative was to leave the old logic fully
    /// authorized, which let anyone keep opening NEW cases in it, so it never
    /// provably drained. `SETTLE_ONLY` is the missing middle: finish what you
    /// started, start nothing new.
    enum LogicState {
        NONE,
        OPEN_AND_SETTLE,
        SETTLE_ONLY
    }

    mapping(address => LogicState) public logicState;

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
    event LogicRetiring(address indexed logic);
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
    error DutyReserved(); // M2.6-P0-2: cannot un-pledge capacity a live panel holds
    error EpochNotSettled(); // M2.6-P0-3: call advanceEpoch() to apply staged changes
    error NotYourObligation(); // M2.6-P0-5: only the creating case may discharge it
    error LogicStillHasObligations(); // M2.6-P0-5: cannot revoke a logic mid-flight

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLogic() {
        if (logicState[msg.sender] == LogicState.NONE) revert NotLogic();
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _timelockDelay,
        uint256 _minStake,
        uint256 _activationDelay,
        uint256 _exitCooldown,
        uint256 _riskPerSeat,
        uint256 _epochBlocks
    ) {
        if (_epochBlocks == 0) revert AmountZero();
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_riskPerSeat == 0) revert AmountZero();
        token = _token;
        timelockDelay = _timelockDelay;
        minStake = _minStake;
        activationDelay = _activationDelay;
        exitCooldown = _exitCooldown;
        epochBlocks = _epochBlocks;
        appliedEpoch = block.number / _epochBlocks;
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
        // M2.6-P0-2 (bypass 1): capacity already held by live panels cannot be
        // un-pledged. `setDutyUnits(0)` after selection used to make
        // `penalizeNoShow` return immediately on its `dutyUnits == 0` guard, so a
        // drawn moderator walked away from an assignment for free.
        if (units < m.dutyReserved) revert DutyReserved();
        if (units > 0) {
            uint256 reserved = m.pending + m.exitAmount;
            uint256 usable = m.free > reserved ? m.free - reserved : 0;
            if (usable < units * riskPerSeat) revert InsufficientEligibleFree();
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
        emit Thawed(moderator, amount);
    }

    // =========================================================================
    // Logic-facing: the narrow privileged API
    // =========================================================================

    /// @notice The obligation key for `moderator` under the CALLING logic's case.
    /// @param caseRef The caller's own case identity. `Moderation` packs
    ///        `(caseId << 8) | depth`; the registry treats it opaquely and only
    ///        needs it to be unique per case-round within one logic.
    /// @dev Includes `authEpoch[msg.sender]`, so a logic re-authorized after
    ///      revocation starts a fresh namespace and cannot reach obligations from
    ///      its previous life.
    function obligationKey(address logic, address moderator, uint256 caseRef) public view returns (bytes32) {
        return keccak256(abi.encode(authEpoch[logic], logic, moderator, caseRef));
    }

    function _ob(address moderator, uint256 caseRef) internal view returns (Obligation storage) {
        return obligations[keccak256(abi.encode(authEpoch[msg.sender], msg.sender, moderator, caseRef))];
    }

    /// Read an obligation (permissionless).
    function obligationOf(address logic, address moderator, uint256 caseRef)
        external
        view
        returns (uint256 committed, uint256 dutyUnits, uint256 dutyBonded)
    {
        Obligation storage o = obligations[obligationKey(logic, moderator, caseRef)];
        return (o.committed, o.dutyUnits, o.dutyBonded);
    }

    /// Move `amount` -> committed (backing a vote in an open case).
    /// @dev M2.6-P0-2: drawn from `dutyBonded` first — that escrow exists for
    ///      exactly this, and a case locking `riskPerSeat` per seat can never need
    ///      more than was bonded for those seats (`Moderation._validateParams`
    ///      rejects a ruleset whose `riskPerSeat` exceeds this registry's unit).
    ///      Any remainder comes from free stake, which keeps the injector paths and
    ///      any future non-duty lock working.
    function lock(address moderator, uint256 caseRef, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        Obligation storage o = _ob(moderator, caseRef);
        // M2.6-P0-5: spend THIS case's escrow. Drawing from the moderator's pooled
        // `dutyBonded` would let one case's commit consume collateral posted for
        // another case's outstanding seat.
        uint256 fromBond = amount > o.dutyBonded ? o.dutyBonded : amount;
        uint256 fromFree = amount - fromBond;
        if (fromFree > 0) {
            uint256 reserved = m.pending + m.exitAmount;
            uint256 eligible = m.free > reserved ? m.free - reserved : 0;
            if (eligible < fromFree) revert InsufficientEligibleFree();
            m.free -= fromFree;
            totalFreeStake -= fromFree;
        }
        if (fromBond > 0) {
            o.dutyBonded -= uint112(fromBond);
            m.dutyBonded -= fromBond;
            totalDutyBondedStake -= fromBond;
        }
        o.committed += uint112(amount);
        logicCommitted[msg.sender] += amount;
        m.committed += amount;
        totalCommittedStake += amount;
        _syncTree(moderator, m);
        emit StakeLocked(moderator, amount);
    }

    /// Move `amount` committed -> free (case settled coherently).
    function release(address moderator, uint256 caseRef, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        _debit(_ob(moderator, caseRef), amount);
        m.committed -= amount;
        m.free += amount;
        totalCommittedStake -= amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit StakeReleased(moderator, amount);
    }

    /// Move `amount` committed -> frozen until `until` (penalty; never a transfer).
    function freeze(address moderator, uint256 caseRef, uint256 amount, uint256 until) external onlyLogic {
        Moderator storage m = moderators[moderator];
        _debit(_ob(moderator, caseRef), amount);
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
    function drawPanel(uint256 count, bytes32 seed, uint256 offset, uint256 caseRef)
        external
        onlyLogic
        returns (address[] memory seats, uint256 attempts)
    {
        // The eligible set for this epoch must be complete before we sample it.
        // Bounded work; a keeper finishes an oversized epoch via `advanceEpoch`.
        _drainEpochs(DRAIN_BUDGET);
        if (!epochSettled()) revert EpochNotSettled();

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
            // M2.6-P0-2 (bypass 4): a seat is only issued if its collateral can be
            // ESCROWED right now. Reserving capacity while the backing stayed in
            // `free` let the same stake back several outstanding assignments, be
            // locked by whichever case committed first, or be exit-reserved.
            uint256 reserved = m.pending + m.exitAmount;
            uint256 usable = m.free > reserved ? m.free - reserved : 0;
            // M2.6-P0-3: the tree is the epoch's sampling distribution, but the
            // STRUCT is the authority for what may actually be seated. A freeze
            // (or any other exclusion) applied mid-epoch is live here even though
            // the leaf still carries last boundary's weight, so a penalised
            // moderator cannot be seated for the remainder of the epoch.
            if (block.timestamp < m.frozenUntil || m.dutyUnits <= m.dutyReserved || usable < riskPerSeat) {
                if (nExcluded < count) {
                    excluded[nExcluded++] = seat;
                    stakeTree.set(seat, 0);
                }
                continue;
            }
            m.dutyReserved += 1;
            m.free -= riskPerSeat;
            m.dutyBonded += riskPerSeat;
            totalFreeStake -= riskPerSeat;
            totalDutyBondedStake += riskPerSeat;
            // M2.6-P0-5: the seat and its escrow belong to THIS case.
            Obligation storage ob = _ob(seat, caseRef);
            ob.dutyUnits += 1;
            ob.dutyBonded += uint112(riskPerSeat);
            logicDutyReserved[msg.sender] += 1;
            seats[drawn++] = seat;
            // M2.6-P0-3: the persistent weight shrink is STAGED for the next
            // epoch — the tree must not move inside an epoch. Within this draw
            // the moderator is held out by the exclusion list instead, which is
            // restored before returning, so the tree is unchanged on exit.
            _stageSeated(seat);
            if (m.dutyUnits <= m.dutyReserved || (m.free > m.pending + m.exitAmount ? m.free - m.pending - m.exitAmount : 0) < riskPerSeat)
            {
                if (nExcluded < count) {
                    excluded[nExcluded++] = seat;
                    stakeTree.set(seat, 0);
                }
            }
        }
        // Restore every temporarily-excluded leaf to the weight this epoch
        // started with, so the draw leaves the tree exactly as it found it.
        for (uint256 j; j < nExcluded; ++j) {
            stakeTree.set(excluded[j], epochWeight[excluded[j]]);
        }
        if (drawn < count) {
            // Shrink to what was actually seated.
            assembly {
                mstore(seats, drawn)
            }
        }
    }

    /// @dev Discharge committed stake from THIS case's obligation. Reverts rather
    ///      than reaching into another case's or another logic's — the failure this
    ///      replaces succeeded here and underflowed in the rightful owner's
    ///      settlement later, where the cause was no longer visible.
    function _debit(Obligation storage o, uint256 amount) internal {
        if (o.committed < amount) revert NotYourObligation();
        o.committed -= uint112(amount);
        logicCommitted[msg.sender] -= amount;
    }

    /// @notice True when `logic` holds no live obligation, so revoking it cannot
    ///         strand a case.
    /// @dev The on-chain drain signal revocation previously lacked. Governance had
    ///      to BELIEVE the outgoing logic had finished; `openPotsTotal` in the game
    ///      contract could not tell it, because that is decremented at settlement
    ///      INIT rather than completion.
    function canRevoke(address logic) public view returns (bool) {
        return logicCommitted[logic] == 0 && logicDutyReserved[logic] == 0;
    }

    /// @notice Settle `units` finished assignments in ONE step: freeze `penalty` of
    ///         the escrow those seats still hold as the no-show cost, and return
    ///         the remainder to free stake.
    /// @dev This exists because penalising and releasing must share a single
    ///      clamp against the same balance. Calling `penalizeNoShow` and then
    ///      `releaseDuty` reads `dutyBonded` twice, and `dutyBonded` is a pool
    ///      shared by every case a moderator is currently seated in — so a seat
    ///      whose bond had already been partly frozen would still release a full
    ///      `riskPerSeat`, draining escrow belonging to a DIFFERENT case's
    ///      outstanding seat and silently un-bonding it. Nothing is minted (the
    ///      conservation identity still holds), which is exactly why the leak is
    ///      invisible without this being one operation.
    ///
    ///      Bounding both parts by `seatBond` makes over-draw unrepresentable.
    ///      Per-obligation accounting (P0-5) replaces the pooling entirely.
    function settleDuty(address moderator, uint256 caseRef, uint256 units, uint256 penalty, uint256 until)
        external
        onlyLogic
    {
        Moderator storage m = moderators[moderator];
        Obligation storage o = _ob(moderator, caseRef);
        // M2.6-P0-5: bounded by what THIS case reserved and escrowed. Bounding by
        // the moderator's pooled totals is what let a settlement hand back escrow
        // belonging to another case's outstanding seat.
        uint256 rel = units > o.dutyUnits ? o.dutyUnits : units;
        o.dutyUnits -= uint32(rel);
        logicDutyReserved[msg.sender] -= rel;
        m.dutyReserved -= rel;

        uint256 seatBond = rel * riskPerSeat;
        if (seatBond > o.dutyBonded) seatBond = o.dutyBonded;
        if (seatBond == 0) {
            _syncTree(moderator, m);
            return;
        }
        o.dutyBonded -= uint112(seatBond);
        m.dutyBonded -= seatBond;
        totalDutyBondedStake -= seatBond;

        uint256 p = penalty > seatBond ? seatBond : penalty;
        if (p > 0) {
            m.frozen += p;
            totalFrozenStake += p;
            if (until > m.frozenUntil) m.frozenUntil = until;
            emit NoShowPenalized(moderator, p, m.frozenUntil);
        }
        uint256 back = seatBond - p;
        if (back > 0) {
            m.free += back;
            totalFreeStake += back;
        }
        _syncTree(moderator, m);
    }

    /// @notice Penalize a moderator that pledged capacity, was drawn on it, and
    ///         never committed: freeze `amount` of its own FREE stake until
    ///         `until`. Never a transfer — no internal attack profit exists.
    /// @dev M2.6-P0-2: taken from `dutyBonded` — the escrow posted when the seat
    ///      was drawn — not from `free`. The old version read free stake minus
    ///      `exitAmount`, so `requestExit(free)` after selection reduced the
    ///      reachable balance to zero and the penalty silently became a no-op
    ///      (bypass 2); the exit did not even have to complete. It also opened with
    ///      `if (m.dutyUnits == 0) return`, which `setDutyUnits(0)` satisfied
    ///      (bypass 1). Escrowed collateral is reachable by construction, so
    ///      neither guard is needed and neither bypass exists.
    function penalizeNoShow(address moderator, uint256 amount, uint256 until) external onlyLogic {
        Moderator storage m = moderators[moderator];
        uint256 penalty = amount > m.dutyBonded ? m.dutyBonded : amount;
        if (penalty == 0) return; // nothing bonded -> was never seated on this duty
        m.dutyBonded -= penalty;
        m.frozen += penalty;
        totalDutyBondedStake -= penalty;
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
        logicState[pl.logic] = LogicState.OPEN_AND_SETTLE;
        authEpoch[pl.logic] += 1; // M2.6-P0-5: fresh handle namespace
        delete pendingLogic;
        emit LogicAuthorized(pl.logic);
    }

    function cancelLogic() external onlyGovernance {
        delete pendingLogic;
    }

    /// Revoke a drained logic contract. Immediate: revocation only ever REDUCES
    /// privilege, so it needs no timelock.
    /// @notice Stop a logic opening new cases while it settles the ones it has.
    function retireLogic(address logic) external onlyGovernance {
        if (logicState[logic] != LogicState.OPEN_AND_SETTLE) revert NotLogic();
        logicState[logic] = LogicState.SETTLE_ONLY;
        emit LogicRetiring(logic);
    }

    /// @dev Refuses while the logic still holds obligations. Revocation used to
    ///      rely on governance BELIEVING the old logic had drained; `canRevoke` is
    ///      the on-chain fact. (`openPotsTotal` in the game contract is not one —
    ///      it is decremented at settlement init.)
    function revokeLogic(address logic) external onlyGovernance {
        if (!canRevoke(logic)) revert LogicStillHasObligations();
        logicState[logic] = LogicState.NONE;
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

    function dutyOf(address a) external view returns (uint256 units, uint256 reserved, uint256 bonded) {
        Moderator storage m = moderators[a];
        return (m.dutyUnits, m.dutyReserved, m.dutyBonded);
    }

    /// Escrow currently posted against outstanding draw assignments (M2.6-P0-2).
    /// Single-word: the logic contract reads this on the commit path and is the
    /// EIP-170-bound side of the boundary.
    function dutyBondedOf(address a) external view returns (uint256) {
        return moderators[a].dutyBonded;
    }

    function eligibleWeightOf(address a) external view returns (uint256) {
        return _eligibleWeight(moderators[a]);
    }

    function totalEligibleWeight() external view returns (uint256) {
        return stakeTree.total();
    }

    /// Conservation: every token held is somebody's stake, in exactly one bucket.
    function stakeBuckets() external view returns (uint256) {
        return totalFreeStake + totalCommittedStake + totalFrozenStake + totalDutyBondedStake;
    }

    // --- internals -----------------------------------------------------------

    function _total(Moderator storage m) internal view returns (uint256) {
        return m.free + m.committed + m.frozen + m.dutyBonded;
    }

    /// @notice The epoch containing `block.number`. A fixed cadence: no
    ///         participant, and no volume of activity, can move a boundary.
    function currentEpoch() public view returns (uint256) {
        return block.number / epochBlocks;
    }

    /// First block of the epoch AFTER the current one — where a seed that cannot
    /// fit inside this epoch is deferred to.
    function nextEpochStart() external view returns (uint256) {
        return (currentEpoch() + 1) * epochBlocks;
    }

    /// @notice True once every change staged in earlier epochs has been applied,
    ///         i.e. the eligible set for this epoch is complete and will not move
    ///         again until the next boundary.
    function epochSettled() public view returns (bool) {
        return appliedEpoch == currentEpoch();
    }

    /// @notice Apply staged weight changes for elapsed epochs. Permissionless and
    ///         batched; `drawPanel` runs it automatically within a bounded budget,
    ///         so this is only needed when a single epoch staged more changes than
    ///         that budget covers.
    /// @dev Timing is not a lever. The set applied here was fixed before this
    ///      epoch began, and applying it is all-or-nothing per epoch, so nobody
    ///      can choose to reveal a change after seeing a seed's entropy.
    function advanceEpoch(uint256 maxItems) external {
        _drainEpochs(maxItems);
    }

    function _drainEpochs(uint256 maxItems) internal {
        uint256 target = currentEpoch();
        uint256 applied = appliedEpoch;
        uint256 budget = maxItems;
        while (applied < target && budget > 0) {
            uint256 e = applied + 1; // the epoch whose stages become effective
            address[] storage list = stagedByEpoch[e - 1];
            uint256 n = list.length;
            uint256 i = drainCursor;
            while (i < n && budget > 0) {
                address a = list[i];
                delete isStaged[e - 1][a];
                uint256 w = _eligibleWeight(moderators[a]);
                epochWeight[a] = w;
                stakeTree.set(a, w);
                unchecked {
                    ++i;
                    --budget;
                }
            }
            if (i < n) {
                drainCursor = i;
                appliedEpoch = applied;
                return; // out of budget mid-epoch; a keeper finishes it
            }
            drainCursor = 0;
            applied = e;
        }
        appliedEpoch = applied;
    }

    /// @dev Record that `a`'s draw-eligible weight has changed. The moderator's
    ///      own accounting is already live; only the SORTITION TREE is deferred,
    ///      to the start of the next epoch. That deferral is the whole of P0-3:
    ///      within an epoch the eligible set cannot move, so a draw armed and
    ///      realized inside one epoch cannot be reshaped after its entropy is
    ///      public — in either direction, by anyone.
    function _stage(address a) internal {
        uint256 e = currentEpoch();
        if (isStaged[e][a]) return;
        isStaged[e][a] = true;
        stagedByEpoch[e].push(a);
    }

    /// @dev As `_stage`, without the dedupe flag. The drain recomputes weight from
    ///      live state, so a duplicate entry is idempotent — it only costs the
    ///      drain an extra recompute. Used on the DRAW path, where the flag's cold
    ///      SSTORE is paid once per seated moderator and the 47-seat panel is
    ///      already the most expensive transaction in the protocol. Callers that a
    ///      griefer could invoke repeatedly must use `_stage`, which bounds list
    ///      growth; a seat cannot be repeated for free.
    function _stageSeated(address a) internal {
        stagedByEpoch[currentEpoch()].push(a);
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

    /// @dev Was an immediate `stakeTree.set`. Since M2.6-P0-3 the tree is only
    ///      written at epoch boundaries (`_drainEpochs`) or transiently inside a
    ///      draw, so every other caller stages instead. The moderator struct is
    ///      still updated immediately by its caller — the struct is the authority
    ///      for what may be seated (P0-2's escrow check reads it), the tree is
    ///      only the sampling distribution.
    function _syncTree(address moderator, Moderator storage m) internal {
        m; // weight is recomputed at drain time from live state
        _stage(moderator);
    }
}
