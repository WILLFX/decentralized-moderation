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

    /// WAD scale for fractional parameters (1e18 = 100%).
    uint256 internal constant WAD = 1e18;

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
    }

    Params internal params;

    /// COMMIT_TARGET[depth]: counted seats per depth (clamped to last at deeper).
    uint256[] internal commitTargetByDepth;
    /// APPEAL_WINDOW[depth]: appeal window duration per depth.
    uint256[] internal appealWindowByDepth;

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
            bonusFrac: WAD / 10 // 10%
        });
        commitTargetByDepth = [uint256(5), 11, 23, 47];
        appealWindowByDepth = [uint256(4 days), 3 days, 3 days, 3 days];
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
        mapping(address => uint256) seats; // seat-holder -> seat count
        mapping(address => bytes32) commits; // seat-holder -> commit hash
        mapping(address => Vote) reveals; // seat-holder -> revealed vote
        mapping(address => bool) committed; // has committed
        mapping(address => uint256) committedAmt; // stake locked by this seat-holder for this round
        uint256 committedCount; // # seat-holders committed
        uint256 revealedCount; // # committers revealed
        uint256 approveSeats; // Σ seats revealing Approve
        uint256 rejectSeats; // Σ seats revealing Reject
        uint256 revealedSeats; // approveSeats + rejectSeats
        Outcome outcome; // drawn ∝ seat counts
        Outcome appealFor; // the outcome an appeal against THIS round argues for
        uint256 bond; // flip-bond accumulated to appeal this round's outcome
        bool bondInPot; // true once the floor was met and the bond moved to the pot
        address[] bondContributors;
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
        Phase phase;
        uint256 depth;
        uint256 pot; // fee + appeal bonds moved in (§6.2)
        uint256 appealBondTotal; // Σ appeal bonds that met their floor and joined the pot
        uint256 phaseDeadline;
        Outcome finalOutcome;
        Round[] rounds; // one per depth reached
    }

    mapping(uint256 => Case) internal cases;
    uint256 public nextCaseId;
    uint256 public openPotsTotal; // Σ live case pots (§9.1)
    uint256 public totalPendingBond; // Σ appeal contributions collected but not yet flooring a round
    mapping(bytes32 => bool) public submissionExists; // dedup: H(content, meta, topicKey) (P3, §9.7)

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
        uint256 n = topicKeys.length;
        if (n == 0 || n > params.maxTopics) revert BadTopicCount();
        if (fee < minFee(n)) revert FeeTooLow();

        if (kind == Kind.SUBMISSION) {
            for (uint256 i; i < n; ++i) {
                if (submissionExists[_dedupKey(contentHash, metaHash, topicKeys[i])]) revert DuplicateSubmission();
            }
            for (uint256 i; i < n; ++i) {
                submissionExists[_dedupKey(contentHash, metaHash, topicKeys[i])] = true;
            }
        }

        address(token).safeTransferFrom(msg.sender, address(this), fee);

        caseId = nextCaseId++;
        Case storage c = cases[caseId];
        c.id = caseId;
        c.kind = kind;
        c.submitter = msg.sender;
        c.contentHash = contentHash;
        c.metaHash = metaHash;
        for (uint256 i; i < n; ++i) {
            c.topicKeys.push(topicKeys[i]);
        }
        c.targetCaseId = targetCaseId;
        c.pot = fee;
        openPotsTotal += fee;
        c.finalOutcome = Outcome.Unset;

        _openRound(c, 0);
        emit CaseSubmitted(caseId, kind, msg.sender, fee);
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
            r.seatSnapshotBlock = block.number + params.seedLag;
            emit SeedRearmed(caseId, c.depth, false, r.seatSnapshotBlock);
            return;
        }
        if (stakeTree.total() == 0) revert NoEligibleModerators();

        r.seatSeed = bh;
        _drawSeats(r, r.nSeats, bh, 0);

        c.phase = Phase.COMMIT;
        c.phaseDeadline = block.timestamp + params.commitTimeout;
        emit SeatsDrawn(caseId, c.depth, r.nSeats);
        emit CommitOpened(caseId, c.depth, c.phaseDeadline);
    }

    /// @notice Commit a hidden vote. Only a drawn seat-holder may commit, and
    ///         doing so locks RISK_PER_SEAT per seat from free -> committed (D5).
    function commitVote(uint256 caseId, bytes32 commitHash) external {
        Case storage c = cases[caseId];
        if (c.phase != Phase.COMMIT) revert WrongPhase();
        Round storage r = _cur(c);
        uint256 s = r.seats[msg.sender];
        if (s == 0) revert NotSeatHolder();
        if (r.committed[msg.sender]) revert AlreadyCommitted();

        uint256 lock = params.riskPerSeat * s;
        _lockStake(msg.sender, lock);
        r.committedAmt[msg.sender] = lock;
        r.commits[msg.sender] = commitHash;
        r.committed[msg.sender] = true;
        r.committedCount++;

        emit Committed(caseId, msg.sender, s);
        if (r.committedCount == r.seatHolders.length) _toReveal(c);
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
        if (vote != Vote.Approve && vote != Vote.Reject) revert BadVote();
        Round storage r = _cur(c);
        if (!r.committed[msg.sender]) revert NotCommitted();
        if (r.reveals[msg.sender] != Vote.None) revert AlreadyRevealed();
        if (keccak256(abi.encode(uint8(vote), salt)) != r.commits[msg.sender]) revert BadReveal();

        r.reveals[msg.sender] = vote;
        uint256 s = r.seats[msg.sender];
        if (vote == Vote.Approve) r.approveSeats += s;
        else r.rejectSeats += s;
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
            r.outcomeSnapshotBlock = block.number + params.seedLag;
            emit SeedRearmed(caseId, c.depth, true, r.outcomeSnapshotBlock);
            return;
        }
        r.outcomeSeed = bh;
        uint256 tot = r.approveSeats + r.rejectSeats; // >= 1 by construction
        uint256 rand = uint256(bh) % tot;
        r.outcome = rand < r.approveSeats ? Outcome.Approve : Outcome.Reject;

        c.phase = Phase.APPEAL_WINDOW;
        c.phaseDeadline = block.timestamp + _appealWindow(c.depth);
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
        if (c.depth >= params.maxDepth) revert AppealsClosed();
        if (block.timestamp >= c.phaseDeadline) revert AppealWindowClosed();

        Round storage r = _cur(c);
        if (r.appealFor == Outcome.Unset) r.appealFor = _opposite(r.outcome);

        uint256 floor = params.bondMultiplier * c.pot;
        uint256 room = floor - r.bond;
        if (room == 0) revert AppealAlreadyFull();
        accepted = amount < room ? amount : room;

        address(token).safeTransferFrom(msg.sender, address(this), accepted);
        if (r.bondContribs[msg.sender] == 0) r.bondContributors.push(msg.sender);
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
        if (c.phase != Phase.FINALIZED && c.phase != Phase.SETTLED && c.phase != Phase.VOID) {
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

    // --- internal transitions ------------------------------------------------

    function _openRound(Case storage c, uint256 depth) internal {
        c.rounds.push();
        Round storage r = c.rounds[c.rounds.length - 1];
        r.nSeats = _commitTarget(depth);
        r.seatSnapshotBlock = block.number + params.seedLag;
        r.outcome = Outcome.Unset;
        r.appealFor = Outcome.Unset;
        c.depth = depth;
        c.phase = Phase.DRAW;
        emit RoundOpened(c.id, depth, r.nSeats, r.seatSnapshotBlock);
    }

    function _toReveal(Case storage c) internal {
        c.phase = Phase.REVEAL;
        c.phaseDeadline = block.timestamp + params.revealWindow;
        emit RevealOpened(c.id, c.depth, c.phaseDeadline);
    }

    function _closeReveal(Case storage c) internal {
        Round storage r = _cur(c);
        uint256 reveals = r.revealedSeats;

        if (reveals >= params.minReveals) {
            _armOutcome(c, r);
            return;
        }
        // Under-participation: widen while retries remain.
        if (r.widenCount < params.maxWiden) {
            r.widenCount++;
            uint256 add = _commitTarget(c.depth);
            uint256 offset = r.seatDrawCount;
            bytes32 newSeed = keccak256(abi.encode(r.seatSeed, r.widenCount));
            r.seatSeed = newSeed;
            r.nSeats += add;
            _drawSeats(r, add, newSeed, offset);
            c.phase = Phase.COMMIT;
            c.phaseDeadline = block.timestamp + params.commitTimeout;
            emit Widened(c.id, c.depth, r.widenCount, r.nSeats);
            emit CommitOpened(c.id, c.depth, c.phaseDeadline);
            return;
        }
        // Widen exhausted with participation: proceed with the reveals we have
        // (a case that got participation should still yield an outcome).
        if (reveals != 0) {
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
            Round storage prev = c.rounds[c.depth - 1];
            r.outcome = prev.outcome;
            c.finalOutcome = prev.outcome;
            c.phase = Phase.FINALIZED;
            emit Finalized(c.id, c.finalOutcome);
        }
    }

    function _armOutcome(Case storage c, Round storage r) internal {
        c.phase = Phase.TALLY;
        r.outcomeSnapshotBlock = block.number + params.seedLag;
        emit OutcomeArmed(c.id, c.depth, r.outcomeSnapshotBlock);
    }

    function _void(Case storage c) internal {
        c.phase = Phase.VOID;
        c.finalOutcome = Outcome.Void;
        _releaseRound(_cur(c)); // return committed stake (brief-freeze refinement: M2-5)

        uint256 pot = c.pot;
        uint256 bounty = (pot * params.claimBountyFrac) / WAD;
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

    function _releaseRound(Round storage r) internal {
        uint256 len = r.seatHolders.length;
        for (uint256 i; i < len; ++i) {
            address a = r.seatHolders[i];
            uint256 amt = r.committedAmt[a];
            if (amt > 0) {
                r.committedAmt[a] = 0;
                Moderator storage m = moderators[a];
                m.committed -= amt;
                m.free += amt;
                totalCommittedStake -= amt;
                totalFreeStake += amt;
                _syncTree(a, m);
            }
        }
    }

    function _clearDedup(Case storage c) internal {
        if (c.kind != Kind.SUBMISSION) return;
        uint256 len = c.topicKeys.length;
        for (uint256 i; i < len; ++i) {
            delete submissionExists[_dedupKey(c.contentHash, c.metaHash, c.topicKeys[i])];
        }
    }

    function _dedupKey(bytes32 contentHash, bytes32 metaHash, bytes32 topicKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(contentHash, metaHash, topicKey));
    }

    function _commitTarget(uint256 depth) internal view returns (uint256) {
        uint256 len = commitTargetByDepth.length;
        return commitTargetByDepth[depth < len ? depth : len - 1];
    }

    function _appealWindow(uint256 depth) internal view returns (uint256) {
        uint256 len = appealWindowByDepth.length;
        return appealWindowByDepth[depth < len ? depth : len - 1];
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
        return params.bondMultiplier * cases[caseId].pot;
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
