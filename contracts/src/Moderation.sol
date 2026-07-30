// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FreezeMath} from "./lib/FreezeMath.sol";
import {StakeRegistry} from "./StakeRegistry.sol";
import {IndexRegistry} from "./IndexRegistry.sol";
import {ProtocolLimits as L} from "./lib/ProtocolLimits.sol";
import {Settlement} from "./lib/Settlement.sol";

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
    using SafeTransferLib for address;

    // --- units ---------------------------------------------------------------

    /// One xBZZ in base units. Swarm BZZ / Gnosis xBZZ uses 16 decimals.
    uint256 internal constant XBZZ = 1e16;

    // --- parameters (§1 working values; governance-settable in M2-7) ---------

    /// WAD scale for fractional parameters (1e18 = 100%).
    uint256 internal constant WAD = L.WAD;
    // H-06: randomness domain-separation purpose tags.
    uint8 internal constant SEED_SEATS = 1;
    uint8 internal constant SEED_OUTCOME = 2;
    /// M2.6-P0-3: blocks guaranteed available, after a seed's snapshot block, for a
    /// permissionless poke to realize it inside the same eligibility epoch. Beyond
    /// this the window may be abandoned and re-armed into a later epoch.
    uint256 internal constant REALIZE_SLACK = 64;
    /// M2.6-P1-2: seats drawn per `realizeSeats` call. `realizeSeats` used to
    /// attempt a whole commit target in one transaction, which made the panel-size
    /// cap nothing more than the block limit divided by the per-seat cost — and
    /// that cost rose three times in M2.6 (escrow, staged weight, obligation
    /// handle), taking a cap-sized panel to 90% of the ceiling.
    uint256 internal constant DRAW_SEATS_PER_BATCH = 24;
    /// M2.6-P0-3b: staged eligibility changes applied per `realizeSeats` poke when
    /// the epoch is not yet settled. Sized from measurement, like the seat batch:
    /// see `GasBounds.t.sol::test_realize_seats_epoch_drain_batch_is_under_ceiling`,
    /// which asserts a full batch against the 8M single-transaction ceiling on the
    /// worst tree the suite builds. A drained item costs one weight recompute plus
    /// one O(log n) sortition-tree update, so this is the number that has to move if
    /// the moderator set grows by orders of magnitude — not `DRAW_SEATS_PER_BATCH`.
    uint256 internal constant EPOCH_DRAIN_STEPS = 128;
    // H-11: the immutable protocol caps live in `ProtocolLimits` (M2.6), shared
    // with `RulesetGovernor` — the contract that validates a ruleset and the
    // contract that enforces it must read the same numbers.

    // NOTE: MIN_STAKE, ACTIVATION_DELAY and EXIT_COOLDOWN are deliberately absent.
    // They govern the custody path, which is StakeRegistry's, and are set at its
    // construction. Mirroring them here would let governance "change" a number
    // that nothing reads — the withdrawal that actually honours a cooldown is the
    // registry's, and it must stay beyond this contract's reach (trust model #2).
    struct Params {
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

    /// M2.6: ruleset AUTHORING (propose / validate / timelock / execute) lives in
    /// `RulesetGovernor`. Immutable, so this contract's trust surface is exactly
    /// what the `governance` multisig held before the split. The ruleset STORAGE
    /// stays here deliberately — `_cp()` reads it on every hot path, and putting
    /// it behind a call would cost more than the split saved.
    address public immutable governor;
    uint256 public guidelinesVersion; // current guidelines version
    mapping(uint256 => bytes32) public guidelinesHashByVersion; // append-only history (invariant 9)

    // --- accounting ----------------------------------------------------------

    IERC20 public immutable token;

    /// Custody + bookkeeping for moderator stake (M2.5-P0-b). Stake lives there
    /// permanently so this contract — the replaceable *game* — can be redeployed
    /// without every moderator having to withdraw and re-stake.
    StakeRegistry public immutable stakeReg;
    /// The topic -> approved-entries index, likewise outliving this contract.
    IndexRegistry public immutable indexReg;

    // --- errors --------------------------------------------------------------

    error AmountZero();

    // -------------------------------------------------------------------------

    constructor(IERC20 _token, StakeRegistry _stakeReg, IndexRegistry _indexReg, address _governor) {
        if (_governor == address(0)) revert ZeroGovernor();
        governor = _governor;
        token = _token;
        stakeReg = _stakeReg;
        indexReg = _indexReg;
        params = Params({
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
        // Ruleset 0 never goes through _validateParams, so the seat-collateral
        // bound is enforced here too: a deployment pointed at a registry whose
        // duty unit is smaller than this contract's per-seat lock would seat
        // panels on collateral that cannot cover them, from the very first case.
        if (params.riskPerSeat > _stakeReg.riskPerSeat()) revert RiskPerSeatExceedsDutyUnit();
        rulesets[0] = Ruleset({p: params, commitTargets: commitTargetByDepth, appealWindows: appealWindowByDepth});

    }

    // --- staking (§3) --------------------------------------------------------
    //
    // Deliberately absent. Stake deposit, activation, exit, withdrawal, thaw and
    // the H-07 duty pledge all live on StakeRegistry and are called there by the
    // moderator directly (M2.5-P0-b). Routing them through this contract would
    // put the game back in the custody path and re-create the very coupling the
    // split exists to remove: exit must never be gated by logic, so logic must
    // not sit between a moderator and its own stake.
    //
    // What remains here is the narrow privileged API this contract is authorized
    // to call: lock / release / freeze / reward / setTrack / drawPanel /
    // settleDuty / advanceEpoch, plus openCase / closeCase / writeEntry /
    // deleteEntry / tryReserveContent / releaseContent on the index registry.
    //
    // `releaseDuty` and `penalizeNoShow` are gone — folded into and superseded by
    // `settleDuty`, which discharges a case's seats in one obligation-scoped step
    // (M2.6-P0-2, P0-5a, and the deletion in P0-5c). This list is the whole
    // privileged surface; if it grows, the trust model in each registry's header
    // is what has to be re-argued.


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
        SETTLED,
        // M2.6-P0-7: VOID disposal in progress across batched claim() calls. A
        // separate phase from SETTLING because the two dispose seats differently
        // — SETTLING pays coherent voters, VOID freezes every committer — and
        // collapsing them would make the settle loop branch per seat.
        VOID_SETTLING
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
        uint256 nSeats; // seats ACTUALLY seated so far this round (grows on widen; may fall short of the commit target when pledged duty capacity is scarce)
        uint256 seatDrawCount; // total seat draws performed (offset base for widen draws)
        uint256 widenCount; // widen re-draws used
        uint256 pendingDraw; // H-05: seats still to be drawn for this round (fresh entropy per draw, incl. each widen)
        uint256 epochAtArm; // H-05/P0-3: the eligibility epoch this seed belongs to
        // M2.6-P0-5: this round's obligation reference in the stake registry,
        // `(caseId << 8) | depth`. Stored once at open rather than threaded
        // through every settlement helper — the settle loop is already at the IR
        // stack limit, and a round always knows which round it is.
        uint256 caseRef;
        uint256 seatSnapshotBlock; // block whose blockhash seeds the seat draw
        uint256 outcomeSnapshotBlock; // block whose blockhash seeds the outcome draw
        bytes32 seatSeed;
        bytes32 outcomeSeed;
        address[] seatHolders; // unique drawn addresses
        mapping(address => uint256) seats; // seat-holder -> seat count (may grow on widen)
        mapping(address => uint256) committedSeats; // H-08: seats collateralized at commit (tally is capped to this)
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
        // M2.6-P0-1: the registry mints a permanent global id per written entry.
        // A local caseId is NOT a safe index handle — it restarts at 0 in every new
        // logic deployment — so we record what the registry actually issued and
        // remove by that. Parallel to topicKeys.
        uint256[] entryIds;
        // M2.6-P0-1c: for a removal aimed at an entry THIS logic did not write,
        // the registry-minted id of that entry. 0 means "not a legacy removal" —
        // safe as a sentinel because the registry mints from 1.
        uint256 legacyEntryId;
        // M2.6-P0-6: this round's draw was abandoned because the network had no
        // drawable capacity before the deadline. Seat-holders that WERE seated get
        // their duty released without a no-show penalty — they never reached a
        // COMMIT phase, so there was nothing for them to fail to do.
        bool drawAbandoned;
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
    /// M2.6: the four money scalars, grouped so the settlement library can take a
    /// storage pointer to them — a `uint256` cannot be passed by storage reference,
    /// and marshalling them individually across the seam costs more than the split
    /// saves. Field order is unchanged, so each still occupies the slot it did as a
    /// standalone variable and the layout is byte-identical.
    ///
    /// The four public getters below preserve the external ABI exactly. Nothing
    /// outside this contract, including the whole test suite, sees the change.
    struct Money {
        uint256 openPotsTotal; // Σ live case pots (§9.1)
        uint256 totalPendingBond; // Σ appeal contributions collected but not yet flooring a round
        uint256 totalPendingPayout; // Σ settled bond refunds + bonuses awaiting pull (per (case,depth), pulled via claimAppealPayout)
        uint256 totalSettling; // H-04: pot value in flight during batched settlement (rewards not yet credited + unpaid bounty); 0 outside an in-progress claim
    }

    Money internal money;

    function openPotsTotal() external view returns (uint256) {
        return money.openPotsTotal;
    }

    function totalPendingBond() external view returns (uint256) {
        return money.totalPendingBond;
    }

    function totalPendingPayout() external view returns (uint256) {
        return money.totalPendingPayout;
    }

    function totalSettling() external view returns (uint256) {
        return money.totalSettling;
    }

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
    // Dedup (P3, §9.7) now lives in IndexRegistry (M2.6-P0-1b). Held here, the
    // reservation map died with the logic contract: a replacement started empty
    // and happily re-indexed content already live in the permanent index. The
    // registry keys it by (logic, caseId), so H-02 ownership survives migration
    // rather than restarting. The views below forward, keeping the M2 ABI.

    // --- index (§8, README 3.8) ----------------------------------------------
    //
    // The topic -> approved-entries index lives in IndexRegistry (M2.5-P0-b).
    // It is the protocol's actual product, and it outlives this contract: if it
    // were held here, every logic redeployment would throw away every approval
    // ever made. Writes and deletions happen through the registry's logic-facing
    // API; the views below forward so the M2 ABI keeps working.
    //
    // `Case.isIndexed` deliberately stays on the case (H-01): it is the removal
    // generation signal and must not depend on iterating a topic.

    // --- case events ---------------------------------------------------------

    event CaseSubmitted(uint256 indexed caseId, Kind kind, address indexed submitter, uint256 fee);
    event RoundOpened(uint256 indexed caseId, uint256 indexed depth, uint256 nSeats, uint256 seatSnapshotBlock);
    /// M2.6-P1-2: a seat-draw batch landed but the panel is not full yet.
    event SeatsProgressed(uint256 indexed caseId, uint256 indexed depth, uint256 seated, uint256 remaining);
    event SeedRearmed(uint256 indexed caseId, uint256 indexed depth, bool outcomeSeed, uint256 newSnapshotBlock);
    event SeatsDrawn(uint256 indexed caseId, uint256 indexed depth, uint256 nSeats);
    /// M2.6-P0-3b: this poke spent itself applying staged eligibility changes
    /// instead of drawing. Poke again; the progress is committed.
    event EpochDraining(uint256 indexed caseId, uint256 appliedEpoch);
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
    /// M2.6-P0-7: VOID disposal opened; `participants` batches remain to drain.
    event VoidOpened(uint256 indexed caseId, uint256 participants);
    /// M2.6-P0-6: a draw was abandoned for want of network capacity.
    event DrawAbandoned(uint256 indexed caseId, uint256 indexed depth, uint256 seated);
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
    error PhaseDeadlineNotPassed(); // M2.6-P0-6: the draw may still complete
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
    error NotAcceptingSubmissions(); // M2.6-P0-5: retired or revoked; settle-only

    event RemovalTargeted(
        uint256 indexed caseId,
        uint256 indexed targetCaseId,
        bytes32 contentHash,
        bytes32 metaHash,
        uint256 topicCount
    );

    /// M2.6-P0-1c: a removal aimed at an entry a superseded logic wrote. Separate
    /// from `RemovalTargeted` because the target is a permanent registry id, not a
    /// local case id — indexers must not conflate the two number spaces.
    event LegacyRemovalTargeted(
        uint256 indexed caseId,
        uint256 indexed globalEntryId,
        address indexed originLogic,
        bytes32 topicKey,
        bytes32 contentHash,
        bytes32 metaHash
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
        _requireOpen(); // M2.6-P0-5
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
            // This case owns the reservation, in the registry that outlives us.
            // M2.6-P0-1b: the registry refuses content already live in the
            // PERMANENT index, even when this logic contract has never seen it.
            if (!indexReg.tryReserveContent(_dedupKey(contentHash, metaHash, topicKeys[i]), caseId)) {
                revert DuplicateSubmission();
            }
        }
        c.guidelinesVersion = guidelinesVersion; // pinned at submit; never changes (§9.6)
        c.rulesVersion = currentRulesVersion; // H-11: pin the consensus ruleset
        c.pot = fee;
        money.openPotsTotal += fee;
        c.finalOutcome = Outcome.Unset;
        // M2.6-P0-5b: this case can still write to the index, so the index must
        // refuse to revoke us until it settles.
        indexReg.openCase(caseId);

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
        _requireOpen(); // M2.6-P0-5
        if (targetCaseId >= nextCaseId) revert TargetNotRemovable();
        Case storage target = cases[targetCaseId];
        if (target.kind != Kind.SUBMISSION || target.phase != Phase.SETTLED) revert TargetNotRemovable();
        if (target.finalOutcome != Outcome.Approve || !target.isIndexed) revert TargetNotRemovable();

        uint256 n = target.topicKeys.length;
        // Derived from the bound target so client-displayed payload == settled action.
        Case storage c;
        (caseId, c) = _openRemoval(target.contentHash, target.metaHash, n, fee);
        for (uint256 i; i < n; ++i) {
            c.topicKeys.push(target.topicKeys[i]);
        }
        c.targetCaseId = targetCaseId;

        _openRound(c, 0);
        emit CaseSubmitted(caseId, Kind.REMOVAL, msg.sender, fee);
        emit RemovalTargeted(caseId, targetCaseId, target.contentHash, target.metaHash, n);
    }

    /// @dev The half of removal-case creation that does not depend on how the
    ///      target was addressed: charge the fee and lay down the case record.
    ///      Shared by the local (`targetCaseId`) and legacy (`globalEntryId`)
    ///      routes so the two cannot drift apart in what they pin — `Moderation`
    ///      is EIP-170-bound, so a second near-copy of this block is not affordable.
    ///      The caller pushes topic keys, sets its own target field, opens round 0
    ///      and emits its own targeting event.
    function _openRemoval(bytes32 contentHash, bytes32 metaHash, uint256 nTopics, uint256 fee)
        internal
        returns (uint256 caseId, Case storage c)
    {
        if (fee < minFee(nTopics)) revert FeeTooLow();
        address(token).safeTransferFrom(msg.sender, address(this), fee);

        caseId = nextCaseId++;
        c = cases[caseId];
        c.id = caseId;
        c.kind = Kind.REMOVAL;
        c.submitter = msg.sender;
        c.contentHash = contentHash;
        c.metaHash = metaHash;
        c.guidelinesVersion = guidelinesVersion;
        c.rulesVersion = currentRulesVersion; // H-11
        c.pot = fee;
        money.openPotsTotal += fee;
        c.finalOutcome = Outcome.Unset;
        // M2.6-P0-5b: a removal takes no content reservation but still DELETES at
        // settlement, which is why the index obligation is per case rather than per
        // reservation.
        indexReg.openCase(caseId);
    }

    /// @notice Open a REMOVAL case against an index entry written by a SUPERSEDED
    ///         logic contract (M2.6-P0-1c), addressed by its permanent registry id.
    ///
    ///         `submitRemoval` resolves its target through this contract's own
    ///         `cases[targetCaseId]`, which a replacement logic does not have: the
    ///         case record stayed behind in the contract that was replaced. The
    ///         registry has permitted cross-version deletion since P0-1a, but no
    ///         public path reached it, so every entry inherited from a previous
    ///         version was permanently unadjudicable — the index could grow but
    ///         never be corrected across an upgrade, which defeats the point of
    ///         making the index outlive the game.
    ///
    ///         Payload and topic are read from the registry, never from the caller,
    ///         so what a client displays is what settlement acts on (H-01). One
    ///         entry per case: entries are independent index memberships, and a
    ///         legacy submission's other topics are addressed by their own ids.
    ///
    ///         Entries written by THIS logic are rejected here — they have a case
    ///         record, so they go through `submitRemoval`, which binds the whole
    ///         submission. Keeping the two disjoint stops a removal from being
    ///         opened by a route that cannot maintain `isIndexed` on the target.
    function submitLegacyRemoval(uint256 globalEntryId, uint256 fee)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        _requireOpen(); // M2.6-P0-5
        (bytes32 topicKey, bytes32 contentHash, bytes32 metaHash, address originLogic) =
            indexReg.legacyEntryInfo(globalEntryId);
        // topicKey == 0 means the id is not live: never minted, or already removed.
        if (topicKey == bytes32(0) || originLogic == address(this)) revert TargetNotRemovable();

        Case storage c;
        (caseId, c) = _openRemoval(contentHash, metaHash, 1, fee);
        c.topicKeys.push(topicKey);
        c.legacyEntryId = globalEntryId;

        _openRound(c, 0);
        emit CaseSubmitted(caseId, Kind.REMOVAL, msg.sender, fee);
        emit LegacyRemovalTargeted(caseId, globalEntryId, originLogic, topicKey, contentHash, metaHash);
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

        // M2.6-P0-3b: the registry refuses to sample an epoch whose staged weight
        // changes are not all applied. Drain toward that and RETURN rather than
        // letting the draw revert — a revert would unwind the drain with it, and an
        // epoch that stages more than one batch could then never complete, halting
        // every draw in the protocol until an external keeper intervened. Returning
        // commits the progress, so repeated pokes of this same function recover on
        // their own. Nothing below this point has run yet, so nothing is discarded.
        if (!stakeReg.epochSettled()) {
            stakeReg.advanceEpoch(EPOCH_DRAIN_STEPS);
            emit EpochDraining(caseId, stakeReg.appliedEpoch());
            return;
        }

        bytes32 bh = blockhash(r.seatSnapshotBlock);
        // Re-arm if the blockhash has aged out of the 256-block window (D4), or if
        // this seed's epoch has passed — nobody poked in time, so the window it was
        // armed for no longer exists and the eligible set has moved on.
        //
        // M2.6-P0-3: there is deliberately NO "did eligibility change?" branch here
        // any more. `eligibilityAddVersion` was that branch, and it was both
        // griefable (any pledged moderator could re-arm every pending case forever
        // with a no-op `setDutyUnits`) and incomplete (`release`, `reward` and
        // `releaseDuty` all grew the drawable set and never bumped it). Eligibility
        // is now constant across the window by construction, so there is no change
        // that could occur for this branch to detect.
        // M2.6-P1-2: the draw is now multi-transaction, so be explicit about what
        // a later batch may and may not depend on.
        //
        // PINNED for the whole batch group: `seatSnapshotBlock` (the entropy
        // source), `epochAtArm` (the eligible set), and `pendingDraw` (the target
        // fixed when the round opened). The seed is recomputed from those pinned
        // inputs each batch and is therefore identical across them; batches differ
        // only in `seatDrawCount`, the cursor.
        //
        // A later batch READS the live moderator struct for capacity and escrow —
        // that is required by P0-2, where the struct is the authority for what may
        // be seated — and the sortition tree, which P0-3 holds constant for the
        // whole epoch. It does NOT read a re-derived seed, a re-armed block, or a
        // changed eligible set.
        //
        // So observing partial seating buys nothing: the remainder is already
        // determined by (pinned seed, cursor) over a tree that cannot move, and
        // every weight change an observer might make is staged to the next epoch.
        // The one thing an observer CAN still do is consume a specific moderator's
        // pledged capacity by drawing it into another case first, which changes
        // whether that address is *accepted* rather than whether it is *drawn*.
        // That is the pre-existing capacity-depletion property (work order P2),
        // now reachable within one case's draw as well as between cases; it costs
        // the attacker a real fee and a random panel of its own.
        //
        // Re-arm when the blockhash has aged out of the 256-block window (D4) or
        // the arm epoch has passed. Seats already drawn KEEP their seats and their
        // escrow, and only the remainder re-arms: its new seed's entropy is not
        // public at the moment it is armed, so the H-05 property holds for that
        // group too. Continuing a half-drawn panel on a stale seed across an epoch
        // boundary is what would break it — that is precisely the case this
        // branch refuses.
        if (bh == 0 || stakeReg.currentEpoch() != r.epochAtArm) {
            _armSeed(c, r);
            emit SeedRearmed(caseId, c.depth, false, r.seatSnapshotBlock);
            return;
        }
        if (stakeReg.totalEligibleWeight() == 0) revert NoEligibleModerators();

        // H-06: domain-separate the raw blockhash so two cases snapshotting the
        // same block (or the same case at different depths) never draw identical
        // panels. The purpose tag keeps seat vs outcome entropy independent.
        // Recomputed identically each batch from pinned inputs.
        r.seatSeed = _domainSeed(caseId, c.depth, SEED_SEATS, bh);

        // M2.6-P1-2: draw at most DRAW_SEATS_PER_BATCH seats per call, on the
        // batched-settlement template (bounded steps + a cursor). `seatDrawCount`
        // IS the cursor: it counts every draw attempt the registry has performed
        // for this round, so successive batches consume disjoint segments of one
        // deterministic sequence and never re-draw the same offset.
        uint256 want = r.pendingDraw;
        uint256 take = want > DRAW_SEATS_PER_BATCH ? DRAW_SEATS_PER_BATCH : want;
        uint256 before = r.nSeats;
        _drawSeats(r, take, r.seatSeed, r.seatDrawCount);
        uint256 seated = r.nSeats - before;
        r.pendingDraw = want - seated;

        // A batch that seated nobody means pledged capacity is exhausted for this
        // epoch — it cannot grow again inside one (P0-3 stages every increase to
        // the next boundary), so continuing would only burn attempts. Seat the
        // short panel and let the widen path do its job.
        if (r.pendingDraw != 0 && seated != 0) {
            emit SeatsProgressed(caseId, c.depth, r.nSeats, r.pendingDraw);
            return;
        }
        r.pendingDraw = 0;

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

        // H-07: seats are drawn stake-weighted WITH REPLACEMENT, so a moderator can
        // win more seats than its free stake can collateralize (a min-stake holder
        // drawn twice, a holder selected by several concurrent cases, or one whose
        // stake was reserved for exit after selection). Requiring the full
        // riskPerSeat x seats made commitVote revert outright — the moderator could
        // not serve even ONE of its seats, and a panel of such holders could never
        // reach quorum. Commit as many seats as the moderator can actually back;
        // the rest are simply not collateralized and (via H-08) never tallied.
        uint256 riskPerSeat = _cp(c).riskPerSeat;
        // M2.6-P0-2: the collateral for these seats was ESCROWED at draw time, so
        // it is in `dutyBonded` and no longer in `free`. Counting only free stake
        // here would reintroduce the exact H-07 liveness failure the partial-commit
        // path exists to prevent — a moderator whose whole stake is bonded to its
        // own assignments would compute `affordable == 0` and be unable to commit
        // the seat it had already posted collateral for.
        uint256 affordable = (_eligibleFreeOf(msg.sender) + stakeReg.dutyBondedOf(msg.sender)) / riskPerSeat;
        if (affordable == 0) revert InsufficientEligibleFree();
        // The clamp survives as the guard it always was, but P0-2 made it
        // NON-BINDING for any seat obtained through `drawPanel`, which is every
        // production seat: the registry escrows its own `riskPerSeat` per seat at
        // draw time into THIS case's obligation, that escrow can only be spent by
        // this case's `lock` or its `settleDuty`, and a ruleset may never lock more
        // per seat than the registry's unit (constructor + `_validateParams`). So
        // `dutyBonded >= s * regRisk >= s * caseRisk` and `affordable >= s` always.
        //
        // M2.6-P0-2b: the `unbackedSeats` counter that recorded the shortfall is
        // therefore gone rather than kept as defence in depth. It could only ever
        // be non-zero via `__injectWidenSeats`, a test harness that writes
        // `r.seats` without going through the registry, and unreachable code that
        // settlement branches on is a false statement about the system —
        // specifically, it read as evidence that widen seats are unbacked, which
        // is what put the wrong description into P1-1.
        if (affordable < s) s = affordable;

        uint256 lock = riskPerSeat * s;
        stakeReg.lock(msg.sender, r.caseRef, lock);
        r.committedAmt[msg.sender] = lock;
        r.committedSeats[msg.sender] = s; // H-08: only these seats are collateralized
        r.commits[msg.sender] = commitHash;
        r.committed[msg.sender] = true;
        r.committedCount++;

        emit Committed(caseId, msg.sender, s);
        if (r.committedCount == r.seatHolders.length) _toReveal(c);
    }

    /// @notice End a case whose draw can never complete (M2.6-P0-6).
    ///
    ///         `realizeSeats` reverts `NoEligibleModerators` when the network has
    ///         no drawable capacity, and a case could sit in DRAW on that revert
    ///         indefinitely — its fee taken, its own duty reservations helping keep
    ///         the tree empty, and no autonomous path out. A case opened when no
    ///         capacity existed at all was in the same position from the start.
    ///
    ///         P1-2 already closed the PARTIAL-capacity half: a batch that seats
    ///         nobody ends the draw and seats a short panel, so under-participation
    ///         proceeds through widen as designed. This closes the ZERO-capacity
    ///         half, which that could not reach.
    ///
    ///         Permissionless and deadline-gated, so the end state is reachable by
    ///         anyone rather than depending on the submitter or on governance.
    function resolveStalledDraw(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        if (c.phase != Phase.DRAW) revert WrongPhase();
        if (block.timestamp < c.phaseDeadline) revert PhaseDeadlineNotPassed();

        c.drawAbandoned = true;
        emit DrawAbandoned(caseId, c.depth, _cur(c).nSeats);
        if (c.depth == 0) {
            // No prior outcome to fall back to: VOID and refund the submitter.
            _void(c);
        } else {
            // The appeal layer failed to adjudicate; the prior outcome stands and
            // the funding bond's capital is refunded.
            _failAppealRound(c, _cur(c));
        }
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
        // Tally is capped to the seats collateralized at commit (H-08): a widen can
        // add seats to r.seats[voter] AFTER commit, but those are uncollateralized,
        // so they must not be tallied, rewarded, or mean-track weighted. Combined
        // with the reveal-time freeze this keeps talliedSeats*riskPerSeat <=
        // committedAmt (F2 + H-08).
        uint256 s = r.seats[msg.sender];
        uint256 cs = r.committedSeats[msg.sender];
        if (s > cs) s = cs;
        r.talliedSeats[msg.sender] = s;
        uint256 trackContrib = s * stakeReg.trackOf(msg.sender); // snapshot track now (M-03)
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
        money.totalPendingBond += accepted;
        emit AppealBondContributed(caseId, c.depth, msg.sender, accepted, r.bond);

        if (r.bond == floor) {
            // Floor met: the bond joins the pot and a fresh round opens at the
            // next depth, arguing for the flipped outcome.
            uint256 fromDepth = c.depth;
            money.totalPendingBond -= r.bond;
            c.pot += r.bond;
            money.openPotsTotal += r.bond;
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
        money.totalPendingBond -= amt;
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
        // M2.6-P0-7: a voided case drains through the same permissionless keeper
        // entry point, so clients and keepers have one poke to call.
        if (c.phase == Phase.VOID_SETTLING) {
            Settlement.settleVoid(c, settleState[c.id], money, _cp(c), Settlement.Ext(token, stakeReg, indexReg), maxSteps);
            return;
        }
        if (c.phase != Phase.FINALIZED && c.phase != Phase.SETTLING) revert CaseNotFinalized();

        // M2.6: the whole settlement block — init, the per-seat disposal loop, the
        // finish and its index effects — lives in `Settlement`, a DELEGATECALLed
        // library. Its bytes sit outside this contract's EIP-170 budget while its
        // storage stays here. ONE call, deliberately: marshalling three separate
        // entry points across the seam cost more than the split saved (measured at
        // 298 B net before this was collapsed). See that file for why this seam.
        Settlement.settle(
            c,
            settleState[c.id],
            money,
            _cp(c),
            trackDecayed[c.id],
            cases[c.targetCaseId],
            Settlement.Ext(token, stakeReg, indexReg),
            maxSteps
        );
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
        money.totalPendingPayout -= amt;
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





    /// @notice The registry-minted global entry ids this case wrote (empty until it
    ///         settles as an approval). These are the permanent, collision-free
    ///         handles a client or a future logic version should use.
    function caseEntryIds(uint256 caseId) external view returns (uint256[] memory) {
        return cases[caseId].entryIds;
    }



    // M2.6: `_freezeSlice` and `_settleDuty` were here, as SECOND COPIES of the
    // versions in `Settlement` — kept only because VOID disposal had not moved
    // across the seam. It has (`Settlement.settleVoid`), so the duplicates are gone.
    // A penalty rule stated in two places is the divergence this milestone keeps
    // finding; there is now exactly one `_settleDuty` in the codebase.

    // --- internal transitions ------------------------------------------------

    /// @dev M2.6-P0-5: a case may only be OPENED while this contract is fully
    ///      authorized on BOTH registries. Settlement deliberately does not check —
    ///      an in-flight case must always be able to finish, which is what
    ///      `SETTLE_ONLY` exists for.
    ///
    ///      This is also the fee-trap fix. `submit` never checked its own
    ///      authorization, so a REVOKED logic still took fees for cases it could
    ///      never seat, settle, or refund — every retired contract became a
    ///      permanent trap with no path back out. It now refuses the money.
    ///
    ///      Checking both registries is what makes a desynchronized authorization
    ///      fail closed: they are governed independently, so a logic can be
    ///      authorized in one and not the other, and a case opened in that state
    ///      would settle its stake and then fail its index write. True atomicity
    ///      needs a shared authorization contract; until then this makes the
    ///      unsafe state unreachable from the only path that creates exposure.
    function _requireOpen() internal view {
        if (
            stakeReg.logicState(address(this)) != StakeRegistry.LogicState.OPEN_AND_SETTLE
                || indexReg.logicState(address(this)) != IndexRegistry.LogicState.OPEN_AND_SETTLE
        ) revert NotAcceptingSubmissions();
    }

    /// @dev Arm a seat seed so its whole window — the snapshot block plus the
    ///      slack a poke needs to realize it — lies inside ONE eligibility epoch
    ///      (M2.6-P0-3). Draw-eligible weight changes only at epoch boundaries, so
    ///      a window that does not straddle one sees a constant eligible set:
    ///      nothing can be reshaped after the entropy is public, in either
    ///      direction, and there is therefore nothing to detect and nothing to
    ///      re-arm on. A window that would not fit is deferred to the start of the
    ///      next epoch rather than armed and later invalidated.
    ///
    ///      `REALIZE_SLACK` is the stated bound: a case gets at least this many
    ///      blocks after its snapshot in which to be realized. Sit longer and the
    ///      window is abandoned and re-armed into a later epoch — the case is never
    ///      stuck, it only waits.
    function _armSeed(Case storage c, Round storage r) internal {
        uint256 lag = _cp(c).seedLag;
        uint256 epochLen = stakeReg.epochBlocks();
        uint256 pos = block.number % epochLen;
        if (epochLen - pos > lag + REALIZE_SLACK) {
            r.seatSnapshotBlock = block.number + lag;
            r.epochAtArm = block.number / epochLen;
        } else {
            uint256 start = (block.number / epochLen + 1) * epochLen;
            r.seatSnapshotBlock = start + lag;
            r.epochAtArm = start / epochLen;
        }
    }

    function _openRound(Case storage c, uint256 depth) internal {
        c.rounds.push();
        Round storage r = c.rounds[c.rounds.length - 1];
        uint256 target = _commitTarget(c, depth);
        r.nSeats = 0; // filled in by the draw: seats seated, not seats sought
        r.pendingDraw = target; // H-05
        r.caseRef = (c.id << 8) | depth; // M2.6-P0-5
        _armSeed(c, r);
        // M2.6-P0-6: a draw that can never complete must still end. Deliberately
        // set here and on widen, NOT in `_armSeed` — a case whose seed keeps
        // re-arming for want of capacity would otherwise push its own deadline
        // forward forever, which is exactly the stall being closed.
        c.phaseDeadline = block.timestamp + _cp(c).commitTimeout;
        r.outcome = Outcome.Unset;
        r.appealFor = Outcome.Unset;
        c.depth = depth;
        c.phase = Phase.DRAW;
        emit RoundOpened(c.id, depth, target, r.seatSnapshotBlock); // seats SOUGHT
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
            // H-05: a widen re-draw gets FRESH entropy (a newly armed snapshot
            // block), not keccak(oldSeed, widenCount) — which contained no new
            // randomness and was fully known before a voter decided whether to
            // withhold a reveal and trigger the widen. Back to DRAW; the poke
            // draws only the added seats.
            r.pendingDraw = add;
            _armSeed(c, r);
            c.phase = Phase.DRAW;
            c.phaseDeadline = block.timestamp + _cp(c).commitTimeout; // P0-6
            emit Widened(c.id, c.depth, r.widenCount, r.nSeats); // seated so far
            emit RoundOpened(c.id, c.depth, add, r.seatSnapshotBlock); // seats SOUGHT
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
            _failAppealRound(c, r);
        }
    }

    /// @dev An appeal round that produced no adjudication: the layer failed, the
    ///      appeal did not lose on the merits. Restore the prior outcome for
    ///      liveness, and refund the funding bond's capital (no bonus) rather than
    ///      forfeiting it to the prior winners (H-10).
    function _failAppealRound(Case storage c, Round storage r) internal {
        Round storage prev = c.rounds[c.depth - 1];
        prev.bondRefundOnly = true;
        r.outcome = prev.outcome;
        c.finalOutcome = prev.outcome;
        c.phase = Phase.FINALIZED;
        emit Finalized(c.id, c.finalOutcome);
    }

    function _armOutcome(Case storage c, Round storage r) internal {
        c.phase = Phase.TALLY;
        r.outcomeSnapshotBlock = block.number + _cp(c).seedLag;
        emit OutcomeArmed(c.id, c.depth, r.outcomeSnapshotBlock);
    }

    /// @dev M2.6-P0-7: begin a VOID. O(1) — it only flips the phase.
    ///
    ///      This used to dispose every seat-holder inline, and it is called from
    ///      `_closeReveal`, a PHASE TRANSITION. Exceeding the block limit therefore
    ///      reverted the transition itself and stranded the case in an expired
    ///      REVEAL with no other exit — strictly worse than an expensive
    ///      settlement, which at least fails without destroying reachability. An
    ///      adversarially widened depth-0 panel reaches it directly.
    ///
    ///      Of the two ways to bound it, the cursor could not simply be threaded
    ///      through `closeReveal` the way `realizeSeats` threads one: a transition
    ///      that returns half-done would leave the case in REVEAL while its
    ///      participants were partly disposed, so every other REVEAL path
    ///      (`commitVote` guards, widen, re-entry into `closeReveal`) would have to
    ///      learn about a half-void state. Disposal moves into its own phase
    ///      instead, exactly as the work order sketches: `closeReveal` becomes
    ///      unconditionally O(1), and `VOID_SETTLING` drains behind the same
    ///      bounded participant cursor `SETTLING` already uses.
    function _void(Case storage c) internal {
        c.phase = Phase.VOID_SETTLING;
        c.finalOutcome = Outcome.Void;
        settleState[c.id].idx = 0;
        emit VoidOpened(c.id, _cur(c).seatHolders.length);
    }

    // M2.6: the DISPOSAL half of a VOID (`_voidStep` / `_voidFinish`) moved to
    // `Settlement.settleVoid`. Only the O(1) opener above stays, because only the
    // opener is called from the round state machine. See that file's header for the
    // correction to the split's original — and wrong — reason for leaving it here.

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

    /// @dev Draw `count` seats, RESERVING one duty unit per seat (H-07). A
    ///      moderator whose pledged capacity is exhausted mid-draw drops out of the
    ///      tree for the remainder of this draw (its weight is restored at the
    ///      end), so seats land only where collateral exists — no rejection
    ///      sampling and no unbounded gas: each exclusion happens at most once per
    ///      distinct moderator, and the loop is bounded by `count + exclusions`.
    function _drawSeats(Round storage r, uint256 count, bytes32 seed, uint256 offset) internal {
        (address[] memory seats, uint256 attempts) = stakeReg.drawPanel(count, seed, offset, r.caseRef);
        uint256 n = seats.length;
        for (uint256 i; i < n; ++i) {
            address seat = seats[i];
            if (r.seats[seat] == 0) r.seatHolders.push(seat);
            r.seats[seat] += 1;
        }
        // The registry seats only where collateral exists, so a panel can come
        // back SHORT of the commit target when pledged duty capacity is scarce
        // (H-07). Count what was actually seated, not what was asked for: an
        // inflated nSeats would misreport the panel and, if it ever fed quorum
        // logic, would let a thin panel look full. Under-participation is
        // already the widen path's job.
        r.nSeats += n;
        // Attempts, not seats: the offset must advance past every draw the
        // registry actually performed, so a later widen's draws stay disjoint
        // from this one's even when some attempts hit exhausted capacity.
        r.seatDrawCount += attempts;
    }

    /// @dev Free stake usable as per-case collateral right now: excludes the
    ///      pending-activation and exit-reserved portions (H-07 partial commit).
    function _eligibleFreeOf(address moderator) internal view returns (uint256) {
        (uint256 free, uint256 pending,,,,, uint256 exitAmount,,) = stakeReg.moderatorInfo(moderator);
        uint256 reserved = pending + exitAmount;
        return free > reserved ? free - reserved : 0;
    }

    // M2.6: `_clearDedup` went with `_voidFinish` — a third duplicate that only
    // existed because VOID disposal had not crossed the seam. `_dedupKey` stays:
    // `submit` reserves with it, and that is on this side of the boundary.
    function _dedupKey(bytes32 contentHash, bytes32 metaHash, bytes32 topicKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(contentHash, metaHash, topicKey));
    }

    /// @notice True iff the (content, meta, topic) triple is currently reserved —
    ///         by ANY logic version, not just this one (M2.6-P0-1b).
    function submissionExists(bytes32 dedupKey) external view returns (bool) {
        return indexReg.isContentReserved(dedupKey);
    }

    /// @dev `dedupOwner(bytes32)` was REMOVED in M2.6. It returned a bare caseId,
    ///      which cannot distinguish "unreserved" from "owned by case 0" and, since
    ///      the reservation became cross-version in P0-1b, cannot say which logic
    ///      holds it either. `indexReg.contentReservation(key)` answers both.
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
    // Thin forwarders: the entries are the registry's, but the M2 ABI keeps
    // working for clients pointed at this contract.

    /// Superset: number of current entries under a topic.
    function entryCount(bytes32 topicKey) external view returns (uint256) {
        return indexReg.entryCount(topicKey);
    }

    function entryAt(bytes32 topicKey, uint256 i) external view returns (IndexRegistry.Entry memory) {
        return indexReg.entryAt(topicKey, i);
    }

    /// @dev The unpaginated `supersafeEntries(bytes32)` wrapper was REMOVED in
    ///      M2.6. It called the registry with the entire topic length, so the
    ///      preserved M2 signature was not operationally safe at scale — and it
    ///      cost `Moderation` bytes it no longer has. Read the paginated
    ///      `indexReg.supersafeEntries(topic, minAge, cursor, limit)` directly;
    ///      `minAge` is `getParams().supersafeAge`.

    function caseGuidelinesVersion(uint256 caseId) external view returns (uint256) {
        return cases[caseId].guidelinesVersion;
    }

    // =========================================================================
    // Governance (§9.9, P6) — APPLICATION only.
    //
    // A ruleset is proposed, validated and timelocked in `RulesetGovernor`; what
    // remains here is sealing the authored result into storage. Core transitions
    // (§3, §5) are code and have no mutation path, and no function anywhere
    // pauses withdrawals (§9.5).
    // =========================================================================

    event ParametersApplied(uint256 indexed rulesVersion);
    event GuidelinesApplied(uint256 indexed version, bytes32 hash);

    error NotGovernor();
    error ZeroGovernor();
    /// A ruleset would lock more per seat than a pledged duty unit is worth, so
    /// panels could be seated on collateral that cannot cover them.
    error RiskPerSeatExceedsDutyUnit();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// @notice Seal a validated ruleset as a new immutable version (H-11). Open
    ///         cases keep the version they pinned at submit; only cases submitted
    ///         after this pick up the new rules.
    /// @dev Full validation is `RulesetGovernor`'s. The one bound re-checked here
    ///      is the one whose violation is a SOLVENCY failure rather than a
    ///      liveness one: a case locking more per seat than a pledged duty unit is
    ///      worth would seat panels on collateral that cannot cover them. Every
    ///      other validation failure can brick a case; only this one can seat an
    ///      uncollateralized panel, so it is enforced at the boundary and cannot
    ///      be skipped by a governor bug.
    function applyRuleset(
        Params calldata p,
        uint256[] calldata commitTargets,
        uint256[] calldata appealWindows
    ) external onlyGovernor {
        if (p.riskPerSeat > stakeReg.riskPerSeat()) revert RiskPerSeatExceedsDutyUnit();
        params = p;
        commitTargetByDepth = commitTargets;
        appealWindowByDepth = appealWindows;
        currentRulesVersion += 1;
        rulesets[currentRulesVersion] =
            Ruleset({p: p, commitTargets: commitTargets, appealWindows: appealWindows});
        emit ParametersApplied(currentRulesVersion);
    }

    /// @notice Append a guidelines version. Existing versions are never
    ///         overwritten (invariant 9).
    function applyGuidelines(bytes32 hash) external onlyGovernor returns (uint256 version) {
        version = guidelinesVersion + 1;
        guidelinesVersion = version;
        guidelinesHashByVersion[version] = hash;
        emit GuidelinesApplied(version, hash);
    }

    // --- eligibility wiring (D6) ---------------------------------------------
    //
    // Draw-eligible weight, the sortition tree and the free/committed/frozen
    // partition are StakeRegistry-internal (M2.5-P0-b). Read them there:
    // `moderatorInfo`, `totalStakeOf`, `eligibleWeightOf`, `totalEligibleWeight`,
    // `stakeBuckets`.

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
