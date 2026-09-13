// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @notice Moderator custody. Stake and frozen time; there is no bond.
interface IStakeRegistry {
    function isActive(address a) external view returns (bool);
    function isFrozen(address a) external view returns (bool);
    function stakedCount() external view returns (uint256);
    function noteCommit(address a) external;
    function settle(address a, bool incoherent, uint256 duration) external;
}

interface IIndexRegistry {
    function writeEntry(
        bytes32 claimKey,
        bytes32 topicKey,
        uint8 status,
        bool allTicketsApprove,
        bool everChallenged,
        uint32 approve,
        uint32 reject
    ) external;
    function removeListing(bytes32 claimKey, bytes32 topicKey) external;
}

/// @title Moderation
/// @notice The case state machine of `specs/protocol.md`.
///
/// The lifecycle, §4:
///
///     submit
///       │  R_A = blockhash at submission
///       ├── committee A commits      closes 15 min after the 3rd commit
///       │  R_B = blockhash after A's commit phase closed
///       ├── committee B commits      closes 15 min after the 3rd commit
///       ├── A and B reveal together  30 min
///       ├── 3 tickets on the combined tally -> PRELIMINARY OUTCOME (published)
///       └── 1 hour challenge window
///             challenged? -> committees C and D on the same pattern, tickets
///             drawn AFRESH over the whole pool. At most two challenges.
///
/// Two properties carry the design and are worth naming where they live:
///
/// **Committee B is unknowable while committee A commits** (`closeCommitA`). Its
/// seed is a block height armed only when A's commit phase closes, so nobody
/// deciding whether to commit in A can see who else will review the case.
///
/// **Neither committee sees the other's votes.** Both reveal in the same phase
/// (`Phase.REVEAL`), so B commits with no tally to follow. Payment is for
/// coherence with the outcome, so a visible tally would make following it more
/// profitable than judging.
contract Moderation is ReentrancyGuard {
    using SafeTransferLib for address;

    // ---------------------------------------------------------------- types

    enum Phase {
        NONE,
        COMMIT_A,
        COMMIT_B,
        REVEAL,
        CHALLENGE,
        FINALIZED,
        UNRESOLVED
    }

    enum Outcome {
        NONE,
        APPROVE,
        REJECT
    }

    struct Case {
        // --- identity
        bytes32 contentHash;
        bytes32 metaHash;
        bytes32 claimKey;
        address submitter;
        uint8 topicCount;
        uint8 actionType; // 0 = LIST, 1 = REMOVE (§8)
        uint256 targetCaseId; // the listing a removal targets; 0 for a listing
        // --- lifecycle
        uint8 phase;
        uint8 challenges; // 0..MAX_CHALLENGES
        uint40 phaseDeadline;
        uint40 finalizedAt;
        // --- committee seeds: TWO per round (§4.1)
        uint40 seedBlockA;
        uint40 seedBlockB;
        uint40 outcomeSeedBlock; // armed when REVEAL closes; fresh each round
        uint8 eligBits; // N-5, pinned at submission
        // --- per-committee counts, current round only. Kept APART because §4.4's
        // floor is per committee: a combined count cannot tell 6-and-0 from 3-and-3.
        uint32 commitsA;
        uint32 commitsB;
        uint32 revealsA;
        uint32 revealsB;
        // --- pooled across every round, never reset (§5)
        uint32 pooledApprove;
        uint32 pooledReject;
        // --- outcome
        uint8 preliminary; // published at each draw
        uint8 ticketsApprove; // of 3, at the latest draw
        bool everChallenged; // §7: a challenged entry is never anonymous
        uint128 pot;
    }

    struct Vote {
        bytes32 commitment;
        uint8 committee; // 1 = A, 2 = B
        uint8 round; // the challenge round it was cast in
        uint8 revealed; // Outcome
        bool settled;
    }

    // ------------------------------------------------------------ constants

    bytes32 internal constant ELIGIBILITY_DOMAIN = keccak256("eligibility");
    bytes32 internal constant OUTCOME_DOMAIN = keccak256("outcome");
    bytes32 internal constant COMMIT_DOMAIN = keccak256("commit");

    uint8 public constant ACTION_LIST = 0;
    uint8 public constant ACTION_REMOVE = 1;

    uint8 public constant MAX_CHALLENGES = 2;
    uint256 public constant MAX_TOPICS = 5;

    /// @dev Only 256 block hashes are addressable. Every seed must be consumed
    ///      inside this horizon or the phase cannot proceed.
    uint256 internal constant BLOCKHASH_HORIZON = 250;

    // ------------------------------------------------------------ immutables

    IERC20 public immutable token;
    IStakeRegistry public immutable stakes;
    IIndexRegistry public immutable index;

    uint256 public immutable commitWindow; // 15 min, from the 3rd commit
    uint256 public immutable revealWindow; // 30 min
    uint256 public immutable challengeWindow; // 1 hour
    uint256 public immutable maxWaitForThird; // bounds a case nobody commits to
    uint256 public immutable freezePerLoss; // §2

    /// @dev §4.4's per-committee minimum, counted on REVEALS and not on commits.
    ///      Commits are the wrong quantity: a clique can commit `k` in each
    ///      committee to clear a commit floor and then reveal only what helps,
    ///      because a non-revealed commitment costs nothing to withhold. That
    ///      clears the floor without producing any evidence — which is exactly
    ///      what `simulation/FINDINGS-floor-price.md` §G concedes a commit floor
    ///      cannot do. Counted on reveals, the `k` votes per committee must
    ///      actually be exposed, and each one carries the ordinary freeze
    ///      liability.
    uint256 public immutable minRevealsPerCommittee;
    uint256 public immutable seedLag;
    uint256 public immutable feeMin;

    // ---------------------------------------------------------------- state

    uint256 public nextCaseId = 1;
    mapping(uint256 => Case) internal cases;

    mapping(uint256 => bytes32[MAX_TOPICS]) internal caseTopics;
    mapping(uint256 => mapping(address => Vote)) internal votes;
    mapping(uint256 => uint256) public refundOwed;

    /// @dev A listing may have at most one removal case open at a time, and a
    ///      listing already removed cannot be removed again.
    mapping(uint256 => uint256) public openRemovalOf;
    mapping(uint256 => bool) public removed;

    // --------------------------------------------------------------- events

    event Submitted(uint256 indexed caseId, address indexed submitter, bytes32 claimKey);
    event RemovalSubmitted(uint256 indexed caseId, uint256 indexed targetCaseId, address indexed by);
    event Removed(uint256 indexed targetCaseId, uint256 indexed removalCaseId);
    event Committed(uint256 indexed caseId, address indexed m, uint8 committee, uint8 round);
    event Revealed(uint256 indexed caseId, address indexed m, uint8 vote);
    event PhaseChanged(uint256 indexed caseId, uint8 from, uint8 to);
    event PreliminaryOutcome(uint256 indexed caseId, uint8 outcome, uint8 ticketsApprove, uint8 round);
    event Challenged(uint256 indexed caseId, address indexed by, uint8 against);
    event Finalized(uint256 indexed caseId, uint8 outcome);
    event Unresolved(uint256 indexed caseId);
    event Claimed(uint256 indexed caseId, address indexed m, uint256 paid, bool frozen);

    // --------------------------------------------------------------- errors

    error BadPhase();
    error TooEarly();
    error TooLate();
    error NotEligible();
    error AlreadyVoted();
    error NoCommitment();
    error BadReveal();
    error SeedUnavailable();
    error NothingToClaim();
    error BadOutcome();
    error BadTopics();
    error FeeTooLow();
    error ChallengeExhausted();
    error NotARemovableListing();
    error RemovalAlreadyOpen();
    error AlreadyRemoved();
    error BadFloor();

    constructor(
        address _token,
        address _stakes,
        address _index,
        uint256 _commitWindow,
        uint256 _revealWindow,
        uint256 _challengeWindow,
        uint256 _maxWaitForThird,
        uint256 _freezePerLoss,
        uint256 _seedLag,
        uint256 _feeMin,
        uint256 _minRevealsPerCommittee
    ) {
        token = IERC20(_token);
        stakes = IStakeRegistry(_stakes);
        index = IIndexRegistry(_index);
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        challengeWindow = _challengeWindow;
        maxWaitForThird = _maxWaitForThird;
        freezePerLoss = _freezePerLoss;
        seedLag = _seedLag;
        feeMin = _feeMin;

        // A floor of 0 is not "the floor turned off", it is a footgun: with no
        // floor, a case that nobody revealed reaches `_decide` with an empty
        // tally, which resolves REJECT and pays nobody instead of refunding the
        // publisher for a judgment that never happened. `k = 1` is the weakest
        // meaningful setting and is already strictly stronger than the combined
        // "any reveal at all" check this replaced, because it demands one in EACH
        // committee.
        if (_minRevealsPerCommittee == 0) revert BadFloor();
        minRevealsPerCommittee = _minRevealsPerCommittee;
    }

    // ------------------------------------------------------------- submit

    function submit(bytes32 contentHash, bytes32 metaHash, bytes32[] calldata topics, uint256 fee)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        if (topics.length == 0 || topics.length > MAX_TOPICS) revert BadTopics();
        if (fee < feeMin) revert FeeTooLow();

        caseId = nextCaseId++;
        Case storage c = cases[caseId];

        c.contentHash = contentHash;
        c.metaHash = metaHash;
        c.claimKey = keccak256(abi.encode(contentHash, metaHash));
        c.submitter = msg.sender;
        c.topicCount = uint8(topics.length);
        for (uint256 i; i < topics.length; ++i) {
            caseTopics[caseId][i] = topics[i];
        }

        _open(caseId, fee);
        emit Submitted(caseId, msg.sender, c.claimKey);
    }

    /// @dev §8 — a removal targets an entry already listed and runs through the
    ///      same engine: same committees, same staging, same tickets, same
    ///      challenge. **Approve means remove.**
    ///
    ///      It references the listing's case rather than re-supplying its hashes
    ///      and topics, so the two cannot disagree about what is being removed —
    ///      a removal naming its own topic list could remove an entry from one
    ///      topic and leave it under another.
    function submitRemoval(uint256 targetCaseId, uint256 fee)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        if (fee < feeMin) revert FeeTooLow();

        Case storage t = cases[targetCaseId];
        if (
            t.phase != uint8(Phase.FINALIZED) || t.actionType != ACTION_LIST
                || t.preliminary != uint8(Outcome.APPROVE)
        ) revert NotARemovableListing();
        if (removed[targetCaseId]) revert AlreadyRemoved();
        if (openRemovalOf[targetCaseId] != 0) revert RemovalAlreadyOpen();

        caseId = nextCaseId++;
        Case storage c = cases[caseId];

        c.contentHash = t.contentHash;
        c.metaHash = t.metaHash;
        c.claimKey = t.claimKey;
        c.submitter = msg.sender;
        c.topicCount = t.topicCount;
        c.actionType = ACTION_REMOVE;
        c.targetCaseId = targetCaseId;
        caseTopics[caseId] = caseTopics[targetCaseId];

        openRemovalOf[targetCaseId] = caseId;

        _open(caseId, fee);
        emit RemovalSubmitted(caseId, targetCaseId, msg.sender);
    }

    function _open(uint256 caseId, uint256 fee) internal {
        Case storage c = cases[caseId];
        c.pot = uint128(fee);
        c.eligBits = _eligBits();
        c.phase = uint8(Phase.COMMIT_A);
        c.seedBlockA = uint40(block.number + seedLag);
        c.phaseDeadline = uint40(block.timestamp + maxWaitForThird);
        address(token).safeTransferFrom(msg.sender, address(this), fee);
    }

    /// @dev §3 derives `N` from the count of NON-FROZEN moderators. That count
    ///      falls and rises without any transaction — a freeze expires on a clock,
    ///      and no one is obliged to report it — so it cannot be maintained on
    ///      chain. `N` is pinned here from the count of STAKED moderators, which
    ///      is exact, and `commit` rejects a frozen caller separately. The
    ///      threshold is therefore calibrated slightly wide whenever part of the
    ///      registry is frozen. Recorded in `specs/protocol.md` §10.2.
    function _eligBits() internal view returns (uint8) {
        uint256 n = stakes.stakedCount();
        uint8 bits;
        while (n > 1) {
            n >>= 1;
            ++bits;
        }
        return bits > 5 ? bits - 5 : 0;
    }

    // ------------------------------------------------------------- voting

    /// @dev One vote per case, not per committee. A moderator eligible for both
    ///      committees of a round votes in whichever they reach first.
    ///      Whether eligibility should instead be one-shot — so that declining
    ///      committee A forfeits committee B — is open (`specs/protocol.md` §10.2).
    function commit(uint256 caseId, bytes32 h) external {
        Case storage c = cases[caseId];
        uint8 committee = _committeeOf(c.phase);
        if (committee == 0) revert BadPhase();
        if (block.timestamp >= c.phaseDeadline) revert TooLate();
        if (!stakes.isActive(msg.sender) || stakes.isFrozen(msg.sender)) revert NotEligible();
        if (votes[caseId][msg.sender].commitment != bytes32(0)) revert AlreadyVoted();
        if (!_eligible(caseId, msg.sender, committee)) revert NotEligible();

        votes[caseId][msg.sender] =
            Vote({commitment: h, committee: committee, round: c.challenges, revealed: 0, settled: false});

        stakes.noteCommit(msg.sender);

        uint32 n;
        if (committee == 1) {
            n = ++c.commitsA;
        } else {
            n = ++c.commitsB;
        }

        // §4.1 — three commitments START the clock. They are not a quorum, and
        // later commits never extend the deadline once it is pinned.
        if (n == 3) c.phaseDeadline = uint40(block.timestamp + commitWindow);

        emit Committed(caseId, msg.sender, committee, c.challenges);
    }

    function reveal(uint256 caseId, uint8 v, bytes32 salt) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.REVEAL)) revert BadPhase();
        if (block.timestamp >= c.phaseDeadline) revert TooLate();
        if (v != uint8(Outcome.APPROVE) && v != uint8(Outcome.REJECT)) revert BadOutcome();

        Vote storage vt = votes[caseId][msg.sender];
        if (vt.commitment == bytes32(0)) revert NoCommitment();
        if (vt.revealed != 0) revert AlreadyVoted();
        if (vt.round != c.challenges) revert BadPhase();
        if (vt.commitment != commitHash(caseId, vt.round, msg.sender, v, salt)) revert BadReveal();

        vt.revealed = v;
        if (vt.committee == 1) ++c.revealsA;
        else ++c.revealsB;

        if (v == uint8(Outcome.APPROVE)) ++c.pooledApprove;
        else ++c.pooledReject;

        emit Revealed(caseId, msg.sender, v);
    }

    function commitHash(uint256 caseId, uint8 round, address m, uint8 v, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(COMMIT_DOMAIN, block.chainid, address(this), caseId, round, m, v, salt));
    }

    // ------------------------------------------------------- phase advance

    /// @dev Arming committee B's seed HERE, and not before, is the whole point of
    ///      the staging: while committee A was committing this height did not
    ///      exist, so committee B was not computable by anyone.
    function closeCommitA(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.COMMIT_A)) revert BadPhase();
        if (block.timestamp < c.phaseDeadline) revert TooEarly();

        if (c.commitsA == 0 && c.challenges == 0) return _toUnresolved(caseId);

        c.phase = uint8(Phase.COMMIT_B);
        c.seedBlockB = uint40(block.number + seedLag);
        c.phaseDeadline = uint40(block.timestamp + maxWaitForThird);
        emit PhaseChanged(caseId, uint8(Phase.COMMIT_A), uint8(Phase.COMMIT_B));
    }

    function closeCommitB(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.COMMIT_B)) revert BadPhase();
        if (block.timestamp < c.phaseDeadline) revert TooEarly();

        c.phase = uint8(Phase.REVEAL);
        c.phaseDeadline = uint40(block.timestamp + revealWindow);
        emit PhaseChanged(caseId, uint8(Phase.COMMIT_B), uint8(Phase.REVEAL));
    }

    /// @dev The outcome seed is armed at reveal close and consumed by `draw`, so
    ///      the tally is frozen before the randomness that resolves it exists —
    ///      and a fresh height is armed for every round, because §5 draws afresh.
    ///
    ///      This is also where §4.4's per-committee minimum is enforced, because
    ///      this is the first moment both committees' REVEALED counts are final.
    ///      `revealsA` and `revealsB` are per-round: `challenge` resets them, so
    ///      each round must field its own two committees rather than inheriting
    ///      the first round's.
    ///
    ///      **What a failed floor means depends on whether anything was decided
    ///      yet, and the two cases are not symmetric.** On the first round no
    ///      outcome exists, so the case is UNRESOLVED and the fee is refunded —
    ///      the publisher paid for a judgment that never happened. On a challenge
    ///      round a preliminary outcome already stands, and voiding the case would
    ///      hand any challenger a way to destroy a decided case by challenging and
    ///      then bringing nobody. So the standing outcome finalizes instead: the
    ///      challenge bought two committees, they did not materialise, and the
    ///      challenge failed to produce evidence.
    ///
    ///      The challenger is not let off. Their vote was opposite the outcome
    ///      that now finalizes, so `claim` settles them as incoherent and freezes
    ///      them — a vote that changed nothing and still cost the ordinary
    ///      liability, which is the whole price of a frivolous challenge.
    function closeReveal(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.REVEAL)) revert BadPhase();
        if (block.timestamp < c.phaseDeadline) revert TooEarly();

        uint256 k = minRevealsPerCommittee;
        if (c.revealsA < k || c.revealsB < k) {
            if (c.challenges == 0) return _toUnresolved(caseId);
            return _finalize(caseId);
        }

        c.outcomeSeedBlock = uint40(block.number + seedLag);
        emit PhaseChanged(caseId, uint8(Phase.REVEAL), uint8(Phase.CHALLENGE));
    }

    /// @dev Permissionless. Publishes the preliminary outcome and opens the
    ///      challenge window (§4.2). No money moves here (§4.3).
    function draw(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.REVEAL)) revert BadPhase();
        uint256 sb = c.outcomeSeedBlock;
        if (sb == 0 || block.number <= sb) revert TooEarly();
        if (block.number > sb + BLOCKHASH_HORIZON) revert SeedUnavailable();

        (uint8 outcome, uint8 tickets) = _decide(caseId, blockhash(sb));
        c.preliminary = outcome;
        c.ticketsApprove = tickets;

        if (c.challenges >= MAX_CHALLENGES) {
            _finalize(caseId);
        } else {
            c.phase = uint8(Phase.CHALLENGE);
            c.phaseDeadline = uint40(block.timestamp + challengeWindow);
        }
        emit PreliminaryOutcome(caseId, outcome, tickets, c.challenges);
    }

    // ---------------------------------------------------------- challenge

    /// @dev §4.2 — a challenge IS a vote, and it is opposite the published
    ///      outcome by construction. It discloses its direction, counts once, and
    ///      carries the ordinary liability: an incoherent challenger is frozen
    ///      like any other incoherent voter.
    function challenge(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.CHALLENGE)) revert BadPhase();
        if (block.timestamp >= c.phaseDeadline) revert TooLate();

        // UNREACHABLE BY CONSTRUCTION, and kept as defence in depth. `draw` only
        // opens `Phase.CHALLENGE` while `c.challenges < MAX_CHALLENGES` and
        // finalizes otherwise, so a case in this phase has at most
        // `MAX_CHALLENGES - 1` challenges and this can never fire. Mutation
        // testing will therefore ALWAYS report `>=` -> `>` here as a survivor: no
        // test can kill a branch that no state reaches. Do not chase it, and do
        // not delete it either — it is the only thing standing between a future
        // change in `draw`'s finalize condition and an uncapped challenge loop.
        if (c.challenges >= MAX_CHALLENGES) revert ChallengeExhausted();
        if (!stakes.isActive(msg.sender) || stakes.isFrozen(msg.sender)) revert NotEligible();
        if (votes[caseId][msg.sender].commitment != bytes32(0)) revert AlreadyVoted();

        uint8 against =
            c.preliminary == uint8(Outcome.APPROVE) ? uint8(Outcome.REJECT) : uint8(Outcome.APPROVE);

        // a public, already-revealed vote: recorded as cast, never re-revealed
        votes[caseId][msg.sender] = Vote({
            commitment: bytes32(uint256(1)),
            committee: 0,
            round: c.challenges,
            revealed: against,
            settled: false
        });
        if (against == uint8(Outcome.APPROVE)) ++c.pooledApprove;
        else ++c.pooledReject;

        stakes.noteCommit(msg.sender);
        c.everChallenged = true;
        ++c.challenges;

        // a fresh pair of committees, on the same staged pattern
        c.commitsA = 0;
        c.commitsB = 0;
        c.revealsA = 0;
        c.revealsB = 0;
        c.seedBlockB = 0;
        c.outcomeSeedBlock = 0;
        c.phase = uint8(Phase.COMMIT_A);
        c.seedBlockA = uint40(block.number + seedLag);
        c.phaseDeadline = uint40(block.timestamp + maxWaitForThird);

        emit Challenged(caseId, msg.sender, against);
    }

    function closeChallenge(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.CHALLENGE)) revert BadPhase();
        if (block.timestamp < c.phaseDeadline) revert TooEarly();
        _finalize(caseId);
    }

    // ---------------------------------------------------------- settlement

    function _finalize(uint256 caseId) internal {
        Case storage c = cases[caseId];
        c.phase = uint8(Phase.FINALIZED);
        c.finalizedAt = uint40(block.timestamp);

        bytes32[MAX_TOPICS] storage t = caseTopics[caseId];

        if (c.actionType == ACTION_REMOVE) {
            // §8 — the fee is paid whichever way this goes, so nothing is
            // refunded here. A speculative removal costs its submitter every
            // time, which is what stops removal being free censorship.
            openRemovalOf[c.targetCaseId] = 0;
            if (c.preliminary == uint8(Outcome.APPROVE)) {
                removed[c.targetCaseId] = true;
                for (uint256 i; i < c.topicCount; ++i) {
                    index.removeListing(c.claimKey, t[i]);
                }
                emit Removed(c.targetCaseId, caseId);
            }
        } else if (c.preliminary == uint8(Outcome.APPROVE)) {
            for (uint256 i; i < c.topicCount; ++i) {
                index.writeEntry(
                    c.claimKey,
                    t[i],
                    uint8(Outcome.APPROVE),
                    c.ticketsApprove == 3,
                    c.everChallenged,
                    c.pooledApprove,
                    c.pooledReject
                );
            }
        }
        emit Finalized(caseId, c.preliminary);
    }

    function _toUnresolved(uint256 caseId) internal {
        Case storage c = cases[caseId];
        if (c.actionType == ACTION_REMOVE) openRemovalOf[c.targetCaseId] = 0;
        c.phase = uint8(Phase.UNRESOLVED);
        c.finalizedAt = uint40(block.timestamp);
        refundOwed[caseId] += c.pot;
        c.pot = 0;
        emit Unresolved(caseId);
    }

    /// @dev Pull settlement, one moderator at a time, permissionless. §6.
    ///      Coherent: paid a share of the pot. Incoherent: `FREEZE_PER_LOSS`
    ///      added to their total frozen time — the only penalty in the design.
    ///
    ///      **A commitment never revealed is frozen for the same duration as a
    ///      wrong one, and the amount is forced rather than chosen.** Reveals are
    ///      public transactions in a shared phase, so a moderator can watch the
    ///      tally form and withhold if they would be incoherent. If withholding
    ///      cost less than being wrong, then anyone expecting to lose would
    ///      withhold and revealing would be the dominated move. Equal removes the
    ///      choice: both cost the same, so revealing is weakly better because it
    ///      keeps the chance of being paid.
    /// @dev Also callable on an UNRESOLVED case, and it has to be. A vote is
    ///      settled here and nowhere else, and settling is what releases the
    ///      moderator's open-vote count. Without this an unresolved case would
    ///      strand every committer's stake permanently, because
    ///      `StakeRegistry.withdraw` refuses while a vote is open.
    ///
    ///      **On an UNRESOLVED case a non-revealer is still frozen, and that is
    ///      not tidiness — it closes a vector the per-committee floor opens.** A
    ///      case is UNRESOLVED when a committee finished below the floor. A
    ///      moderator whose own reveal was needed to reach it can therefore push
    ///      the case to UNRESOLVED by withholding: the fee is refunded, nothing is
    ///      listed, and repeating it censors a submission indefinitely. Free, if
    ///      non-reveal were free here. A revealer on an unresolved case is NOT
    ///      frozen — they did their part and the case failed for want of others —
    ///      and nobody is paid, because there is no outcome to be coherent with.
    function claim(uint256 caseId, address m) external nonReentrant {
        Case storage c = cases[caseId];
        bool resolved = c.phase == uint8(Phase.FINALIZED);
        if (!resolved && c.phase != uint8(Phase.UNRESOLVED)) revert BadPhase();

        Vote storage vt = votes[caseId][m];
        if (vt.commitment == bytes32(0) || vt.settled) revert NothingToClaim();
        vt.settled = true;

        uint256 paid;
        // `Outcome.NONE` is 0 and `c.preliminary` is APPROVE or REJECT once drawn,
        // so `revealed != preliminary` already catches the non-revealer on a
        // resolved case; the first clause is what carries the unresolved one.
        bool frozen = vt.revealed == uint8(Outcome.NONE)
            || (resolved && vt.revealed != c.preliminary);
        stakes.settle(m, frozen, freezePerLoss);

        if (!resolved) {
            emit Claimed(caseId, m, 0, false);
            return;
        }

        if (vt.revealed == c.preliminary) {
            paid = shareOf(caseId);
            // paid from this contract's own balance — the fee never left it, so
            // routing the reward through the registry would only move custody
            // around for no reason
            if (paid != 0) address(token).safeTransfer(m, paid);
        }
        emit Claimed(caseId, m, paid, frozen);
    }

    /// @dev The pot over the number of coherent revealed votes. Fixed at
    ///      finalization, so every claimant computes the same number.
    function shareOf(uint256 caseId) public view returns (uint256) {
        Case storage c = cases[caseId];
        uint256 winners =
            c.preliminary == uint8(Outcome.APPROVE) ? c.pooledApprove : c.pooledReject;
        return winners == 0 ? 0 : uint256(c.pot) / winners;
    }

    function withdrawRefund(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        uint256 owed = refundOwed[caseId];
        if (owed == 0) revert NothingToClaim();
        refundOwed[caseId] = 0;
        address(token).safeTransfer(c.submitter, owed);
    }

    // ---------------------------------------------------------- the draw

    /// @dev §5. Three tickets against the combined tally; the outcome is the
    ///      majority. The comparison is cross-multiplied rather than modular:
    ///      both are uniform, but only this form is MONOTONE in the tally, so a
    ///      round that adds no votes cannot move the answer and a round that adds
    ///      votes can only move it toward the side it added.
    ///
    ///      `_estimator` is the raw share, decided in `specs/protocol.md` §5 against
    ///      the Laplace form `(A+1)/(N+2)`. It stays isolated in one function because
    ///      that is where the decision lives, not because it is still open.
    function _decide(uint256 caseId, bytes32 entropy) internal view returns (uint8 outcome, uint8 tickets) {
        (uint256 num, uint256 den) = _estimator(caseId);
        if (den == 0) return (uint8(Outcome.REJECT), 0);

        Case storage c = cases[caseId];
        for (uint256 i; i < 3; ++i) {
            uint256 u = uint128(
                uint256(
                    keccak256(
                        abi.encode(
                            OUTCOME_DOMAIN, block.chainid, address(this), caseId, c.challenges, i, entropy
                        )
                    )
                )
            );
            if (u * den < num << 128) tickets += 1;
        }
        outcome = tickets >= 2 ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);
    }

    /// @dev The raw share `A/N`. A unanimous tally therefore decides with
    ///      certainty. The alternative, `(A+1)/(N+2)`, never returns certainty and
    ///      was introduced so a single revealed vote could not decide a case
    ///      outright — a job §4.1's third-commit clock may already do. Open.
    function _estimator(uint256 caseId) internal view returns (uint256 num, uint256 den) {
        Case storage c = cases[caseId];
        num = c.pooledApprove;
        den = uint256(c.pooledApprove) + c.pooledReject;
    }

    function decideAt(uint256 caseId, bytes32 entropy) external view returns (uint8, uint8) {
        return _decide(caseId, entropy);
    }

    // ------------------------------------------------------- eligibility

    /// @dev §3. `hash(case, moderator, seed)` must carry at least `eligBits`
    ///      leading zeros. Publicly computable the moment the seed exists — which
    ///      for committee B is not until committee A has closed.
    function _eligible(uint256 caseId, address m, uint8 committee) internal view returns (bool) {
        Case storage c = cases[caseId];
        uint256 sb = committee == 1 ? c.seedBlockA : c.seedBlockB;
        if (sb == 0 || block.number <= sb) revert SeedUnavailable();
        if (block.number > sb + BLOCKHASH_HORIZON) revert SeedUnavailable();

        // a registry of 32 or fewer needs no narrowing at all, and the shift
        // below is only defined for 1..255
        if (c.eligBits == 0) return true;

        bytes32 seed = blockhash(sb);
        uint256 h = uint256(
            keccak256(abi.encode(ELIGIBILITY_DOMAIN, block.chainid, address(this), caseId, committee, seed, m))
        );
        return h >> (256 - c.eligBits) == 0;
    }

    function isEligible(uint256 caseId, address m) external view returns (bool) {
        uint8 committee = _committeeOf(cases[caseId].phase);
        if (committee == 0) return false;
        return _eligible(caseId, m, committee);
    }

    function _committeeOf(uint8 phase) internal pure returns (uint8) {
        if (phase == uint8(Phase.COMMIT_A)) return 1;
        if (phase == uint8(Phase.COMMIT_B)) return 2;
        return 0;
    }

    // ------------------------------------------------------------- views

    function caseInfo(uint256 caseId) external view returns (Case memory) {
        return cases[caseId];
    }

    function voteOf(uint256 caseId, address m) external view returns (Vote memory) {
        return votes[caseId][m];
    }

    function topicsOf(uint256 caseId) external view returns (bytes32[MAX_TOPICS] memory) {
        return caseTopics[caseId];
    }
}
