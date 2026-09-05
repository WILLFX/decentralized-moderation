// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title StakeRegistry (v3)
/// @notice Custody of moderator stake and bond for the v3 moderation protocol.
///         Written against `specs/state-machine-v3.md` §2.1-§2.4, §5.4 and §6.
///
/// @dev This is a rewrite, not an edit of the v1 registry. v1's eligibility-epoch
///      subsystem (P0-3, P0-3c, P0-3d) existed to stop a sortition tree mutating
///      mid-draw. v3 eligibility is a passive hash test over no tree at all, so
///      that machinery is not simplifiable but meaningless, and it is gone rather
///      than carried forward with its justification evaporated. Likewise there is
///      no freeze, no suspension, no risk unit and no duty pool.
///
///      The contract owns these invariants (§9). Each has a test that fails if the
///      invariant is removed, in `test/v3/StakeRegistry.t.sol`:
///
///      I1   `bond` never goes negative, structurally and in two independent ways:
///           every removable value is a term in `liabilities()`, AND no debit
///           exceeds the claim it is drawn against. The second is the one that
///           survives a second logic contract.
///      I13  `withdraw` implies `liabilities(m) == 0`.
///      I14  No moderator's loss is another moderator's gain.
///      I16  The §2.2 state predicates are mutually exclusive.
///      I21  Every value moved has a named destination, never another moderator.
///      I23  `liabilities` equals the sum of that moderator's open claim records —
///           an identity, asserted by `liabilitiesMatch`, not a convention.
///      I32  Only the case that created a claim may discharge it, and only the
///           logic that created that case may act on it.
contract StakeRegistry {
    using SafeTransferLib for address;

    // --- claim kinds (§2.1) ---------------------------------------------------

    uint8 public constant KIND_VOTE = 1;
    uint8 public constant KIND_CHALLENGE = 2;

    // --- capabilities (§2.4) --------------------------------------------------

    /// @dev Discharge capability must outlive creation capability: a logic barred
    ///      from opening new claims must still settle the ones it holds, or
    ///      deauthorizing it strands every moderator who voted under it (I13, I20).
    ///      So the two are separate bits, and `MAY_DISCHARGE` is not revocable
    ///      while the logic holds an open claim.
    uint8 public constant MAY_CREATE = 1;
    uint8 public constant MAY_DISCHARGE = 2;

    // --- storage (§2.1) -------------------------------------------------------

    /// @dev `trackEpoch` from §2.1's struct is deliberately absent: §6 gives it no
    ///      job, and a field nothing writes is the same defect as the epoch
    ///      subsystem this rewrite deleted. See the port report — if it is meant to
    ///      be the hook for an order-independent decay, §6 has to say so first.
    struct Moderator {
        uint128 stake; // 0 or MIN_STAKE. Identity floor; never debited.
        uint128 bond; // working capital: penalties consume it, rewards replenish it
        uint32 openVoteCount; // committed votes whose case has not settled
        uint32 openChallenges; // registered challenges not yet resolved
        uint128 liabilities; // ACCRUED, never recomputed (§2.4). == Σ claims (I23)
        uint40 maturesAt;
        uint40 exitRequestedAt;
        uint128 track; // reputation, WAD-scaled (§6)
    }

    /// @notice One claim on a bond. A scalar cannot say who is owed, so a claim is
    ///         a record: 96 + 160 bits, exactly one storage slot.
    /// @dev `amount` is PINNED at creation (I27) — `LAMBDA(c)` or
    ///      `CHALLENGE_BOND(c)` as of the case's submission, never the live value.
    ///      This is what makes "what was added is what is removed" true by
    ///      construction, so no coefficient is read at settlement at all.
    struct Claim {
        uint96 amount;
        address logic;
    }

    uint256 internal constant WAD = 1e18;

    IERC20 public immutable token;
    uint256 public immutable minStake;
    uint256 public immutable bondMin;
    uint256 public immutable maturation;
    uint256 public immutable exitCooldown;
    uint256 public immutable timelockDelay;
    uint256 public immutable minTrackDecay;

    address public governance;
    address public pendingGovernance;

    mapping(address => Moderator) internal moderators;

    /// @dev keccak(moderator, caseId, kind) -> Claim
    mapping(bytes32 => Claim) internal claims;

    /// @notice Capability bitmap per logic contract: `MAY_CREATE | MAY_DISCHARGE`.
    mapping(address => uint8) public caps;

    /// @notice Open claims held by each logic. The registry keeps a COUNT, not an
    ///         enumeration — which is why the no-revoke rule below is a comparison
    ///         rather than a governance discipline, and why `liabilitiesMatch`
    ///         takes the enumeration from its caller.
    mapping(address => uint256) public openClaims;

    /// @notice A logic governance has ruled will not discharge (§2.4).
    ///         Once condemned, any of its claims may be discharged by anyone,
    ///         forever. Condemnation ADDS a discharge path and removes none: the
    ///         condemned logic keeps `MAY_DISCHARGE` and may still settle claims it
    ///         holds legitimately, so the no-revoke rule is never excepted.
    mapping(address => bool) public condemned;

    uint256 public totalStake;
    uint256 public totalBond;

    /// @notice The named destination for every debit (§5.1, I21). Value removed
    ///         from a bond lands here and never in another moderator's balance.
    /// @dev Nothing in §2 or §5 gives this an exit. That is a gap in the spec, not
    ///      a licence to invent a governance sweep into a custody contract; it is
    ///      reported rather than filled in.
    uint256 public maintenanceReserve;

    struct PendingCap {
        address logic;
        uint8 capBits;
        uint40 eta;
        bool exists;
    }

    struct PendingCondemn {
        address logic;
        uint40 eta;
        bool exists;
    }

    PendingCap internal pendingCap;
    PendingCondemn internal pendingCondemn;

    // --- events ---------------------------------------------------------------

    event Staked(address indexed m, uint256 stakeAmount, uint256 bondAmount);
    event BondPosted(address indexed m, uint256 amount);
    event ExitRequested(address indexed m, uint256 at);
    event Withdrawn(address indexed m, uint256 amount);

    /// @dev The claim log is what lets a moderator reconstruct their own open
    ///      claims off-chain — which the condemnation recovery path depends on,
    ///      since the registry cannot enumerate them.
    event ClaimCreated(address indexed m, uint256 indexed caseId, uint8 kind, uint256 amount, address indexed logic);
    event ClaimDischarged(address indexed m, uint256 indexed caseId, uint8 kind, uint256 amount, address indexed logic);
    event Debited(address indexed m, uint256 indexed caseId, uint8 kind, uint256 amount);
    event Rewarded(address indexed m, uint256 amount);
    event TrackRecorded(address indexed m, uint256 newTrack);

    event CapProposed(address indexed logic, uint8 capBits, uint256 eta);
    event CapSet(address indexed logic, uint8 capBits);
    event CapProposalCancelled(address indexed logic);
    event CondemnProposed(address indexed logic, uint256 eta);
    event Condemned(address indexed logic);
    event CondemnProposalCancelled(address indexed logic);
    event GovernanceProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    // --- errors ---------------------------------------------------------------

    error NotGovernance();
    error NotCapable();
    error NotClaimOwner();
    error NotCondemned();
    error ExceedsClaim();
    error NoSuchClaim();
    error ClaimExists();
    error ZeroAddress();
    error AmountZero();
    error NotStaked();
    error AlreadyStaked();
    error Insolvent();
    error Exiting();
    error NotExiting();
    error CooldownActive();
    error OutstandingLiabilities();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error LogicHoldsClaims();
    error BondUnderflow();
    error BadTrackDecay();
    error BadEnumeration();
    error BadKind();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _minStake,
        uint256 _bondMin,
        uint256 _maturation,
        uint256 _exitCooldown,
        uint256 _timelockDelay,
        uint256 _minTrackDecay
    ) {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_minStake == 0 || _bondMin == 0) revert AmountZero();
        if (_minTrackDecay == 0 || _minTrackDecay >= WAD) revert BadTrackDecay();
        token = _token;
        minStake = _minStake;
        bondMin = _bondMin;
        maturation = _maturation;
        exitCooldown = _exitCooldown;
        timelockDelay = _timelockDelay;
        minTrackDecay = _minTrackDecay;
        governance = msg.sender;
    }

    // =========================================================================
    // §2.2 States — four, mutually exclusive by construction (I16)
    // =========================================================================

    enum State {
        NONE,
        PENDING,
        ACTIVE,
        EXITING
    }

    /// @notice The §2.2 predicate set, evaluated as one function so the four
    ///         states cannot drift apart.
    /// @dev Two conjuncts here are not in §2.2's table as written, and both are
    ///      needed for I16 to hold:
    ///
    ///      - `PENDING` carries `exitRequestedAt == 0`, exactly as `ACTIVE` does.
    ///        Without it a PENDING moderator who calls `requestExit` — a transition
    ///        §2.3 explicitly permits, and must permit, or stake is locked for
    ///        MATURATION with no way out — satisfies PENDING and EXITING at once.
    ///      - `EXITING` carries `stake != 0`. §2.3 gets this from `withdraw`
    ///        clearing `exitRequestedAt`; stating it in the predicate makes I16
    ///        structural rather than dependent on that one writer's discipline.
    ///        `withdraw` clears the flag anyway, for §2.3's other reason: a
    ///        re-staking identity must not land straight back in EXITING.
    function stateOf(address a) public view returns (State) {
        Moderator storage m = moderators[a];
        if (m.stake == 0) return State.NONE;
        if (m.exitRequestedAt != 0) return State.EXITING;
        if (block.timestamp < m.maturesAt) return State.PENDING;
        return State.ACTIVE;
    }

    function isActive(address a) public view returns (bool) {
        return stateOf(a) == State.ACTIVE;
    }

    // =========================================================================
    // §2.3 Transitions
    // =========================================================================

    /// @notice NONE -> PENDING. Posts `MIN_STAKE` and an opening bond of at least
    ///         `BOND_MIN` in one transaction, which is what §2.3's row specifies.
    function stake(uint256 bondAmount) external {
        Moderator storage m = moderators[msg.sender];
        if (m.stake != 0) revert AlreadyStaked();
        if (bondAmount < bondMin) revert Insolvent();
        uint256 total = minStake + bondAmount;
        address(token).safeTransferFrom(msg.sender, address(this), total);
        m.stake = uint128(minStake);
        m.bond = uint128(bondAmount);
        m.maturesAt = uint40(block.timestamp + maturation);
        totalStake += minStake;
        totalBond += bondAmount;
        emit Staked(msg.sender, minStake, bondAmount);
    }

    /// @notice ACTIVE -> ACTIVE. Permitted at any time, including to restore
    ///         solvency after debits. There is no ceiling: a moderator who posts
    ///         more bond may cover more open votes.
    function postBond(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        if (m.stake == 0) revert NotStaked();
        address(token).safeTransferFrom(msg.sender, address(this), amount);
        m.bond += uint128(amount);
        totalBond += amount;
        emit BondPosted(msg.sender, amount);
    }

    /// @notice PENDING -> EXITING and ACTIVE -> EXITING.
    function requestExit() external {
        Moderator storage m = moderators[msg.sender];
        if (m.stake == 0) revert NotStaked();
        if (m.exitRequestedAt != 0) revert Exiting();
        m.exitRequestedAt = uint40(block.timestamp);
        emit ExitRequested(msg.sender, block.timestamp);
    }

    /// @notice EXITING -> NONE. Returns `stake + bond`, less nothing.
    /// @dev I13: the gate is `liabilities == 0`, not `openVoteCount == 0`. A
    ///      registered challenge is a claim on `bond` that no vote counter sees —
    ///      the omission that broke I1 once already (§2.4). The cooldown alone let
    ///      a voter commit, request exit and withdraw before the case that would
    ///      debit them ever settled (P0-5); the liability count is exact where a
    ///      duration guess is not.
    function withdraw() external {
        Moderator storage m = moderators[msg.sender];
        if (m.exitRequestedAt == 0) revert NotExiting();
        if (block.timestamp < uint256(m.exitRequestedAt) + exitCooldown) revert CooldownActive();
        if (m.liabilities != 0) revert OutstandingLiabilities();

        uint256 amount = uint256(m.stake) + uint256(m.bond);
        totalStake -= m.stake;
        totalBond -= m.bond;
        m.stake = 0;
        m.bond = 0;
        m.exitRequestedAt = 0; // §2.3 — or NONE and EXITING both hold (I16)
        // `track` is retained. That is what makes identity replacement expensive
        // rather than the stake (§6).
        address(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // =========================================================================
    // §2.4 Solvency: one liability function, used in three places
    // =========================================================================

    function _key(address m, uint256 caseId, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(m, caseId, kind));
    }

    /// @notice §2.4's commit predicate. `_create` calls this rather than restating
    ///         it, so the gate and the predicate are the same code and a test on
    ///         one discriminates the other.
    function mayCommit(address a, uint256 lambda) public view returns (bool) {
        Moderator storage m = moderators[a];
        return isActive(a) && uint256(m.bond) >= bondMin + uint256(m.liabilities) + lambda;
    }

    /// @notice §2.4's challenge predicate. `CHALLENGE_BOND` needs no relation to
    ///         `BOND_MIN`: requiring it to be COVERED scales with whatever the
    ///         parameter turns out to be.
    function mayChallenge(address a, uint256 challengeBond) public view returns (bool) {
        Moderator storage m = moderators[a];
        return isActive(a) && uint256(m.bond) >= bondMin + uint256(m.liabilities) + challengeBond;
    }

    function _create(address a, uint256 caseId, uint8 kind, uint256 amount) internal {
        if (caps[msg.sender] & MAY_CREATE == 0) revert NotCapable();
        if (amount == 0) revert AmountZero();
        if (amount > type(uint96).max) revert AmountZero();

        // I1, first clause: the solvency test is taken AFTER the addition, so
        // `bond >= BOND_MIN + liabilities` holds at every point at which a claim
        // exists. `liabilities` is the single accumulator — writing the test
        // against `openVoteCount` alone is what let CHALLENGE_BOND through.
        if (kind == KIND_VOTE) {
            if (!mayCommit(a, amount)) revert Insolvent();
        } else if (kind == KIND_CHALLENGE) {
            if (!mayChallenge(a, amount)) revert Insolvent();
        } else {
            revert BadKind();
        }

        bytes32 k = _key(a, caseId, kind);
        if (claims[k].logic != address(0)) revert ClaimExists();

        Moderator storage m = moderators[a];
        m.liabilities = uint128(uint256(m.liabilities) + amount);
        claims[k] = Claim({amount: uint96(amount), logic: msg.sender});
        openClaims[msg.sender] += 1;
        if (kind == KIND_VOTE) m.openVoteCount += 1;
        else m.openChallenges += 1;

        emit ClaimCreated(a, caseId, kind, amount, msg.sender);
    }

    /// @notice Open a vote claim of `LAMBDA(c)` against `a`'s bond.
    function createVoteClaim(address a, uint256 caseId, uint256 lambda) external {
        _create(a, caseId, KIND_VOTE, lambda);
    }

    /// @notice Open a challenge claim of `CHALLENGE_BOND(c)` against `a`'s bond.
    function createChallengeClaim(address a, uint256 caseId, uint256 challengeBond) external {
        _create(a, caseId, KIND_CHALLENGE, challengeBond);
    }

    /// @notice Draw against a claim you hold. Value goes to the maintenance
    ///         reserve (§5.1) — a named destination that is not another moderator
    ///         (I21, I14).
    /// @dev I1, second clause, and the one that survives a second logic contract:
    ///      the bound is `amount <= claims[m,c,k].amount`, enforced at the call
    ///      site rather than argued from `liabilities()` being complete. A caller
    ///      with no claim on a moderator can debit them nothing at all, whatever
    ///      their bond says.
    ///
    ///      §5.4: the underflow check REVERTS, it does not clamp. A `bond -= d(c)`
    ///      that would underflow means I1 has already failed, and clamping would
    ///      hide it.
    function debit(address a, uint256 caseId, uint8 kind, uint256 amount) external {
        bytes32 k = _key(a, caseId, kind);
        Claim storage cl = claims[k];
        if (cl.logic == address(0)) revert NoSuchClaim();
        if (cl.logic != msg.sender) revert NotClaimOwner();
        if (amount > cl.amount) revert ExceedsClaim();

        Moderator storage m = moderators[a];
        if (uint256(m.bond) < amount) revert BondUnderflow();
        m.bond -= uint128(amount);
        totalBond -= amount;
        maintenanceReserve += amount;

        emit Debited(a, caseId, kind, amount);
    }

    /// @notice Release a claim you hold. The amount is looked up, never supplied.
    /// @dev I32. The release amount cannot be wrong because no caller states it:
    ///      an earlier revision wrote this as "subtract the amount that case
    ///      added", with `liabilities` a bare scalar and the caller's word for the
    ///      figure. Every guarantee then held of the arithmetic and none of the
    ///      authorization — which is how v1's P0-2 drained escrow across cases
    ///      inside a single contract, and how a second logic empties a moderator's
    ///      liabilities out from under the first.
    function discharge(address a, uint256 caseId, uint8 kind) external {
        if (caps[msg.sender] & MAY_DISCHARGE == 0) revert NotCapable();
        bytes32 k = _key(a, caseId, kind);
        Claim storage cl = claims[k];
        if (cl.logic == address(0)) revert NoSuchClaim();
        if (cl.logic != msg.sender) revert NotClaimOwner();
        _release(a, caseId, kind, k, cl);
    }

    /// @notice Release a claim held by a CONDEMNED logic. Permissionless, one
    ///         claim, idempotent, callable by the affected moderator themselves.
    /// @dev §2.4: "Once a logic is condemned, any of its claims may be discharged
    ///      by anyone, forever." Partial application is not a state — there is no
    ///      list to lose and no ordering to get wrong, which is the whole reason
    ///      this replaced the force-discharge that walked a caller-supplied list.
    ///
    ///      This pardons the pending debit, and that is a decision rather than an
    ///      oversight: a claim record holds `amount` and `logic`, not the case's
    ///      outcome, which lives in the contract that is broken. Charging the
    ///      maximum instead would debit moderators who were about to be paid.
    function dischargeCondemned(address a, uint256 caseId, uint8 kind) external {
        bytes32 k = _key(a, caseId, kind);
        Claim storage cl = claims[k];
        if (cl.logic == address(0)) revert NoSuchClaim();
        if (!condemned[cl.logic]) revert NotCondemned();
        _release(a, caseId, kind, k, cl);
    }

    function _release(address a, uint256 caseId, uint8 kind, bytes32 k, Claim storage cl) internal {
        uint256 amount = cl.amount;
        address logic = cl.logic;

        Moderator storage m = moderators[a];
        m.liabilities -= uint128(amount);
        if (kind == KIND_VOTE) m.openVoteCount -= 1;
        else m.openChallenges -= 1;
        openClaims[logic] -= 1;
        delete claims[k];

        emit ClaimDischarged(a, caseId, kind, amount, logic);
    }

    /// @notice Pay a moderator. The value is transferred in by the caller in the
    ///         same call, so nothing here moves value between moderators (I14).
    function reward(address a, uint256 amount) external {
        if (caps[msg.sender] == 0) revert NotCapable();
        if (amount == 0) revert AmountZero();
        uint256 before = token.balanceOf(address(this));
        address(token).safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before < amount) revert AmountZero();
        Moderator storage m = moderators[a];
        m.bond += uint128(amount);
        totalBond += amount;
        emit Rewarded(a, amount);
    }

    /// @notice §6 track update: a decayed, saturating count of coherent
    ///         participations, retained through withdrawal.
    /// @dev `decayFactor` is the CASE's pinned value (I27), floored at
    ///      `minTrackDecay` so a replacement logic cannot zero a moderator's
    ///      standing by supplying a decay of 0.
    ///
    ///      NOT order-independent, and §6 requires that it be. With per-case decay
    ///      factors `a != b`, settling A then B gives `t·a·b + b + 1` and B then A
    ///      gives `t·a·b + a + 1`. §5.5 makes settlement order permissionless and
    ///      unordered, so the difference is reachable. Reported, not silently
    ///      papered over; the fix needs a decision in §6, not a reading here.
    function recordParticipation(address a, uint256 caseId, uint256 coherentUnits, uint256 decayFactor) external {
        if (caps[msg.sender] == 0) revert NotCapable();
        if (decayFactor < minTrackDecay || decayFactor >= WAD) revert BadTrackDecay();
        Moderator storage m = moderators[a];
        uint256 next = (uint256(m.track) * decayFactor) / WAD + coherentUnits * WAD;
        if (next > type(uint128).max) next = type(uint128).max;
        m.track = uint128(next);
        caseId; // logged by the caller; the registry pins nothing per case here
        emit TrackRecorded(a, next);
    }

    // =========================================================================
    // Capability lifecycle (§2.4)
    // =========================================================================

    function proposeCaps(address logic, uint8 capBits) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + timelockDelay;
        pendingCap = PendingCap({logic: logic, capBits: capBits, eta: uint40(eta), exists: true});
        emit CapProposed(logic, capBits, eta);
    }

    function cancelCaps() external onlyGovernance {
        if (!pendingCap.exists) revert NoPendingProposal();
        address logic = pendingCap.logic;
        delete pendingCap;
        emit CapProposalCancelled(logic);
    }

    /// @dev The no-revoke rule: `MAY_DISCHARGE` cannot be taken from a logic that
    ///      holds an open claim, or retiring a contract strands every moderator who
    ///      voted under it. The registry knows the count, so this is a comparison
    ///      rather than a governance discipline. Nothing in this contract excepts
    ///      it — condemnation adds a discharge path and removes none.
    function executeCaps() external onlyGovernance {
        PendingCap memory p = pendingCap;
        if (!p.exists) revert NoPendingProposal();
        if (block.timestamp < p.eta) revert TimelockNotElapsed();
        if (caps[p.logic] & MAY_DISCHARGE != 0 && p.capBits & MAY_DISCHARGE == 0) {
            if (openClaims[p.logic] != 0) revert LogicHoldsClaims();
        }
        caps[p.logic] = p.capBits;
        delete pendingCap;
        emit CapSet(p.logic, p.capBits);
    }

    // =========================================================================
    // Condemnation (§2.4) — the recovery for a logic that WILL NOT discharge
    // =========================================================================

    function proposeCondemn(address logic) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + timelockDelay;
        pendingCondemn = PendingCondemn({logic: logic, eta: uint40(eta), exists: true});
        emit CondemnProposed(logic, eta);
    }

    function cancelCondemn() external onlyGovernance {
        if (!pendingCondemn.exists) revert NoPendingProposal();
        address logic = pendingCondemn.logic;
        delete pendingCondemn;
        emit CondemnProposalCancelled(logic);
    }

    /// @dev `logic` is named again at execution so a pending proposal cannot be
    ///      swapped underneath the timelock.
    function executeCondemn(address logic) external onlyGovernance {
        PendingCondemn memory p = pendingCondemn;
        if (!p.exists || p.logic != logic) revert NoPendingProposal();
        if (block.timestamp < p.eta) revert TimelockNotElapsed();
        condemned[logic] = true;
        delete pendingCondemn;
        emit Condemned(logic);
    }

    // =========================================================================
    // Governance (two-step)
    // =========================================================================

    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernance = next;
        emit GovernanceProposed(next);
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
            uint256 stakeAmount,
            uint256 bond,
            uint256 openVoteCount,
            uint256 openChallenges,
            uint256 liabilities,
            uint256 maturesAt,
            uint256 exitRequestedAt,
            uint256 track
        )
    {
        Moderator storage m = moderators[a];
        return (
            m.stake,
            m.bond,
            m.openVoteCount,
            m.openChallenges,
            m.liabilities,
            m.maturesAt,
            m.exitRequestedAt,
            m.track
        );
    }

    function claimOf(address a, uint256 caseId, uint8 kind) external view returns (uint256 amount, address logic) {
        Claim storage cl = claims[_key(a, caseId, kind)];
        return (cl.amount, cl.logic);
    }

    function liabilitiesOf(address a) external view returns (uint256) {
        return moderators[a].liabilities;
    }

    function trackOf(address a) external view returns (uint256) {
        return moderators[a].track;
    }

    function bondOf(address a) external view returns (uint256) {
        return moderators[a].bond;
    }

    function openClaimsOf(address a) public view returns (uint256) {
        Moderator storage m = moderators[a];
        return uint256(m.openVoteCount) + uint256(m.openChallenges);
    }

    /// @notice I23 as an assertion: `liabilities` equals the sum of this
    ///         moderator's open claim records.
    /// @dev The registry deliberately keeps a count and not an enumeration, so the
    ///      caller supplies the list. This does not take the list on trust — it
    ///      checks the enumeration is COMPLETE (`length == openVoteCount +
    ///      openChallenges`), that every entry names a live claim, and that no
    ///      entry is repeated. Without the duplicate check a caller could pass one
    ///      claim twice and omit another of equal amount, and a false `true` from
    ///      an invariant assertion is worse than no assertion at all.
    ///
    ///      The duplicate check is O(n²) in the moderator's own open-claim count,
    ///      which their bond bounds. This is an `eth_call` and test helper; no
    ///      protocol path calls it.
    function liabilitiesMatch(address a, uint256[] calldata caseIds, uint8[] calldata kinds)
        external
        view
        returns (bool ok, uint256 sum)
    {
        uint256 n = caseIds.length;
        if (n != kinds.length) revert BadEnumeration();
        if (n != openClaimsOf(a)) revert BadEnumeration();

        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (caseIds[i] == caseIds[j] && kinds[i] == kinds[j]) revert BadEnumeration();
            }
            Claim storage cl = claims[_key(a, caseIds[i], kinds[i])];
            if (cl.logic == address(0)) revert BadEnumeration();
            sum += cl.amount;
        }
        ok = (sum == moderators[a].liabilities);
    }

    /// @notice Every unit of token this contract holds is in exactly one named
    ///         bucket (I21). Ledger totals never exceed the real balance.
    function balanceBuckets() public view returns (uint256) {
        return totalStake + totalBond + maintenanceReserve;
    }

    function solvent() external view returns (bool) {
        return token.balanceOf(address(this)) >= balanceBuckets();
    }
}
