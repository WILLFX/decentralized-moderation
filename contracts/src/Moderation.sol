// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SortitionTree} from "./lib/SortitionTree.sol";
import {FreezeMath} from "./lib/FreezeMath.sol";

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

    /// WAD scale for fractional parameters (1e18 = 100%).
    uint256 internal constant WAD = 1e18;
    // H-06: randomness domain-separation purpose tags.
    uint8 internal constant SEED_SEATS = 1;
    uint8 internal constant SEED_OUTCOME = 2;
    // H-11: immutable protocol caps. Governance can tune numbers only WITHIN these
    // bounds, so it can never configure an unsettleable case or overflowing freeze.
    uint256 internal constant MAX_RULE_DEPTH = 8;
    uint256 internal constant MAX_RULE_WIDEN = 8;
    uint256 internal constant MAX_PANEL = 512; // per-depth commit target
    uint256 internal constant MAX_RULE_TOPICS = 16;
    uint256 internal constant MAX_ARRAY_LEN = 16;
    uint256 internal constant MAX_WINDOW = 30 days;
    uint256 internal constant MAX_FREEZE = 365 days;
    uint256 internal constant MAX_BOND_MULT = 100;
    uint256 internal constant MAX_SEED_LAG = 250; // < 256-block blockhash window
    uint256 internal constant MAX_TOTAL_DRAWS = 4000; // reachable settlement bound

    struct Params {
        uint256 minStake; // MIN_STAKE
        uint256 activationDelay; // ACTIVATION_DELAY
        uint256 exitCooldown; // EXIT_COOLDOWN
        uint256 commitTimeout; // COMMIT_TIMEOUT
        uint256 revealWindow; // REVEAL_WINDOW
        uint256 minReveals; // MIN_REVEALS
        uint256 maxWiden; // MAX_WIDEN
        uint256 maxDepth; // MAX_DEPTH
        uint256 bondMultiplier; // BOND_MULTIPLIER (bond floor = mult * pot)
        uint256 maxTopics; // MAX_TOPICS
        uint256 feeBase; // FEE_BASE (base units)
        uint256 feePerTopic; // FEE_PER_TOPIC (base units)
        uint256 riskPerSeat; // RISK_PER_SEAT (stake locked per seat on commit, D5)
        uint256 seedLag; // SEED_LAG (blocks between arm and snapshot, D4)
        uint256 claimBountyFrac; // CLAIM_BOUNTY as WAD fraction of residual (M2-5)
        uint256 bonusFrac; // winning-appellant bonus as WAD fraction of residual (M2-5)
        uint256 freezeBase; // FREEZE_BASE (seconds)
        uint256 freezeCap; // FREEZE_CAP multiplier (WAD, >= 1e18)
        uint256 trackSat; // TRACK_SAT (WAD)
        uint256 trackDecay; // TRACK_DECAY per-case decay (WAD fraction, < 1e18)
        uint256 failedRevealFreeze; // brief freeze for commit-and-vanish (seconds)
        uint256 supersafeAge; // SUPERSAFE_AGE (seconds)
    }

    Params internal params; // live mirror of rulesets[currentRulesVersion].p

    /// COMMIT_TARGET[depth]: counted seats per depth (clamped to last at deeper).
    uint256[] internal commitTargetByDepth;
    /// APPEAL_WINDOW[depth]: appeal window duration per depth.
    uint256[] internal appealWindowByDepth;

    // H-11: governance changes create a new immutable ruleset VERSION; each case
    // pins the version live when it was submitted and reads all its consensus
    // parameters from that pinned ruleset, so a mid-case parameter change never
    // alters the rules of an already-open case.
    struct Ruleset {
        Params p;
        uint256[] commitTargets;
        uint256[] appealWindows;
    }

    mapping(uint256 => Ruleset) internal rulesets;
    uint256 public currentRulesVersion;

    // --- governance (§9.9, P6) -----------------------------------------------

    address public governance; // multisig
    uint256 public timelockDelay; // delay between proposal and execution
    uint256 public guidelinesVersion; // current guidelines version
    mapping(uint256 => bytes32) public guidelinesHashByVersion; // append-only history (invariant 9)

    struct PendingParams {
        uint256 eta;
        bool exists;
        Params p;
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
        uint256 exitClaimableAt; // H-11: cooldown end snapshotted at request; governance can't extend it retroactively
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
        params = Params({
            minStake: 10 * XBZZ,
            activationDelay: 7 days,
            exitCooldown: 7 days,
            commitTimeout: 24 hours,
            revealWindow: 24 hours,
            minReveals: 3,
            maxWiden: 3,
            maxDepth: 3,
            bondMultiplier: 2,
            maxTopics: 5,
            feeBase: 1 * XBZZ,
            feePerTopic: XBZZ / 2,
            riskPerSeat: 10 * XBZZ, // == MIN_STAKE (D5)
            seedLag: 2,
            claimBountyFrac: WAD / 100, // 1%
            bonusFrac: WAD / 10, // 10%
            freezeBase: 7 days,
            freezeCap: 4 * WAD, // FREEZE_CAP = 4 (WO-6 recalibration)
            trackSat: 60 * WAD, // TRACK_SAT = 60
            trackDecay: (WAD * 95) / 100, // TRACK_DECAY = 0.95
            failedRevealFreeze: 1 days,
            supersafeAge: 96 hours
        });
        commitTargetByDepth = [uint256(5), 11, 23, 47];
        appealWindowByDepth = [uint256(4 days), 3 days, 3 days, 3 days];

        // Ruleset version 0 mirrors the initial params (H-11).
        rulesets[0] = Ruleset({p: params, commitTargets: commitTargetByDepth, appealWindows: appealWindowByDepth});

        governance = msg.sender;
        timelockDelay = 7 days;
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
        // H-11: snapshot the cooldown end and settle the min-stake decision now, so
        // a later governance change can neither extend the wait nor invalidate an
        // already-valid exit.
        m.exitClaimableAt = block.timestamp + params.exitCooldown;
        _syncTree(msg.sender, m); // remove exiting stake from eligibility

        emit ExitRequested(msg.sender, amount, m.exitClaimableAt);
    }

    /// @notice Claim a previously requested exit after the cooldown. No admin
    ///         gate exists on this path (invariant §9.5: withdrawals never
    ///         pausable).
    function withdraw() external nonReentrant {
        Moderator storage m = moderators[msg.sender];
        uint256 amount = m.exitAmount;
        if (amount == 0) revert NoExitPending();
        // H-11: cooldown end and the min-stake decision were fixed at request time.
        if (block.timestamp < m.exitClaimableAt) revert CooldownNotElapsed();

        m.free -= amount;
        totalFreeStake -= amount;
        if (m.pending > m.free) m.pending = m.free; // keep pending <= free
        m.exitAmount = 0;
        m.exitRequestedAt = 0;
        m.exitClaimableAt = 0;
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

    // =========================================================================
    // Case lifecycle (§4, §5) — submit -> DRAW -> COMMIT -> REVEAL -> TALLY ->
    // APPEAL_WINDOW -> FINALIZED, with widen and VOID. Appeals (the
    // APPEAL_WINDOW -> DRAW(depth+1) branch) are added in M2-4; settlement
    // (FINALIZED -> SETTLED via claim) in M2-5.
    // =========================================================================

    enum Kind {
        SUBMISSION,
        REMOVAL
    }

    enum Phase {
        NONE,
        DRAW,
        COMMIT,
        REVEAL,
        TALLY,
        APPEAL_WINDOW,
        FINALIZED,
        SETTLING, // H-04: settlement in progress across batched claim() calls
        VOID,
        SETTLED
    }

    enum Vote {
        None,
        Approve,
        Reject
    }

    enum Outcome {
        Unset,
        Approve,
        Reject,
        Void
    }

    struct Round {
        uint256 nSeats; // counted seats drawn so far this round (grows on widen)
        uint256 seatDrawCount; // total seat draws performed (offset base for widen draws)
        uint256 widenCount; // widen re-draws used
        uint256 seatSnapshotBlock; // block whose blockhash seeds the seat draw
        uint256 outcomeSnapshotBlock; // block whose blockhash seeds the outcome draw
        bytes32 seatSeed;
        bytes32 outcomeSeed;
        address[] seatHolders; // unique drawn addresses
        mapping(address => uint256) seats; // seat-holder -> seat count (may grow on widen)
        mapping(address => uint256) talliedSeats; // seats counted for THIS voter at reveal (frozen; F2)
        mapping(address => bytes32) commits; // seat-holder -> commit hash
        mapping(address => Vote) reveals; // seat-holder -> revealed vote
        mapping(address => bool) committed; // has committed
        mapping(address => uint256) committedAmt; // stake locked by this seat-holder for this round
        uint256 committedCount; // # seat-holders committed
        uint256 revealedCount; // # committers revealed
        uint256 approveSeats; // Σ seats revealing Approve
        uint256 rejectSeats; // Σ seats revealing Reject
        // H-04/M-03: Σ talliedSeats × track (snapshotted at reveal) per side, so
        // settlement derives mean-track in O(rounds) and freeze durations no
        // longer depend on when the case is claimed relative to track mutations.
        uint256 approveTrackNum;
        uint256 rejectTrackNum;
        bool underQuorum; // H-09: outcome armed below MIN_REVEALS after max widen
        uint256 revealedSeats; // approveSeats + rejectSeats
        Outcome outcome; // drawn ∝ seat counts
        Outcome appealFor; // the outcome an appeal against THIS round argues for
        uint256 bond; // flip-bond accumulated to appeal this round's outcome
        bool bondInPot; // true once the floor was met and the bond moved to the pot
        bool bondRefundOnly; // H-10: the appeal this bond funded failed for lack of quorum, not on merits -> refund capital (no bonus, not forfeited)
        mapping(address => uint256) bondContribs;
    }

    struct Case {
        uint256 id;
        Kind kind;
        address submitter;
        bytes32 contentHash;
        bytes32 metaHash;
        bytes32[] topicKeys;
        uint256 targetCaseId; // removal only (§8.2, validated in M2-6)
        uint256 guidelinesVersion; // pinned at submit (governance in M2-7)
        uint256 rulesVersion; // H-11: consensus ruleset pinned at submit
        Phase phase;
        uint256 depth;
        uint256 pot; // fee + appeal bonds moved in (§6.2)
        uint256 appealBondTotal; // Σ appeal bonds that met their floor and joined the pot
        uint256 phaseDeadline;
        Outcome finalOutcome;
        // H-01: a SUBMISSION whose entries are currently live in the index. Set
        // true when its entries are written, false when a removal deletes them.
        // Serves as the target's "index generation" signal: a removal is bound to
        // an indexed target at submit and no-ops at settlement if it is no longer
        // indexed (already removed by a concurrent removal).
        bool isIndexed;
        Round[] rounds; // one per depth reached
        // C-01: winning-appeal refunds+bonuses are pulled (not credited in a loop
        // at settlement, which was unbounded in contributor count). These running
        // totals let claimAppealPayout compute each share in O(1); the final
        // claimer absorbs the pro-rata dust, so the pool is consumed exactly.
        uint256 apBonusPoolLeft; // bonus pool not yet pulled
        uint256 apContribTotLeft; // winning-contribution total not yet pulled
    }

    mapping(uint256 => Case) internal cases;
    uint256 public nextCaseId;
    uint256 public openPotsTotal; // Σ live case pots (§9.1)
    uint256 public totalPendingBond; // Σ appeal contributions collected but not yet flooring a round
    uint256 public totalPendingPayout; // Σ settled bond refunds + bonuses awaiting pull (per (case,depth), pulled via claimAppealPayout)
    uint256 public totalSettling; // H-04: pot value in flight during batched settlement (rewards not yet credited + unpaid bounty); 0 outside an in-progress claim

    // H-04: per-case batched-settlement working state. The aggregate scalars are
    // computed once (O(rounds)) when settlement starts; the (round, idx) cursor
    // walks seat-holders across batched claim() calls so no single transaction
    // must dispose all of a maximal case's ~344 committed seats at once.
    struct SettleState {
        uint256 winnersSeats;
        uint256 distributable;
        uint256 freezeDur;
        uint256 bounty; // base claim bounty (reward-channel dust added at finish)
        uint256 pot; // original pot, for the Settled event
        uint256 distributed; // Σ rewards credited so far (across batches)
        uint256 round; // cursor: current round
        uint256 idx; // cursor: next seat-holder index in that round
    }

    mapping(uint256 => SettleState) internal settleState;
    mapping(uint256 => mapping(address => bool)) internal trackDecayed; // caseId -> participant -> track already decayed (dedup, O(1))
    // Dedup (P3, §9.7): H(content, meta, topicKey) -> owning caseId + 1 (0 = free).
    // H-02: keyed by OWNER, not a bare bool, so an obsolete case (e.g. a stale
    // removal) can never clear a reservation a newer resubmission now holds.
    mapping(bytes32 => uint256) internal dedupOwnerPlusOne;

    // --- index (§8, README 3.8) ----------------------------------------------

    struct Entry {
        bytes32 contentHash;
        bytes32 metaHash;
        uint40 approvalTime; // settlement time; drives the supersafe age filter
        bool uncontested; // true iff no Reject vote was ever revealed in the case
        bool fullQuorum; // H-09: decided at full quorum (no under-quorum fallback, enough independent revealers)
        uint256 caseId; // back-reference for removal (§8.2)
    }

    mapping(bytes32 => Entry[]) internal indexByTopic; // topicKey -> approved entries
    mapping(bytes32 => bool) internal topicSeen; // first index write emits TopicCreated
    // H-03: topicKey -> caseId -> (index in indexByTopic[topicKey]) + 1, so entry
    // removal is O(1) swap-pop instead of an unbounded linear scan that could grow
    // past the block gas limit and make a removal unclaimable.
    mapping(bytes32 => mapping(uint256 => uint256)) internal entryPosPlusOne;

    event TopicCreated(bytes32 indexed topicKey);
    event EntryWritten(uint256 indexed caseId, bytes32 indexed topicKey, bool uncontested);
    event EntryRemoved(uint256 indexed caseId, bytes32 indexed topicKey);

    // --- case events ---------------------------------------------------------

    event CaseSubmitted(uint256 indexed caseId, Kind kind, address indexed submitter, uint256 fee);
    event RoundOpened(uint256 indexed caseId, uint256 indexed depth, uint256 nSeats, uint256 seatSnapshotBlock);
    event SeedRearmed(uint256 indexed caseId, uint256 indexed depth, bool outcomeSeed, uint256 newSnapshotBlock);
    event SeatsDrawn(uint256 indexed caseId, uint256 indexed depth, uint256 nSeats);
    event CommitOpened(uint256 indexed caseId, uint256 indexed depth, uint256 deadline);
    event Committed(uint256 indexed caseId, address indexed moderator, uint256 seats);
    event RevealOpened(uint256 indexed caseId, uint256 indexed depth, uint256 deadline);
    event Revealed(uint256 indexed caseId, address indexed moderator, Vote vote, uint256 seats);
    event Widened(uint256 indexed caseId, uint256 indexed depth, uint256 widenCount, uint256 nSeats);
    event OutcomeArmed(uint256 indexed caseId, uint256 indexed depth, uint256 outcomeSnapshotBlock);
    event OutcomeDrawn(uint256 indexed caseId, uint256 indexed depth, Outcome outcome);
    event AppealWindowOpened(uint256 indexed caseId, uint256 indexed depth, uint256 deadline);
    event Finalized(uint256 indexed caseId, Outcome finalOutcome);
    event Voided(uint256 indexed caseId);
    event AppealBondContributed(
        uint256 indexed caseId, uint256 indexed depth, address indexed contributor, uint256 accepted, uint256 bondTotal
    );
    event Appealed(uint256 indexed caseId, uint256 indexed fromDepth, Outcome appealFor);
    event BondReclaimed(uint256 indexed caseId, uint256 indexed depth, address indexed contributor, uint256 amount);

    // --- case errors ---------------------------------------------------------

    error BadTopicCount();
    error FeeTooLow();
    error DuplicateSubmission();
    error DuplicateTopic(); // M-04: a submission's topic keys must be distinct
    error WrongPhase();
    error SeedNotReady();
    error NotSeatHolder();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error BadReveal();
    error BadVote();
    error DeadlineNotReached();
    error NoEligibleModerators();
    error InsufficientEligibleFree();
    error AppealsClosed();
    error AppealWindowClosed();
    error AppealAlreadyFull();
    error CaseNotTerminal();
    error BondLocked();
    error NothingToReclaim();
    error PhaseDeadlinePassed(); // M-02: commit/reveal after the window has elapsed
    error BadKind(); // submit() is submissions-only; removals go through submitRemoval
    error TargetNotRemovable(); // removal target must be a settled, approved, indexed submission

    event RemovalTargeted(
        uint256 indexed caseId,
        uint256 indexed targetCaseId,
        bytes32 contentHash,
        bytes32 metaHash,
        uint256 topicCount
    );

    // --- submit --------------------------------------------------------------

    /// @notice Open a moderation case. `kind` is SUBMISSION (approve/reject new
    ///         content) or REMOVAL (approve/reject deleting an existing entry).
    ///         Fee must be >= minFee(nTopics); overpayment is allowed and joins
    ///         the pot. For submissions, the (content, meta, topic) triple is
    ///         reserved against duplicates (§9.7).
    function submit(
        Kind kind,
        bytes32 contentHash,
        bytes32 metaHash,
        bytes32[] calldata topicKeys,
        uint256 targetCaseId,
        uint256 fee
    ) external nonReentrant returns (uint256 caseId) {
        // H-01: removals no longer accept caller-chosen content/meta/topics/target
        // (they were ignored at settlement, which resolved the target lazily — a
        // future-ID or payload-substitution vector). Use submitRemoval instead.
        if (kind != Kind.SUBMISSION) revert BadKind();
        targetCaseId; // unused for submissions
        uint256 n = topicKeys.length;
        if (n == 0 || n > params.maxTopics) revert BadTopicCount();
        if (fee < minFee(n)) revert FeeTooLow();

        // M-04: topic keys must be distinct (n <= maxTopics is small). Duplicates
        // would double-write the entry and corrupt the O(1) position map (H-03).
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < i; ++j) {
                if (topicKeys[i] == topicKeys[j]) revert DuplicateTopic();
            }
        }
        for (uint256 i; i < n; ++i) {
            if (dedupOwnerPlusOne[_dedupKey(contentHash, metaHash, topicKeys[i])] != 0) revert DuplicateSubmission();
        }

        address(token).safeTransferFrom(msg.sender, address(this), fee);

        caseId = nextCaseId++;
        Case storage c = cases[caseId];
        c.id = caseId;
        c.kind = Kind.SUBMISSION;
        c.submitter = msg.sender;
        c.contentHash = contentHash;
        c.metaHash = metaHash;
        for (uint256 i; i < n; ++i) {
            c.topicKeys.push(topicKeys[i]);
            dedupOwnerPlusOne[_dedupKey(contentHash, metaHash, topicKeys[i])] = caseId + 1; // this case owns the reservation
        }
        c.guidelinesVersion = guidelinesVersion; // pinned at submit; never changes (§9.6)
        c.rulesVersion = currentRulesVersion; // H-11: pin the consensus ruleset
        c.pot = fee;
        openPotsTotal += fee;
        c.finalOutcome = Outcome.Unset;

        _openRound(c, 0);
        emit CaseSubmitted(caseId, Kind.SUBMISSION, msg.sender, fee);
    }

    /// @notice Open a REMOVAL case against an existing index entry (§8.2, P1).
    ///         Unlike the old generic path, the target is bound at submit: it must
    ///         be a settled, approved SUBMISSION whose entries are currently in the
    ///         index, and the content/metadata/topics are derived from that target
    ///         (not caller-supplied), so the removal cannot name a future case ID
    ///         or display a payload that differs from what settlement acts on
    ///         (H-01). Fee scales with the target's real topic count.
    function submitRemoval(uint256 targetCaseId, uint256 fee) external nonReentrant returns (uint256 caseId) {
        if (targetCaseId >= nextCaseId) revert TargetNotRemovable();
        Case storage target = cases[targetCaseId];
        if (target.kind != Kind.SUBMISSION || target.phase != Phase.SETTLED) revert TargetNotRemovable();
        if (target.finalOutcome != Outcome.Approve || !target.isIndexed) revert TargetNotRemovable();

        uint256 n = target.topicKeys.length;
        if (fee < minFee(n)) revert FeeTooLow();

        address(token).safeTransferFrom(msg.sender, address(this), fee);

        caseId = nextCaseId++;
        Case storage c = cases[caseId];
        c.id = caseId;
        c.kind = Kind.REMOVAL;
        c.submitter = msg.sender;
        // Derived from the bound target so client-displayed payload == settled action.
        c.contentHash = target.contentHash;
        c.metaHash = target.metaHash;
        for (uint256 i; i < n; ++i) {
            c.topicKeys.push(target.topicKeys[i]);
        }
        c.targetCaseId = targetCaseId;
        c.guidelinesVersion = guidelinesVersion;
        c.rulesVersion = currentRulesVersion; // H-11
        c.pot = fee;
        openPotsTotal += fee;
        c.finalOutcome = Outcome.Unset;

        _openRound(c, 0);
        emit CaseSubmitted(caseId, Kind.REMOVAL, msg.sender, fee);
        emit RemovalTargeted(caseId, targetCaseId, target.contentHash, target.metaHash, n);
    }

    // --- phase transitions (permissionless pokes) ----------------------------

    /// @notice DRAW -> COMMIT: realize the seat seed from its snapshot block and
    ///         draw the panel stake-weighted with replacement (§5.2, §5.3). If
    ///         the snapshot block is already older than the blockhash window
    ///         (nobody poked in time), re-arm and wait (D4).
    function realizeSeats(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.DRAW) revert WrongPhase();
        Round storage r = _cur(c);
        if (block.number <= r.seatSnapshotBlock) revert SeedNotReady();

        bytes32 bh = blockhash(r.seatSnapshotBlock);
        if (bh == 0) {
            r.seatSnapshotBlock = block.number + _cp(c).seedLag;
            emit SeedRearmed(caseId, c.depth, false, r.seatSnapshotBlock);
            return;
        }
        if (stakeTree.total() == 0) revert NoEligibleModerators();

        // H-06: domain-separate the raw blockhash so two cases snapshotting the
        // same block (or the same case at different depths) never draw identical
        // panels. The purpose tag keeps seat vs outcome entropy independent.
        r.seatSeed = _domainSeed(caseId, c.depth, SEED_SEATS, bh);
        _drawSeats(r, r.nSeats, r.seatSeed, 0);

        c.phase = Phase.COMMIT;
        c.phaseDeadline = block.timestamp + _cp(c).commitTimeout;
        emit SeatsDrawn(caseId, c.depth, r.nSeats);
        emit CommitOpened(caseId, c.depth, c.phaseDeadline);
    }

    /// @notice Commit a hidden vote. Only a drawn seat-holder may commit, and
    ///         doing so locks RISK_PER_SEAT per seat from free -> committed (D5).
    function commitVote(uint256 caseId, bytes32 commitHash) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.COMMIT) revert WrongPhase();
        if (block.timestamp >= c.phaseDeadline) revert PhaseDeadlinePassed(); // M-02: hard window
        Round storage r = _cur(c);
        uint256 s = r.seats[msg.sender];
        if (s == 0) revert NotSeatHolder();
        if (r.committed[msg.sender]) revert AlreadyCommitted();

        uint256 lock = _cp(c).riskPerSeat * s;
        _lockStake(msg.sender, lock);
        r.committedAmt[msg.sender] = lock;
        r.commits[msg.sender] = commitHash;
        r.committed[msg.sender] = true;
        r.committedCount++;

        emit Committed(caseId, msg.sender, s);
        if (r.committedCount == r.seatHolders.length) _toReveal(c);
    }

    /// @notice The commit hash a voter must submit: bound to chain, contract,
    ///         case, depth, voter, vote, and salt (M-01). Binding prevents copying
    ///         another voter's commitment or replaying one across cases/depths.
    function computeCommit(uint256 caseId, uint256 depth, address voter, Vote vote, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), caseId, depth, voter, uint8(vote), salt));
    }

    /// @notice COMMIT -> REVEAL once the commit window elapses (also triggered
    ///         automatically when every seat-holder has committed).
    function closeCommit(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.COMMIT) revert WrongPhase();
        if (block.timestamp < c.phaseDeadline) revert DeadlineNotReached();
        _toReveal(c);
    }

    /// @notice Reveal a previously committed vote (Approve or Reject) with its
    ///         salt.
    function revealVote(uint256 caseId, Vote vote, bytes32 salt) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.REVEAL) revert WrongPhase();
        if (block.timestamp >= c.phaseDeadline) revert PhaseDeadlinePassed(); // M-02: hard window
        if (vote != Vote.Approve && vote != Vote.Reject) revert BadVote();
        Round storage r = _cur(c);
        if (!r.committed[msg.sender]) revert NotCommitted();
        if (r.reveals[msg.sender] != Vote.None) revert AlreadyRevealed();
        if (computeCommit(caseId, c.depth, msg.sender, vote, salt) != r.commits[msg.sender]) revert BadReveal();

        r.reveals[msg.sender] = vote;
        uint256 s = r.seats[msg.sender];
        // Freeze the seat count credited to this voter at reveal time: a later
        // widen re-draw can add seats to r.seats[voter], but settlement must pay
        // (and mean-track) only the seats actually tallied here (F2).
        r.talliedSeats[msg.sender] = s;
        uint256 trackContrib = s * moderators[msg.sender].track; // snapshot track now (M-03)
        if (vote == Vote.Approve) {
            r.approveSeats += s;
            r.approveTrackNum += trackContrib;
        } else {
            r.rejectSeats += s;
            r.rejectTrackNum += trackContrib;
        }
        r.revealedSeats += s;
        r.revealedCount++;

        emit Revealed(caseId, msg.sender, vote, s);
        if (r.revealedCount == r.committedCount) _closeReveal(c);
    }

    /// @notice REVEAL -> TALLY decision once the reveal window elapses (also
    ///         triggered automatically when every committer has revealed).
    function closeReveal(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.REVEAL) revert WrongPhase();
        if (block.timestamp < c.phaseDeadline) revert DeadlineNotReached();
        _closeReveal(c);
    }

    /// @notice TALLY -> APPEAL_WINDOW: realize the outcome seed (armed only after
    ///         reveals closed, §7) and draw the outcome ∝ seat counts. Re-arms on
    ///         a stale snapshot block (D4).
    function realizeOutcome(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.TALLY) revert WrongPhase();
        Round storage r = _cur(c);
        if (block.number <= r.outcomeSnapshotBlock) revert SeedNotReady();

        bytes32 bh = blockhash(r.outcomeSnapshotBlock);
        if (bh == 0) {
            r.outcomeSnapshotBlock = block.number + _cp(c).seedLag;
            emit SeedRearmed(caseId, c.depth, true, r.outcomeSnapshotBlock);
            return;
        }
        r.outcomeSeed = _domainSeed(caseId, c.depth, SEED_OUTCOME, bh); // H-06
        uint256 tot = r.approveSeats + r.rejectSeats; // >= 1 by construction
        uint256 rand = uint256(r.outcomeSeed) % tot;
        r.outcome = rand < r.approveSeats ? Outcome.Approve : Outcome.Reject;

        c.phase = Phase.APPEAL_WINDOW;
        c.phaseDeadline = block.timestamp + _appealWindow(c, c.depth);
        emit OutcomeDrawn(caseId, c.depth, r.outcome);
        emit AppealWindowOpened(caseId, c.depth, c.phaseDeadline);
    }

    /// @notice APPEAL_WINDOW -> FINALIZED once the window closes with no
    ///         successful appeal. (Appeals intercept this in M2-4.)
    function finalize(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.APPEAL_WINDOW) revert WrongPhase();
        if (block.timestamp < c.phaseDeadline) revert DeadlineNotReached();
        c.finalOutcome = _cur(c).outcome;
        c.phase = Phase.FINALIZED;
        emit Finalized(caseId, c.finalOutcome);
    }

    // --- appeals (§5.4) ------------------------------------------------------

    /// @notice Contribute toward the flip-bond that appeals the current round's
    ///         outcome. Anyone may contribute during the appeal window (§5.4) —
    ///         it is a directional flip request, not a first-come slot.
    ///         Contributions are capped exactly at the floor (BOND_MULTIPLIER ×
    ///         pot); the contributor that reaches it takes a partial fill, and
    ///         only the accepted amount is pulled. When the floor is met the bond
    ///         joins the pot and the next-depth round opens.
    /// @return accepted The amount actually taken (<= amount).
    function contributeAppealBond(uint256 caseId, uint256 amount) external nonReentrant returns (uint256 accepted) {
        if (amount == 0) revert AmountZero();
        Case storage c = cases[caseId];
        if (c.phase != Phase.APPEAL_WINDOW) revert WrongPhase();
        if (c.depth >= _cp(c).maxDepth) revert AppealsClosed();
        if (block.timestamp >= c.phaseDeadline) revert AppealWindowClosed();

        Round storage r = _cur(c);
        if (r.appealFor == Outcome.Unset) r.appealFor = _opposite(r.outcome);

        uint256 floor = _cp(c).bondMultiplier * c.pot;
        // Guard underflow: a governance parameter change (lower bondMultiplier) can
        // execute mid-window and drop the floor below the already-aggregated bond.
        if (floor <= r.bond) revert AppealAlreadyFull();
        uint256 room = floor - r.bond;
        accepted = amount < room ? amount : room;

        address(token).safeTransferFrom(msg.sender, address(this), accepted);
        r.bondContribs[msg.sender] += accepted;
        r.bond += accepted;
        totalPendingBond += accepted;
        emit AppealBondContributed(caseId, c.depth, msg.sender, accepted, r.bond);

        if (r.bond == floor) {
            // Floor met: the bond joins the pot and a fresh round opens at the
            // next depth, arguing for the flipped outcome.
            uint256 fromDepth = c.depth;
            totalPendingBond -= r.bond;
            c.pot += r.bond;
            openPotsTotal += r.bond;
            c.appealBondTotal += r.bond;
            r.bondInPot = true;
            _openRound(c, fromDepth + 1);
            emit Appealed(caseId, fromDepth, r.appealFor);
        }
    }

    /// @notice Reclaim an appeal contribution to a bond that never met its floor
    ///         (so no round opened from it) after the case reaches a terminal
    ///         state. Bonds that DID meet their floor joined the pot and are
    ///         settled in claim() (refund + bonus if the appeal won, forfeit if
    ///         it lost) — those cannot be reclaimed here.
    function reclaimBond(uint256 caseId, uint256 depth) external nonReentrant {
        Case storage c = cases[caseId];
        if (
            c.phase != Phase.FINALIZED && c.phase != Phase.SETTLING && c.phase != Phase.SETTLED
                && c.phase != Phase.VOID
        ) {
            revert CaseNotTerminal();
        }
        Round storage r = c.rounds[depth];
        if (r.bondInPot) revert BondLocked();
        uint256 amt = r.bondContribs[msg.sender];
        if (amt == 0) revert NothingToReclaim();

        r.bondContribs[msg.sender] = 0;
        totalPendingBond -= amt;
        address(token).safeTransfer(msg.sender, amt);
        emit BondReclaimed(caseId, depth, msg.sender, amt);
    }

    function _opposite(Outcome o) internal pure returns (Outcome) {
        return o == Outcome.Approve ? Outcome.Reject : Outcome.Approve;
    }

    // =========================================================================
    // Settlement (§6) — claim() runs the WO-1 solvent payout order in integers:
    // refund winning bonds first, then bounty and bonuses off the residual, then
    // the remainder to coherent seats; freeze incoherent/failed voters; update
    // track. All divisions round down and every remainder is swept into the
    // claim bounty, so funds conservation (invariant 11) is an exact equality.
    // =========================================================================

    event Settled(uint256 indexed caseId, Outcome finalOutcome, uint256 pot, uint256 claimBounty);
    event SettleProgressed(uint256 indexed caseId, uint256 round, uint256 idx);
    event PayoutClaimed(address indexed who, uint256 amount);

    error CaseNotFinalized();

    /// @notice Settle a FINALIZED case in a single call (unbounded work). Suitable
    ///         for any realistic case; for a maximal adversarial case that would
    ///         not fit one block, use claim(caseId, maxSteps) to settle it in
    ///         batches. Permissionless; the caller that completes settlement earns
    ///         the claim bounty (plus reward-channel rounding dust).
    function claim(uint256 caseId) external nonReentrant {
        _settle(caseId, type(uint256).max);
    }

    /// @notice Settle up to `maxSteps` seat-holders of a FINALIZED/SETTLING case,
    ///         advancing a persistent cursor (H-04). The first call computes the
    ///         O(rounds) aggregates and moves the case to SETTLING; subsequent
    ///         calls dispose seat-holders in bounded batches; the call that
    ///         processes the last seat-holder runs the index effects, pays the
    ///         bounty, and moves the case to SETTLED. So no single transaction
    ///         must dispose all of a maximal case's ~344 committed seats at once.
    function claim(uint256 caseId, uint256 maxSteps) external nonReentrant {
        _settle(caseId, maxSteps);
    }

    function _settle(uint256 caseId, uint256 maxSteps) internal {
        Case storage c = cases[caseId];
        if (c.phase == Phase.FINALIZED) _settleInit(c);
        if (c.phase != Phase.SETTLING) revert CaseNotFinalized();
        _settleStep(c, maxSteps);
    }

    /// @dev O(rounds) aggregate + money bookkeeping, run once when settlement
    ///      starts. Winners' seats and mean-track are read from the per-round,
    ///      per-side accumulators frozen at reveal (no O(participants) scan).
    function _settleInit(Case storage c) internal {
        Outcome fo = c.finalOutcome;
        uint256 nRounds = c.rounds.length;
        uint256 winnersSeats;
        uint256 meanTrackNum;
        uint256 refunds;
        uint256 winningContribTot;
        for (uint256 d; d < nRounds; ++d) {
            Round storage r = c.rounds[d];
            if (fo == Outcome.Approve) {
                winnersSeats += r.approveSeats;
                meanTrackNum += r.approveTrackNum;
            } else {
                winnersSeats += r.rejectSeats;
                meanTrackNum += r.rejectTrackNum;
            }
            if (r.bondInPot) {
                if (r.appealFor == fo) {
                    // winning appeal: capital refunded + shares the bonus pool
                    refunds += r.bond;
                    winningContribTot += r.bond;
                } else if (r.bondRefundOnly) {
                    // quorum-failed appeal (H-10): capital refunded, no bonus, not
                    // forfeited to winners — excluded from the distributable pot.
                    refunds += r.bond;
                }
            }
        }

        Params storage p = _cp(c); // cache pinned ruleset (avoids stack pressure)
        uint256 pot = c.pot;
        uint256 residual = pot - refunds; // WO-1: refund winning bond capital first
        uint256 bounty = (residual * p.claimBountyFrac) / WAD;
        uint256 bonusPool = winningContribTot == 0 ? 0 : (residual * p.bonusFrac) / WAD;
        uint256 distributable = residual - bounty - bonusPool;

        // Winning-appeal refunds + bonuses become pull-based (C-01); the reward
        // pool + bounty are held in `totalSettling` while the batched disposition
        // credits them out, so conservation is exact at every intermediate state.
        openPotsTotal -= pot;
        c.apBonusPoolLeft = bonusPool;
        c.apContribTotLeft = winningContribTot;
        totalPendingPayout += refunds + bonusPool;
        totalSettling += residual - bonusPool; // = bounty + distributable, in flight

        SettleState storage s = settleState[c.id];
        s.winnersSeats = winnersSeats;
        s.distributable = distributable;
        s.freezeDur = FreezeMath.freezeDuration(
            winnersSeats == 0 ? 0 : meanTrackNum / winnersSeats, p.trackSat, p.freezeCap, p.freezeBase
        );
        s.bounty = bounty;
        s.pot = pot;
        c.phase = Phase.SETTLING;
    }

    /// @dev Dispose up to `maxSteps` seat-holders from the cursor, then finish if
    ///      the last round is complete. Every seat-holder visit counts toward the
    ///      budget so a batch's gas is bounded regardless of non-committers.
    function _settleStep(Case storage c, uint256 maxSteps) internal {
        SettleState storage s = settleState[c.id];
        Outcome fo = c.finalOutcome;
        uint256 nRounds = c.rounds.length;
        uint256 round = s.round;
        uint256 idx = s.idx;
        uint256 steps;
        while (round < nRounds) {
            Round storage r = c.rounds[round];
            uint256 nsh = r.seatHolders.length;
            while (idx < nsh) {
                if (steps >= maxSteps) {
                    s.round = round;
                    s.idx = idx;
                    emit SettleProgressed(c.id, round, idx);
                    return;
                }
                address a = r.seatHolders[idx];
                idx++;
                steps++;
                if (r.committed[a]) _disposeSeat(c, r, a, fo, s);
            }
            round++;
            idx = 0;
        }
        s.round = round;
        s.idx = 0;
        _settleFinish(c, s);
    }

    /// @dev Return or freeze one seat-holder's committed stake, credit its reward
    ///      if coherent, and decay its track once per case.
    function _disposeSeat(Case storage c, Round storage r, address a, Outcome fo, SettleState storage s) internal {
        uint256 amt = r.committedAmt[a];
        Vote vote = r.reveals[a];
        if (vote == Vote.None) {
            _freezeSlice(a, amt, block.timestamp + _cp(c).failedRevealFreeze);
        } else if (_coherent(vote, fo)) {
            Moderator storage m = moderators[a];
            m.committed -= amt;
            m.free += amt;
            totalCommittedStake -= amt;
            totalFreeStake += amt;
            uint256 reward = s.winnersSeats == 0 ? 0 : (s.distributable * r.talliedSeats[a]) / s.winnersSeats;
            if (reward > 0) {
                m.free += reward;
                totalFreeStake += reward;
                s.distributed += reward;
                totalSettling -= reward;
            }
            _syncTree(a, m);
        } else {
            _freezeSlice(a, amt, block.timestamp + s.freezeDur);
        }
        _touchTrack(c, r, a, fo);
    }

    /// @dev Decay a participant's track exactly once per case (O(1) dedup, no more
    ///      O(participants²) scan), with the coherent-undisputed +1 for a single
    ///      round case (§6.5).
    function _touchTrack(Case storage c, Round storage r, address a, Outcome fo) internal {
        if (trackDecayed[c.id][a]) return;
        trackDecayed[c.id][a] = true;
        Moderator storage m = moderators[a];
        m.track = (m.track * _cp(c).trackDecay) / WAD;
        if (c.rounds.length == 1 && r.reveals[a] != Vote.None && _coherent(r.reveals[a], fo)) {
            m.track += WAD; // +1 for a coherent, undisputed participation
        }
    }

    /// @dev Complete settlement: sweep reward-channel dust into the claim bounty,
    ///      run index effects, pay the finisher, and mark SETTLED.
    function _settleFinish(Case storage c, SettleState storage s) internal {
        uint256 claimBounty = s.bounty + (s.distributable - s.distributed);
        totalSettling -= claimBounty; // drains this case's in-flight amount to 0
        c.pot = 0;
        _settleIndex(c);
        c.phase = Phase.SETTLED;
        if (claimBounty > 0) address(token).safeTransfer(msg.sender, claimBounty);
        emit Settled(c.id, c.finalOutcome, s.pot, claimBounty);
    }

    /// @notice Withdraw a winning appeal contribution's refund (own capital) plus
    ///         its pro-rata bonus, after the case has SETTLED. Pull-based and O(1)
    ///         (C-01): settlement never iterates the contributor set, so an
    ///         attacker cannot brick claim() by funding a bond from many
    ///         addresses. The final claimer of a case's pool absorbs the rounding
    ///         dust, so the pool is consumed to the wei.
    function claimAppealPayout(uint256 caseId, uint256 depth) external nonReentrant {
        Case storage c = cases[caseId];
        if (c.phase != Phase.SETTLED) revert CaseNotFinalized();
        if (depth >= c.rounds.length) revert NothingToReclaim();
        Round storage r = c.rounds[depth];
        bool winning = r.bondInPot && r.appealFor == c.finalOutcome;
        bool refundOnly = r.bondInPot && r.bondRefundOnly && !winning; // H-10: capital back, no bonus
        // A bond that lost on the merits was forfeited into the rewards — nothing to pull.
        if (!winning && !refundOnly) revert NothingToReclaim();
        uint256 contrib = r.bondContribs[msg.sender];
        if (contrib == 0) revert NothingToReclaim();

        r.bondContribs[msg.sender] = 0;
        uint256 bonus;
        if (winning) {
            bonus = c.apContribTotLeft == 0 ? 0 : (c.apBonusPoolLeft * contrib) / c.apContribTotLeft;
            c.apBonusPoolLeft -= bonus;
            c.apContribTotLeft -= contrib;
        }

        uint256 amt = contrib + bonus;
        totalPendingPayout -= amt;
        address(token).safeTransfer(msg.sender, amt);
        emit PayoutClaimed(msg.sender, amt);
    }

    /// @notice The amount `who` can pull from a winning appeal contribution to
    ///         `caseId`, summed across winning rounds. Pristine (pre-pull) it
    ///         equals the exact pro-rata refund+bonus; it shrinks as pulls occur.
    function appealPayoutOwed(uint256 caseId, address who) external view returns (uint256 owed) {
        Case storage c = cases[caseId];
        if (c.phase != Phase.SETTLED) return 0;
        uint256 nRounds = c.rounds.length;
        for (uint256 d; d < nRounds; ++d) {
            Round storage r = c.rounds[d];
            if (!r.bondInPot) continue;
            bool winning = r.appealFor == c.finalOutcome;
            if (!winning && !r.bondRefundOnly) continue; // forfeited on the merits
            uint256 contrib = r.bondContribs[who];
            if (contrib == 0) continue;
            uint256 bonus = winning && c.apContribTotLeft != 0 ? (c.apBonusPoolLeft * contrib) / c.apContribTotLeft : 0;
            owed += contrib + bonus;
        }
    }

    /// @dev Index side effects at settlement (§8.1, §8.2). Writes happen only
    ///      here, on a final APPROVE — never provisionally at a depth-0 tally.
    function _settleIndex(Case storage c) internal {
        if (c.kind == Kind.SUBMISSION) {
            if (c.finalOutcome == Outcome.Approve) {
                _writeEntries(c); // dedup kept: content is now in the index
            } else if (c.finalOutcome == Outcome.Reject) {
                _clearDedup(c); // resubmittable
            }
        } else {
            // REMOVAL: APPROVE deletes the target's entries; REJECT keeps them.
            if (c.finalOutcome == Outcome.Approve) {
                _removeTarget(c);
            }
        }
    }

    function _writeEntries(Case storage c) internal {
        bool uncontested = _noRejectEver(c); // an appeal alone does not clear it (§8.1)
        bool fullQuorum = _fullQuorum(c);
        uint40 t = uint40(block.timestamp);
        uint256 n = c.topicKeys.length;
        for (uint256 i; i < n; ++i) {
            bytes32 topicKey = c.topicKeys[i];
            if (!topicSeen[topicKey]) {
                topicSeen[topicKey] = true;
                emit TopicCreated(topicKey);
            }
            indexByTopic[topicKey].push(
                Entry({
                    contentHash: c.contentHash,
                    metaHash: c.metaHash,
                    approvalTime: t,
                    uncontested: uncontested,
                    fullQuorum: fullQuorum,
                    caseId: c.id
                })
            );
            entryPosPlusOne[topicKey][c.id] = indexByTopic[topicKey].length; // 1-based position (H-03)
            emit EntryWritten(c.id, topicKey, uncontested);
        }
        c.isIndexed = true; // now live in the index (H-01 generation signal)
    }

    function _removeTarget(Case storage c) internal {
        Case storage target = cases[c.targetCaseId];
        // H-01: no-op if the target is no longer indexed (a concurrent removal
        // already deleted it). Bound to a specific caseId at submit, so this can
        // only ever delete the exact entries the removal was approved against.
        if (!target.isIndexed) return;
        uint256 n = target.topicKeys.length;
        for (uint256 i; i < n; ++i) {
            _deleteEntry(target.topicKeys[i], c.targetCaseId);
        }
        target.isIndexed = false;
        _clearDedup(target); // the removed submission is resubmittable
    }

    /// @dev O(1) swap-and-pop of the entry for `caseId` under `topicKey` via the
    ///      position map (H-03). No-op if absent (already removed): removal of a
    ///      missing entry settles cleanly (§10).
    function _deleteEntry(bytes32 topicKey, uint256 caseId) internal {
        uint256 p = entryPosPlusOne[topicKey][caseId];
        if (p == 0) return; // not present
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 idx = p - 1;
        uint256 last = arr.length - 1;
        if (idx != last) {
            Entry storage moved = arr[last];
            arr[idx] = moved;
            entryPosPlusOne[topicKey][moved.caseId] = idx + 1; // relocate the moved entry
        }
        arr.pop();
        delete entryPosPlusOne[topicKey][caseId];
        emit EntryRemoved(caseId, topicKey);
    }

    /// @dev uncontested iff no Reject vote was revealed in ANY round (§8.1).
    function _noRejectEver(Case storage c) internal view returns (bool) {
        uint256 n = c.rounds.length;
        for (uint256 d; d < n; ++d) {
            if (c.rounds[d].rejectSeats != 0) return false;
        }
        return true;
    }

    /// @dev H-09: a case is "full quorum" — the precondition for the supersafe
    ///      view — iff no round fell back to arming below MIN_REVEALS after max
    ///      widen, and the deciding (final) round drew at least MIN_REVEALS
    ///      *independent* revealers (addresses, not seats — one multi-seat voter
    ///      must not satisfy quorum alone).
    function _fullQuorum(Case storage c) internal view returns (bool) {
        uint256 n = c.rounds.length;
        for (uint256 d; d < n; ++d) {
            if (c.rounds[d].underQuorum) return false;
        }
        return c.rounds[c.depth].revealedCount >= _cp(c).minReveals;
    }

    function _freezeSlice(address a, uint256 amt, uint256 until) internal {
        Moderator storage m = moderators[a];
        m.committed -= amt;
        m.frozen += amt;
        totalCommittedStake -= amt;
        totalFrozenStake += amt;
        if (until > m.frozenUntil) m.frozenUntil = until;
        _syncTree(a, m);
    }

    function _coherent(Vote vote, Outcome finalOutcome) internal pure returns (bool) {
        return (vote == Vote.Approve && finalOutcome == Outcome.Approve)
            || (vote == Vote.Reject && finalOutcome == Outcome.Reject);
    }

    // --- internal transitions ------------------------------------------------

    function _openRound(Case storage c, uint256 depth) internal {
        c.rounds.push();
        Round storage r = c.rounds[c.rounds.length - 1];
        r.nSeats = _commitTarget(c, depth);
        r.seatSnapshotBlock = block.number + _cp(c).seedLag;
        r.outcome = Outcome.Unset;
        r.appealFor = Outcome.Unset;
        c.depth = depth;
        c.phase = Phase.DRAW;
        emit RoundOpened(c.id, depth, r.nSeats, r.seatSnapshotBlock);
    }

    function _toReveal(Case storage c) internal {
        c.phase = Phase.REVEAL;
        c.phaseDeadline = block.timestamp + _cp(c).revealWindow;
        emit RevealOpened(c.id, c.depth, c.phaseDeadline);
    }

    function _closeReveal(Case storage c) internal {
        Round storage r = _cur(c);
        uint256 reveals = r.revealedSeats;

        if (reveals >= _cp(c).minReveals) {
            _armOutcome(c, r);
            return;
        }
        // Under-participation: widen while retries remain.
        if (r.widenCount < _cp(c).maxWiden) {
            r.widenCount++;
            uint256 add = _commitTarget(c, c.depth);
            uint256 offset = r.seatDrawCount;
            bytes32 newSeed = keccak256(abi.encode(r.seatSeed, r.widenCount));
            r.seatSeed = newSeed;
            r.nSeats += add;
            _drawSeats(r, add, newSeed, offset);
            c.phase = Phase.COMMIT;
            c.phaseDeadline = block.timestamp + _cp(c).commitTimeout;
            emit Widened(c.id, c.depth, r.widenCount, r.nSeats);
            emit CommitOpened(c.id, c.depth, c.phaseDeadline);
            return;
        }
        // Widen exhausted with participation: proceed with the reveals we have
        // (a case that got participation should still yield an outcome), but mark
        // the round under-quorum so its approval can never reach the supersafe
        // view (H-09).
        if (reveals != 0) {
            r.underQuorum = true;
            _armOutcome(c, r);
            return;
        }
        // Zero reveals after the cap. At depth 0 there is no prior outcome, so
        // VOID. For an appeal round (depth > 0) the flip-bond was already funded
        // to reach this round, so instead of voiding the whole case the appeal
        // simply fails and the prior round's outcome stands (the forfeited bond
        // is settled in claim(), M2-5).
        if (c.depth == 0) {
            _void(c);
        } else {
            // The appeal round drew NO quorum after max widen: the adjudication
            // layer failed, the appeal did not lose on the merits. Restore the
            // prior outcome for liveness, but refund the funding bond's capital
            // (no bonus) instead of forfeiting it to the prior winners (H-10).
            Round storage prev = c.rounds[c.depth - 1];
            prev.bondRefundOnly = true;
            r.outcome = prev.outcome;
            c.finalOutcome = prev.outcome;
            c.phase = Phase.FINALIZED;
            emit Finalized(c.id, c.finalOutcome);
        }
    }

    function _armOutcome(Case storage c, Round storage r) internal {
        c.phase = Phase.TALLY;
        r.outcomeSnapshotBlock = block.number + _cp(c).seedLag;
        emit OutcomeArmed(c.id, c.depth, r.outcomeSnapshotBlock);
    }

    function _void(Case storage c) internal {
        c.phase = Phase.VOID;
        c.finalOutcome = Outcome.Void;

        // A VOID happens only on zero reveals after MAX_WIDEN, so every committer
        // in the round is a commit-and-vanish actor: each takes the §6.3 brief
        // freeze (committed -> frozen), never a free release. Otherwise a
        // coordinated panel could grief submissions to VOID at no cost.
        Round storage r = _cur(c);
        uint256 len = r.seatHolders.length;
        for (uint256 i; i < len; ++i) {
            address a = r.seatHolders[i];
            uint256 amt = r.committedAmt[a];
            if (amt > 0) {
                r.committedAmt[a] = 0;
                _freezeSlice(a, amt, block.timestamp + _cp(c).failedRevealFreeze);
            }
        }

        uint256 pot = c.pot;
        uint256 bounty = (pot * _cp(c).claimBountyFrac) / WAD;
        c.pot = 0;
        openPotsTotal -= pot;
        _clearDedup(c);

        if (bounty > 0) address(token).safeTransfer(msg.sender, bounty);
        address(token).safeTransfer(c.submitter, pot - bounty);
        emit Voided(c.id);
    }

    // --- internal helpers ----------------------------------------------------

    function _cur(Case storage c) internal view returns (Round storage) {
        return c.rounds[c.rounds.length - 1];
    }

    /// @dev H-06: bind randomness to (chain, contract, case, depth, purpose) so
    ///      no two draws share a seed derived from the same blockhash.
    function _domainSeed(uint256 caseId, uint256 depth, uint8 purpose, bytes32 entropy)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), caseId, depth, purpose, entropy));
    }

    function _drawSeats(Round storage r, uint256 count, bytes32 seed, uint256 offset) internal {
        for (uint256 i; i < count; ++i) {
            address seat = stakeTree.draw(uint256(keccak256(abi.encode(seed, offset + i))));
            if (r.seats[seat] == 0) r.seatHolders.push(seat);
            r.seats[seat] += 1;
        }
        r.seatDrawCount += count;
    }

    function _lockStake(address moderator, uint256 amount) internal {
        Moderator storage m = moderators[moderator];
        uint256 reserved = m.pending + m.exitAmount;
        uint256 eligible = m.free > reserved ? m.free - reserved : 0;
        if (eligible < amount) revert InsufficientEligibleFree();
        m.free -= amount;
        m.committed += amount;
        totalFreeStake -= amount;
        totalCommittedStake += amount;
        _syncTree(moderator, m);
    }

    function _clearDedup(Case storage c) internal {
        if (c.kind != Kind.SUBMISSION) return;
        uint256 len = c.topicKeys.length;
        for (uint256 i; i < len; ++i) {
            bytes32 k = _dedupKey(c.contentHash, c.metaHash, c.topicKeys[i]);
            // H-02: only the current owner may release its reservation, so a stale
            // case cannot wipe a key a newer resubmission now holds.
            if (dedupOwnerPlusOne[k] == c.id + 1) delete dedupOwnerPlusOne[k];
        }
    }

    function _dedupKey(bytes32 contentHash, bytes32 metaHash, bytes32 topicKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(contentHash, metaHash, topicKey));
    }

    /// @notice True iff the (content, meta, topic) triple is currently reserved.
    function submissionExists(bytes32 dedupKey) external view returns (bool) {
        return dedupOwnerPlusOne[dedupKey] != 0;
    }

    /// @notice The caseId currently holding a dedup reservation (reverts-free: 0
    ///         means unreserved; otherwise the owning caseId).
    function dedupOwner(bytes32 dedupKey) external view returns (uint256) {
        uint256 v = dedupOwnerPlusOne[dedupKey];
        return v == 0 ? 0 : v - 1;
    }

    /// @dev H-11: consensus params for a case come from its pinned ruleset.
    function _cp(Case storage c) internal view returns (Params storage) {
        return rulesets[c.rulesVersion].p;
    }

    function _commitTarget(Case storage c, uint256 depth) internal view returns (uint256) {
        uint256[] storage arr = rulesets[c.rulesVersion].commitTargets;
        uint256 len = arr.length;
        return arr[depth < len ? depth : len - 1];
    }

    function _appealWindow(Case storage c, uint256 depth) internal view returns (uint256) {
        uint256[] storage arr = rulesets[c.rulesVersion].appealWindows;
        uint256 len = arr.length;
        return arr[depth < len ? depth : len - 1];
    }

    function minFee(uint256 nTopics) public view returns (uint256) {
        return params.feeBase + params.feePerTopic * nTopics;
    }

    // --- case views ----------------------------------------------------------

    function caseInfo(uint256 caseId)
        external
        view
        returns (Kind kind, address submitter, Phase phase, uint256 depth, uint256 pot, uint256 phaseDeadline, Outcome finalOutcome)
    {
        Case storage c = cases[caseId];
        return (c.kind, c.submitter, c.phase, c.depth, c.pot, c.phaseDeadline, c.finalOutcome);
    }

    function roundInfo(uint256 caseId, uint256 depth)
        external
        view
        returns (
            uint256 nSeats,
            uint256 seatHolderCount,
            uint256 committedCount,
            uint256 revealedCount,
            uint256 approveSeats,
            uint256 rejectSeats,
            uint256 widenCount,
            Outcome outcome,
            uint256 seatSnapshotBlock,
            uint256 outcomeSnapshotBlock
        )
    {
        Round storage r = cases[caseId].rounds[depth];
        return (
            r.nSeats,
            r.seatHolders.length,
            r.committedCount,
            r.revealedCount,
            r.approveSeats,
            r.rejectSeats,
            r.widenCount,
            r.outcome,
            r.seatSnapshotBlock,
            r.outcomeSnapshotBlock
        );
    }

    function seatsOf(uint256 caseId, uint256 depth, address moderator) external view returns (uint256) {
        return cases[caseId].rounds[depth].seats[moderator];
    }

    function seatHolderAt(uint256 caseId, uint256 depth, uint256 i) external view returns (address) {
        return cases[caseId].rounds[depth].seatHolders[i];
    }

    function bondInfo(uint256 caseId, uint256 depth)
        external
        view
        returns (uint256 bond, Outcome appealFor, bool bondInPot)
    {
        Round storage r = cases[caseId].rounds[depth];
        return (r.bond, r.appealFor, r.bondInPot);
    }

    function bondContribOf(uint256 caseId, uint256 depth, address contributor) external view returns (uint256) {
        return cases[caseId].rounds[depth].bondContribs[contributor];
    }

    function appealFloor(uint256 caseId) external view returns (uint256) {
        return _cp(cases[caseId]).bondMultiplier * cases[caseId].pot;
    }

    // --- index views (§8.3) --------------------------------------------------

    /// Superset: number of current entries under a topic.
    function entryCount(bytes32 topicKey) external view returns (uint256) {
        return indexByTopic[topicKey].length;
    }

    function entryAt(bytes32 topicKey, uint256 i) external view returns (Entry memory) {
        return indexByTopic[topicKey][i];
    }

    /// Supersafe subset (§8.3): uncontested, full-quorum (H-09), and aged past
    /// SUPERSAFE_AGE.
    function supersafeEntries(bytes32 topicKey) external view returns (Entry[] memory out) {
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 len = arr.length;
        uint256 count;
        for (uint256 i; i < len; ++i) {
            if (_isSupersafe(arr[i])) count++;
        }
        out = new Entry[](count);
        uint256 j;
        for (uint256 i; i < len; ++i) {
            if (_isSupersafe(arr[i])) out[j++] = arr[i];
        }
    }

    function _isSupersafe(Entry storage e) internal view returns (bool) {
        return e.uncontested && e.fullQuorum && block.timestamp - e.approvalTime >= params.supersafeAge;
    }

    function caseGuidelinesVersion(uint256 caseId) external view returns (uint256) {
        return cases[caseId].guidelinesVersion;
    }

    // =========================================================================
    // Governance (§9.9, P6) — a multisig may change only the §1 numeric
    // parameters and append (never mutate) guidelines versions, both behind a
    // timelock. Core transitions (§3, §5) are code and have no mutation path, and
    // no function anywhere pauses withdrawals (§9.5).
    // =========================================================================

    event ParametersProposed(uint256 eta);
    event ParametersExecuted();
    event ParametersCancelled();
    event GuidelinesProposed(bytes32 hash, uint256 eta);
    event GuidelinesExecuted(uint256 indexed version, bytes32 hash);
    event GovernanceTransferred(address indexed newGovernance);

    error NotGovernance();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error BadParams();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    /// @notice Queue a full replacement of the numeric parameters (validated for
    ///         solvency/liveness sanity). Only these numbers are mutable.
    function proposeParameters(
        Params calldata p,
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
        PendingParams storage pp = pendingParams;
        if (!pp.exists) revert NoPendingProposal();
        if (block.timestamp < pp.eta) revert TimelockNotElapsed();
        params = pp.p;
        commitTargetByDepth = pp.commitTargets;
        appealWindowByDepth = pp.appealWindows;
        // H-11: seal a new immutable ruleset version; open cases keep their pinned
        // version, only cases submitted after this pick up the new rules.
        currentRulesVersion += 1;
        rulesets[currentRulesVersion] =
            Ruleset({p: pp.p, commitTargets: pp.commitTargets, appealWindows: pp.appealWindows});
        delete pendingParams;
        emit ParametersExecuted();
    }

    function cancelParameters() external onlyGovernance {
        delete pendingParams;
        emit ParametersCancelled();
    }

    /// @notice Queue a new guidelines version. Execution appends a new version
    ///         entry; existing versions are never overwritten (invariant 9).
    function proposeGuidelines(bytes32 hash) external onlyGovernance {
        pendingGuidelines = PendingGuidelines({eta: block.timestamp + timelockDelay, exists: true, hash: hash});
        emit GuidelinesProposed(hash, block.timestamp + timelockDelay);
    }

    function executeGuidelines() external onlyGovernance {
        PendingGuidelines storage pg = pendingGuidelines;
        if (!pg.exists) revert NoPendingProposal();
        if (block.timestamp < pg.eta) revert TimelockNotElapsed();
        guidelinesVersion += 1;
        guidelinesHashByVersion[guidelinesVersion] = pg.hash;
        emit GuidelinesExecuted(guidelinesVersion, pg.hash);
        delete pendingGuidelines;
    }

    function transferGovernance(address next) external onlyGovernance {
        governance = next;
        emit GovernanceTransferred(next);
    }

    function _validateParams(Params calldata p, uint256[] calldata commitTargets, uint256[] calldata appealWindows)
        internal
        pure
    {
        if (commitTargets.length == 0 || appealWindows.length == 0) revert BadParams();
        if (commitTargets.length > MAX_ARRAY_LEN || appealWindows.length > MAX_ARRAY_LEN) revert BadParams();
        if (p.minStake == 0 || p.riskPerSeat == 0) revert BadParams();
        if (p.minReveals == 0) revert BadParams();
        if (p.bondMultiplier == 0 || p.bondMultiplier > MAX_BOND_MULT) revert BadParams();
        if (p.freezeCap < WAD) revert BadParams(); // power multiplier >= 1
        if (p.trackDecay > WAD) revert BadParams(); // decay is a fraction
        if (p.claimBountyFrac + p.bonusFrac > WAD) revert BadParams(); // distributable stays >= 0

        // H-11: hard protocol caps + cross-field sanity so governance cannot brick
        // active or future cases.
        if (p.maxDepth > MAX_RULE_DEPTH || p.maxWiden > MAX_RULE_WIDEN) revert BadParams();
        if (p.maxTopics == 0 || p.maxTopics > MAX_RULE_TOPICS) revert BadParams();
        if (p.seedLag == 0 || p.seedLag > MAX_SEED_LAG) revert BadParams();
        if (p.commitTimeout == 0 || p.commitTimeout > MAX_WINDOW) revert BadParams();
        if (p.revealWindow == 0 || p.revealWindow > MAX_WINDOW) revert BadParams();
        if (p.activationDelay > MAX_WINDOW || p.exitCooldown > MAX_WINDOW) revert BadParams();
        if (p.failedRevealFreeze > MAX_FREEZE || p.freezeBase == 0 || p.freezeBase > MAX_FREEZE) revert BadParams();
        // minReveals must be reachable within the fully-widened depth-0 panel.
        if (p.minReveals > commitTargets[0] * (1 + p.maxWiden)) revert BadParams();

        uint256 totalDraws;
        for (uint256 i; i < commitTargets.length; ++i) {
            if (commitTargets[i] == 0 || commitTargets[i] > MAX_PANEL) revert BadParams();
            // every depth up to maxDepth can widen maxWiden times
            if (i <= p.maxDepth) totalDraws += (1 + p.maxWiden) * commitTargets[i];
        }
        for (uint256 i; i < appealWindows.length; ++i) {
            if (appealWindows[i] == 0 || appealWindows[i] > MAX_WINDOW) revert BadParams();
        }
        if (totalDraws > MAX_TOTAL_DRAWS) revert BadParams();
    }

    function pendingParamsEta() external view returns (uint256 eta, bool exists) {
        return (pendingParams.eta, pendingParams.exists);
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

    function getCommitTargets() external view returns (uint256[] memory) {
        return commitTargetByDepth;
    }

    function getAppealWindows() external view returns (uint256[] memory) {
        return appealWindowByDepth;
    }

    function commitTargetAt(uint256 depth) external view returns (uint256) {
        uint256 len = commitTargetByDepth.length;
        return commitTargetByDepth[depth < len ? depth : len - 1];
    }
}
