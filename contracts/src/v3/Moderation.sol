// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {StakeRegistry} from "./StakeRegistry.sol";

/// @notice The index this contract publishes to (§8.1, §8.2, §8.3).
/// @dev The real `IndexRegistry` surface as of M2.10. This was an improvised
///      four-argument stub (D3-1) while the index was unported; `strict` and the
///      two question calls are §8.3's split, and `removeListing` is §8.1's fifth
///      write. M2.10 made `removeListing` reachable, closing D3-15.
interface IIndexRegistry {
    function writeEntry(
        bytes32 claimKey,
        bytes32 topicKey,
        uint8 status,
        uint8 plurality,
        bool strict,
        uint8 actionType
    ) external returns (bytes32);
    function openQuestion(bytes32 claimKey, bytes32 topicKey) external;
    function closeQuestion(bytes32 claimKey, bytes32 topicKey) external;
    function removeListing(bytes32 listClaimKey, bytes32 topicKey) external returns (bytes32);
    function isListed(bytes32 claimKey, bytes32 topicKey) external view returns (bool);
}

/// @title Moderation (v3) — the case state machine
/// @notice §4 end to end, plus the parts of §5, §7 and §8 a case reaches.
///
/// @dev `Moderation` is a LOGIC CONTRACT in the registry's sense: governance grants
///      it `MAY_CREATE | MAY_DISCHARGE` and it drives moderator accounting through
///      `StakeRegistry` rather than holding it. It never reads or writes a
///      moderator's bond directly; §2.4 is the boundary and the registry is the
///      authority on solvency.
///
///      Invariants this contract owns, each with a discriminating test:
///
///      I3   one vote per moderator per CLAIM, across rounds — consumed by
///           `commit`, never by `reveal`
///      I7   both seeds derive from schedules fixed at submission
///      I11  no verdict is more confident than the tally it was drawn from
///      I12  both outcomes have non-zero probability at every reachable tally
///      I15  the index is written at the transition establishing a terminal —
///           all four — and settlement never touches it
///      I17  at most one challenge round per OPENING of a claim
///      I18  the §4.3 guards are pairwise disjoint
///      I19  every §4.1 field is written or provably preserved by every transition
///      I22  the verdict is monotone in `a` for fixed `u`
///      I25  the non-reveal debit fires wherever a reveal phase OPENED
///      I26  once tallied, no reachable terminal releases the claim key
///      I27  every debit uses the parameters pinned at submission
///      I29  seed guards are block-height comparisons, never observations of the
///           returned hash
///      I30  every obligation names its own condition, and a terminal fires
///           exactly those whose condition it meets
///      I31  no comparison spans two units of time
contract Moderation is ReentrancyGuard {
    using SafeTransferLib for address;

    uint8 internal constant KIND_VOTE = 1;
    uint8 internal constant KIND_CHALLENGE = 2;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_TOPICS = 5;

    bytes32 internal constant ELIGIBILITY_DOMAIN = keccak256("v3.eligibility");
    bytes32 internal constant OUTCOME_DOMAIN = keccak256("v3.outcome");
    bytes32 internal constant COMMIT_DOMAIN = keccak256("v3.commit");

    // =========================================================================
    // Types
    // =========================================================================

    enum Phase {
        NONE,
        COMMIT,
        REVEAL,
        TALLY,
        DRAW,
        FINALIZED,
        UNRESOLVED
    }

    enum Terminal {
        NONE,
        APPROVED,
        REJECTED,
        UNRESOLVED
    }

    enum Reason {
        NONE,
        NO_TURNOUT,
        NO_REVEALS,
        NO_RANDOMNESS
    }

    /// @dev `NONE` is not a third outcome — §4.2's plurality is TOTAL on any tally,
    ///      ties included. It is the pre-`TALLY` value only.
    enum Outcome {
        NONE,
        APPROVE,
        REJECT
    }

    /// @notice §8.2's index status. `NONE = 0` is what makes the other five mean
    ///         anything: an unwritten slot and a live interim status must not read
    ///         identically.
    enum IndexStatus {
        NONE,
        PLURALITY_APPROVE,
        PLURALITY_REJECT,
        APPROVED,
        REJECTED,
        UNRESOLVED
    }

    /// @notice §8.5's action type — what a claim ASKS about the content.
    /// @dev `LIST` asks "should this be shown"; `REMOVE` asks "should this be taken
    ///      down". It is a term in `claimKey` (§8.4), so the two questions about one
    ///      piece of content earn different keys and neither reservation binds the
    ///      other.
    ///
    ///      A **re-review is not here**, and §8.5 is explicit about why: a re-review
    ///      under its own action type would carry a different key, and the permanent
    ///      reservation it exists to escape would not bind it. `reopen` reopens a
    ///      claim in place. `REMOVE` is a genuinely different question and earns a
    ///      key; a re-review is the same question asked again and must not.
    enum ActionType {
        LIST,
        REMOVE
    }

    /// @notice Claim-key reservation (§8.4). Keyed on content and topics only —
    ///         `policyVersion` is deliberately absent, or a ruleset change would be
    ///         a scheduled amnesty an attacker could wait for.
    enum Reservation {
        FREE,
        LISTED, // APPROVED, reserved while listed
        PERMANENT, // REJECTED, and NO_RANDOMNESS by reference (I26)
        COOLDOWN // NO_REVEALS, for RETRY_COOLDOWN, pot carried forward

    }

    /// @notice An immutable parameter block. A case pins its version at submission
    ///         and every debit it produces is computed from that block (I27), never
    ///         from the live values.
    /// @dev Values left open by §1/§10 — `BOND_MIN`, `GAS_ALLOWANCE`,
    ///      `CHALLENGE_BOND`, `MATURATION`, `SUPER_QUORUM`, `RETRY_COOLDOWN` and
    ///      `DRAW_BOUNTY`'s sizing — are governance inputs here. This contract picks
    ///      no value and encodes no default.
    struct Params {
        uint32 blockTime; // seconds; the ONE wall-clock->block conversion input
        uint32 commitWindow; // seconds
        uint32 revealWindow; // seconds
        uint32 challengeWindow; // seconds
        uint32 lateWidenAt; // seconds into the commit phase (§3.3)
        uint32 seedLag; // blocks
        uint32 blockhashHorizon; // blocks
        uint32 retryCooldown; // seconds (§8.4; open — §4.8c)
        uint32 superQuorum; // §8.3; open (§1, §10) — no default, governance-set
        uint16 lateWidenFactorBps; // §3.3, 1.5x == 15_000
        uint16 drawBountyBps;
        uint16 claimBountyBps;
        uint16 reserveBps;
        uint16 maintenanceBps;
        uint128 lambda; // = d + G (§2.4)
        uint128 revealBond; // = d + G (§5.2)
        uint128 penaltyDebit; // d (§5.1)
        uint128 challengeBond;
        uint128 trackDecay; // WAD (§6)
        uint128 feeBase;
        uint128 feePerTopic;
        uint256 threshold; // T, so E[eligible] == TARGET_COHORT (§3.3)
    }

    /// @notice §4.1, verbatim in field set and width.
    /// @dev `phaseDeadline`, `eligSeedBlock` and `outcomeSeedBlock` are BLOCK
    ///      HEIGHTS. `finalizedAt` is a TIMESTAMP and is never compared — it is a
    ///      record (§0, I31).
    struct Case {
        uint8 phase;
        uint8 round; // 0 or 1
        uint8 terminal;
        uint8 unresolvedReason;
        uint32 paramsVersion; // I27
        uint40 phaseDeadline;
        uint40 eligSeedBlock; // armed at round open
        uint40 outcomeSeedBlock; // armed at submission, from the SCHEDULED heights
        uint8 plurality; // which side led at round-0 close; a FACT
        uint8 verdict; // written once, at the binding draw
        bool unanimousDraw; // §8.3 reads this; nothing reads `u` back
        // --- slot boundary ---
        uint128 pot; // NEVER grows: the reserve is added at settlement
        uint128 challengeReserve; // escrowed throughout
        // --- slot boundary ---
        uint128 drawBounty; // §1's fee split. §4.8 speaks of retaining the
        uint128 claimBounty; //   finalization bounty, which presupposes a field
        // --- slot boundary ---
        uint32 commitBlocks; // the three windows, converted ONCE at submission
        uint32 revealBlocks;
        uint32 challengeBlocks;
        uint32 pooledApprove; // POOLED across rounds, never reset
        uint32 pooledReject;
        uint32 commitsThisRound;
        uint32 revealsThisRound;
        uint32 reveals0; // round-0 reveal count, for §5.3 and §8.3
        // --- slot boundary ---
        address challenger;
        uint40 finalizedAt; // a TIMESTAMP — a record, never compared
        // --- slot boundary ---
        bytes32 outcomeEntropy; // blockhash(outcomeSeedBlock), stored at the draw
        bytes32 claimKey;
        bytes32 contentHash;
        bytes32 metaHash;
        address submitter;
        uint8 topicCount;
        uint8 actionType; // §8.5 — LIST or REMOVE; a term in `claimKey`
        uint32 guidelinesVersion; // §4.1 — pinned at submission, like `paramsVersion`
    }

    // =========================================================================
    // Storage
    // =========================================================================

    IERC20 public immutable token;
    StakeRegistry public immutable stakeReg;
    IIndexRegistry public immutable index;

    address public governor;

    uint32 public paramsVersion;

    /// @notice §4.1's guidelines version currently in force. A case pins it at
    ///         submission and is judged against that pin for its whole life.
    /// @dev **The deciding argument is FAIRNESS, not measurement.** `d` is charged
    ///      for voting incoherently with the settled side (§5.1). Without a pin, a
    ///      guidelines change mid-case means moderators who committed before read
    ///      one text and those after read another — and whichever side loses is
    ///      debited for correctly applying the instructions it was given. That is
    ///      I27's own argument applied to what a moderator is ASKED rather than to
    ///      what they are paid, and it is a stronger case for pinning than
    ///      parameters ever had.
    ///
    ///      The mid-case question therefore dissolves rather than being answered:
    ///      every moderator on a case reads the version pinned at its submission,
    ///      whatever governance does meanwhile.
    ///
    ///      **The version only, never the text.** The governor's log carries the
    ///      hash and the effective block; this carries which one applied. The
    ///      governor's height join remains the right tool for a READER recovering
    ///      text, and is not the authority for what a CASE was judged under.
    ///      **Declared here, beside `paramsVersion`, deliberately.** Two `uint32`s
    ///      share one slot. Placed after `paramBlocks` instead, it takes a slot of
    ///      its own AND shifts every storage slot below it — including the `cases`
    ///      mapping, whose slot number `DrawProperties.t.sol` writes tallies
    ///      through. That test's "did the write land" assertion caught the shift,
    ///      which is what it was put there for.
    uint32 public currentGuidelinesVersion;
    mapping(uint32 => Params) internal paramBlocks;


    uint256 public nextCaseId = 1;
    mapping(uint256 => Case) internal cases;
    mapping(uint256 => bytes32[MAX_TOPICS]) internal caseTopics;

    /// @dev I3 — the allowance is per CLAIM, across rounds, and `commit` consumes
    ///      it. Scoping it to reveals would let a moderator commit in round 0,
    ///      abandon for the price of `REVEAL_BOND`, and re-enter in round 1 with the
    ///      round-0 tally in hand.
    mapping(uint256 => mapping(address => bytes32)) internal commitments;
    mapping(uint256 => mapping(address => uint8)) internal revealedVote; // Outcome
    mapping(uint256 => mapping(address => bool)) internal voteSettled;
    mapping(uint256 => bool) internal challengeSettled;

    /// @dev §8.3 — whether this case currently holds an open question against its
    ///      own index entries. A re-review OPENS one; its terminal CLOSES it. Not a
    ///      §4.1 field: it is index bookkeeping, not case state.
    mapping(uint256 => bool) internal questionOpen;

    /// @dev Open vote claims this contract holds against a case. §8.5 assumes prior
    ///      voters are settled before a re-review; settlement is pull-based and may
    ///      never complete, so `reopen` REQUIRES what §8.5 assumes. See the report.
    mapping(uint256 => uint256) public openVoteClaims;

    mapping(bytes32 => Reservation) public reservationOf;
    mapping(bytes32 => uint256) public reservedUntil; // COOLDOWN only
    mapping(bytes32 => uint256) public carriedPot; // NO_REVEALS carries the pot

    /// @dev Refunds are PULLED, not pushed. A push inside a terminal transition
    ///      lets a submitter contract that reverts brick the transition for
    ///      everyone. See DEVIATIONS D3-3.
    mapping(uint256 => uint256) public refundOwed;

    /// @notice What this contract has accrued for the maintenance reserve since the
    ///         last sweep: `maintenance` from the fee (§1), §5.3's division
    ///         remainder, and `CLAIM_BOUNTY` retained on `UNRESOLVED` (§4.8).
    /// @dev An ACCUMULATOR, not a pool. §5.6 makes the registry's reserve the one
    ///      pool; `sweepMaintenance` forwards this into it. Nothing reads it between
    ///      sweeps, which is why the forwarding is lazy rather than per-terminal.
    uint256 public maintenanceAccrued;

    // =========================================================================
    // Events
    // =========================================================================

    event ParamsApplied(uint32 indexed version);

    /// @dev The governor allocates the version and pushes it here. `Moderation`
    ///      stores no text and no hash — only which version is in force.
    event GuidelinesApplied(uint32 indexed version);
    event Submitted(uint256 indexed caseId, address indexed submitter, bytes32 indexed claimKey, uint256 fee);

    /// @notice A removal carried and the LIST claim's entries left the index.
    /// @dev Emitted once per case, not once per topic: the fifth write is
    ///      `O(MAX_TOPICS)` but the FACT it establishes is one fact about one claim.
    event ListingRemoved(uint256 indexed caseId, bytes32 indexed listClaimKey);
    event Committed(uint256 indexed caseId, address indexed m, uint8 round);
    event Revealed(uint256 indexed caseId, address indexed m, uint8 vote);
    event Challenged(uint256 indexed caseId, address indexed challenger);
    event PhaseChanged(uint256 indexed caseId, uint8 from, uint8 to, uint8 round);
    event PluralityPublished(uint256 indexed caseId, uint8 plurality, uint32 approve, uint32 reject);
    event Drawn(uint256 indexed caseId, uint8 verdict, uint8 tickets, bytes32 entropy);
    event Terminated(uint256 indexed caseId, uint8 terminal, uint8 reason);
    event VoteClaimSettled(uint256 indexed caseId, address indexed m);
    event ChallengeClaimSettled(uint256 indexed caseId, address indexed challenger);
    event Reopened(uint256 indexed caseId, address indexed by, uint256 fee);
    event BountyPaid(uint256 indexed caseId, address indexed to, uint256 amount);
    event Refunded(uint256 indexed caseId, address indexed to, uint256 amount);
    event MaintenanceSwept(address indexed by, uint256 amount);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotGovernor();
    error ZeroAddress();
    error WrongPhase();
    error DeadlineNotReached();
    error DeadlinePassed();
    error AlreadyCommitted();
    error NotCommitted();
    error NotEligible();
    error CannotCommit();
    error CannotChallenge();
    error AlreadyChallenged();
    error BadReveal();
    error AlreadyRevealed();
    error SeedNotYet();
    error SeedExpired();
    error NoSuchCase();
    error NotTerminal();
    error AlreadySettled();
    error KeyReserved();
    error NotListed();
    error FeeTooLow();
    error TooManyTopics();
    error ZeroTopic();
    error BadParams();
    error GuidelinesNotMonotonic();
    error CommitWindowExceedsSeedHorizon();
    error NotReopenable();
    error ClaimsOutstanding();
    error NothingToRefund();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IERC20 _token, StakeRegistry _stakeReg, IIndexRegistry _index, address _governor) {
        if (
            address(_token) == address(0) || address(_stakeReg) == address(0) || address(_index) == address(0)
                || _governor == address(0)
        ) revert ZeroAddress();
        if (_stakeReg.KIND_VOTE() != KIND_VOTE || _stakeReg.KIND_CHALLENGE() != KIND_CHALLENGE) revert BadParams();
        token = _token;
        stakeReg = _stakeReg;
        index = _index;
        governor = _governor;
    }

    // =========================================================================
    // Parameters
    // =========================================================================

    /// @dev The one hard bound §10 states and §3.1 derives:
    ///      `commitBlocks <= SEED_LAG + BLOCKHASH_HORIZON`. Below it a governance
    ///      change does not fail loudly — it re-points the tail of every commit
    ///      window at a seed block that does not exist yet.
    function applyParams(Params calldata p) external onlyGovernor returns (uint32 v) {
        if (p.blockTime == 0 || p.commitWindow == 0 || p.revealWindow == 0 || p.challengeWindow == 0) {
            revert BadParams();
        }
        if (p.blockhashHorizon == 0) revert BadParams();
        if (p.lateWidenAt > p.commitWindow) revert BadParams();
        if (p.lateWidenFactorBps < BPS) revert BadParams();
        if (p.trackDecay == 0 || p.trackDecay >= WAD) revert BadParams();
        if (uint256(p.drawBountyBps) + p.claimBountyBps + p.reserveBps + p.maintenanceBps >= BPS) revert BadParams();

        uint256 cb = _ceilDiv(p.commitWindow, p.blockTime);
        if (cb > uint256(p.seedLag) + uint256(p.blockhashHorizon)) revert CommitWindowExceedsSeedHorizon();

        v = ++paramsVersion;
        paramBlocks[v] = p;
        emit ParamsApplied(v);
    }

    function paramsAt(uint32 v) external view returns (Params memory) {
        return paramBlocks[v];
    }

    /// @notice §4.1 — record the guidelines version now in force.
    /// @dev The governor ALLOCATES the version (it owns the version-to-hash record
    ///      and the effective-block map) and pushes the number here. Two reasons it
    ///      is a push and not a pull:
    ///
    ///      A pull would put an external call on the `submit` path, on every case,
    ///      to read a number that changes only by governance action. It would also
    ///      make `Moderation` depend on the governor's ABI, so a `governor` that is
    ///      a plain address — which is every test fixture that does not need
    ///      governance, and any future governor with a different surface — would
    ///      revert every submission.
    ///
    ///      **Monotonic, enforced here and not only upstream.** The governor is the
    ///      allocator today; this contract still refuses to move backwards, because
    ///      a pinned version that could be reused would let two different guideline
    ///      texts share a number and silently merge the cases decided under them.
    ///      The check also makes divergence one-directional: this contract can lag
    ///      the governor only if a push reverted, and a reverting push reverts the
    ///      whole `executeGuidelines`.
    function applyGuidelines(uint32 v) external onlyGovernor {
        if (v <= currentGuidelinesVersion) revert GuidelinesNotMonotonic();
        currentGuidelinesVersion = v;
        emit GuidelinesApplied(v);
    }

    function _p(uint256 caseId) internal view returns (Params storage) {
        return paramBlocks[cases[caseId].paramsVersion];
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // =========================================================================
    // §4.3 — submit
    // =========================================================================

    /// @dev The three windows are converted to block counts HERE and nowhere else.
    ///      That is the only wall-clock->block conversion in the system (§0, I31).
    function submit(bytes32 contentHash, bytes32 metaHash, bytes32[] calldata topics, uint256 fee)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        return _submit(uint8(ActionType.LIST), contentHash, metaHash, topics, fee);
    }

    /// @notice §8.5's removal case — "should this listed content be taken down".
    /// @dev **The same engine.** Same cohort, same `â`, same three tickets, same
    ///      challenge round, same settlement; `actionType` changes what the answer
    ///      is ABOUT, never how it is reached. Everything below the precondition is
    ///      `_submit`, shared verbatim with a listing.
    ///
    ///      `verdict == APPROVE` on this claim means **remove it**.
    ///
    ///      The precondition is a LIVENESS requirement, not a policy choice, and it
    ///      is the answer to the order's open question 3. `removeListing` reverts
    ///      `NoSuchEntry` on an entry that was never written. Without the guard a
    ///      removal naming a topic the LIST claim never carried would take a fee,
    ///      spend a cohort's attention, reach the draw — and then revert INSIDE
    ///      `_finalize`, on every call, forever. The case would be unfinalizable and
    ///      every bond committed to it unrecoverable. The guard is what makes the
    ///      fifth write total, and the argument is in DEVIATIONS D3-18.
    function submitRemoval(bytes32 contentHash, bytes32 metaHash, bytes32[] calldata topics, uint256 fee)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        // The LIST key is COMPUTED from this case's own fields (§8.2b) — no stored
        // pointer. That is why a removal must name the same content, metadata and
        // topics as the listing it targets: the key it targets IS those fields.
        bytes32 listKey = claimKeyOf(uint8(ActionType.LIST), contentHash, metaHash, topics);

        uint256 n = topics.length;
        for (uint256 i; i < n; ++i) {
            if (!index.isListed(listKey, topics[i])) revert NotListed();
        }

        caseId = _submit(uint8(ActionType.REMOVE), contentHash, metaHash, topics, fee);

        // §8.3 — a removal is an open question against the LIST entries, and
        // SUPER_SAFE must stop reading true the moment it opens. The question is
        // against the LIST claim's entries, NOT this case's own.
        questionOpen[caseId] = true;
        for (uint256 i; i < n; ++i) {
            index.openQuestion(listKey, topics[i]);
        }
    }

    function _submit(
        uint8 actionType,
        bytes32 contentHash,
        bytes32 metaHash,
        bytes32[] calldata topics,
        uint256 fee
    ) internal returns (uint256 caseId) {
        uint32 v = paramsVersion;
        if (v == 0) revert BadParams();
        Params storage p = paramBlocks[v];

        uint256 n = topics.length;
        if (n == 0 || n > MAX_TOPICS) revert TooManyTopics();
        for (uint256 i; i < n; ++i) {
            if (topics[i] == bytes32(0)) revert ZeroTopic(); // §8.2b, I29
        }
        if (fee < uint256(p.feeBase) + uint256(p.feePerTopic) * n) revert FeeTooLow();

        bytes32 key = claimKeyOf(actionType, contentHash, metaHash, topics);
        _requireKeyFree(key, p);

        address(token).safeTransferFrom(msg.sender, address(this), fee);

        caseId = nextCaseId++;
        Case storage c = cases[caseId];

        // §7.2 — every height below is derived from a schedule, never from a
        // transaction's timing (I7).
        uint32 commitBlocks = uint32(_ceilDiv(p.commitWindow, p.blockTime));
        uint32 revealBlocks = uint32(_ceilDiv(p.revealWindow, p.blockTime));
        uint32 challengeBlocks = uint32(_ceilDiv(p.challengeWindow, p.blockTime));

        c.phase = uint8(Phase.COMMIT);
        c.round = 0;
        c.paramsVersion = v;
        c.commitBlocks = commitBlocks;
        c.revealBlocks = revealBlocks;
        c.challengeBlocks = challengeBlocks;
        c.claimKey = key;
        c.contentHash = contentHash;
        c.metaHash = metaHash;
        c.submitter = msg.sender;
        c.topicCount = uint8(n);
        c.actionType = actionType;
        // §4.1 — pinned here and nowhere else, exactly like `paramsVersion`.
        // NOT re-pinned by `reopen`: a re-review reopens the claim IN PLACE
        // (§8.5), the pooled tally carries, and the earlier cohort's votes are
        // evidence in the same question. Re-pinning would judge one tally against
        // two texts, which is the split this field exists to prevent.
        c.guidelinesVersion = currentGuidelinesVersion;
        for (uint256 i; i < n; ++i) {
            caseTopics[caseId][i] = topics[i];
        }

        // §1's four components. `pot` takes the residue and never grows after this.
        uint256 drawB = (fee * p.drawBountyBps) / BPS;
        uint256 claimB = (fee * p.claimBountyBps) / BPS;
        uint256 reserve = (fee * p.reserveBps) / BPS;
        uint256 maint = (fee * p.maintenanceBps) / BPS;
        uint256 pot = fee - drawB - claimB - reserve - maint;

        // §8.4 — a NO_REVEALS retry carries the pot forward with no fresh fee.
        pot += carriedPot[key];
        carriedPot[key] = 0;

        c.pot = uint128(pot);
        c.challengeReserve = uint128(reserve);
        c.drawBounty = uint128(drawB);
        c.claimBounty = uint128(claimB);
        maintenanceAccrued += maint;

        c.phaseDeadline = uint40(block.number + commitBlocks);
        c.eligSeedBlock = uint40(block.number + p.seedLag);
        c.outcomeSeedBlock = uint40(
            block.number + uint256(commitBlocks) + revealBlocks // round 0
                + challengeBlocks + uint256(commitBlocks) + revealBlocks // round 1, ALWAYS
                + p.seedLag
        );

        reservationOf[key] = Reservation.LISTED; // held while the case is live

        emit Submitted(caseId, msg.sender, key, fee);
        emit PhaseChanged(caseId, uint8(Phase.NONE), uint8(Phase.COMMIT), 0);
    }

    /// @notice §8.4 — `claimKey = H(actionType, contentHash, metaHash, topics)`.
    /// @dev `policyVersion` is deliberately NOT in the key. A key containing the
    ///      version cannot produce a reservation that survives a version bump, which
    ///      would make every ruleset change a scheduled amnesty an attacker could
    ///      wait for.
    ///
    ///      `actionType` IS in the key, and that is what lets one piece of content
    ///      carry two live questions — "show this" and "take this down" — without
    ///      either reservation binding the other. It hardcoded `"LIST"` until M2.10,
    ///      which is why the removal case could not be created (D3-15).
    function claimKeyOf(uint8 actionType, bytes32 contentHash, bytes32 metaHash, bytes32[] calldata topics)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(actionType, contentHash, metaHash, topics));
    }

    /// @dev The same derivation over a MEMORY topics array, for the two sites that
    ///      recompute a LIST key from a stored case (§8.2b: computed, never stored).
    ///      `abi.encode` of a memory and a calldata `bytes32[]` are identical, and
    ///      `test_s8_4_memoryAndCalldataKeyDerivationsAgree` holds that.
    function _claimKeyMem(uint8 actionType, bytes32 contentHash, bytes32 metaHash, bytes32[] memory topics)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(actionType, contentHash, metaHash, topics));
    }

    /// @dev The LIST claim a removal case targets, recomputed from the case's own
    ///      fields. §2.2 of the M2.10 order: both entry keys are content-derived, so
    ///      NO STORED POINTER is needed — and a stored one could disagree with the
    ///      content, which a derived one cannot.
    function _listClaimKey(uint256 caseId) internal view returns (bytes32) {
        Case storage c = cases[caseId];
        uint256 n = c.topicCount;
        bytes32[] memory t = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            t[i] = caseTopics[caseId][i];
        }
        return _claimKeyMem(uint8(ActionType.LIST), c.contentHash, c.metaHash, t);
    }

    /// @notice The claim key an open question is recorded against.
    /// @dev A re-review reopens the LIST claim in place, so its question is against
    ///      that claim's own entries. A REMOVAL is a separate claim asking about
    ///      SOMEONE ELSE'S entries, so its question is against the LIST claim's.
    ///      One function, so open and close cannot disagree about where the question
    ///      was recorded — which would leak a permanently non-zero `openQuestions`
    ///      and pin `SUPER_SAFE` false forever.
    function _questionKey(uint256 caseId) internal view returns (bytes32) {
        Case storage c = cases[caseId];
        if (c.actionType == uint8(ActionType.REMOVE)) return _listClaimKey(caseId);
        return c.claimKey;
    }

    function _requireKeyFree(bytes32 key, Params storage p) internal view {
        Reservation r = reservationOf[key];
        if (r == Reservation.FREE) return;
        if (r == Reservation.COOLDOWN && block.timestamp >= reservedUntil[key]) return;
        p; // RETRY_COOLDOWN is pinned into `reservedUntil` at the terminal
        revert KeyReserved();
    }

    // =========================================================================
    // §3.1 — eligibility
    // =========================================================================

    /// @dev Both guards are BLOCK-HEIGHT COMPARISONS, never observations of the
    ///      returned hash (I29). `blockhash` returns zero for a block that has
    ///      expired AND for one that has not happened yet, and the head gap is not
    ///      a tail edge case: it is the first `SEED_LAG + 1` blocks of EVERY commit
    ///      phase. Unguarded, every moderator would be evaluated against
    ///      `roundSeed = 0` — a set computable from `caseId` at submission.
    function _eligible(uint256 caseId, address m) internal view returns (bool) {
        Case storage c = cases[caseId];
        Params storage p = _p(caseId);
        uint256 sb = c.eligSeedBlock;
        if (block.number <= sb) revert SeedNotYet();
        if (block.number > sb + p.blockhashHorizon) revert SeedExpired();

        bytes32 seed = blockhash(sb);
        uint256 h = uint256(
            keccak256(abi.encode(ELIGIBILITY_DOMAIN, block.chainid, address(this), caseId, c.round, seed, m))
        );
        return h < _threshold(c, p);
    }

    /// @dev §3.3 — the widening schedule is fixed when the round opens and is not
    ///      conditional on how many commitments have arrived. `lateWidenAt` is
    ///      scaled from the already-converted `commitBlocks` rather than converted
    ///      separately, so there is still exactly one wall-clock->block conversion
    ///      per case (I31).
    function _threshold(Case storage c, Params storage p) internal view returns (uint256) {
        uint256 roundOpen = uint256(c.phaseDeadline) - c.commitBlocks;
        uint256 widenAt = roundOpen + (uint256(c.commitBlocks) * p.lateWidenAt) / p.commitWindow;
        if (block.number < widenAt) return p.threshold;
        return (p.threshold * p.lateWidenFactorBps) / BPS;
    }

    function isEligible(uint256 caseId, address m) external view returns (bool) {
        return _eligible(caseId, m);
    }

    // =========================================================================
    // §4.3 — the non-phase writers
    // =========================================================================

    /// @dev I3: the check is "has not committed to `c` in ANY round".
    function commit(uint256 caseId, bytes32 h) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.COMMIT)) revert WrongPhase();
        if (block.number >= c.phaseDeadline) revert DeadlinePassed();
        if (commitments[caseId][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (!_eligible(caseId, msg.sender)) revert NotEligible();

        Params storage p = _p(caseId);
        if (!stakeReg.mayCommit(msg.sender, p.lambda)) revert CannotCommit();

        commitments[caseId][msg.sender] = h;
        c.commitsThisRound += 1;
        openVoteClaims[caseId] += 1;
        stakeReg.createVoteClaim(msg.sender, caseId, p.lambda);

        emit Committed(caseId, msg.sender, c.round);
    }

    /// @dev The preimage binds chainId, this contract, the case, the ROUND and
    ///      `paramsVersion`, so a round-0 commitment cannot be revealed in round 1.
    function reveal(uint256 caseId, uint8 v, bytes32 salt) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.REVEAL)) revert WrongPhase();
        if (block.number >= c.phaseDeadline) revert DeadlinePassed();
        if (v != uint8(Outcome.APPROVE) && v != uint8(Outcome.REJECT)) revert BadReveal();
        if (revealedVote[caseId][msg.sender] != 0) revert AlreadyRevealed();

        bytes32 h = commitments[caseId][msg.sender];
        if (h == bytes32(0)) revert NotCommitted();
        if (h != commitHash(caseId, c.round, c.paramsVersion, msg.sender, v, salt)) revert BadReveal();

        revealedVote[caseId][msg.sender] = v;
        c.revealsThisRound += 1;
        if (v == uint8(Outcome.APPROVE)) c.pooledApprove += 1;
        else c.pooledReject += 1;

        emit Revealed(caseId, msg.sender, v);
    }

    function commitHash(uint256 caseId, uint8 round, uint32 pv, address m, uint8 v, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(COMMIT_DOMAIN, block.chainid, address(this), caseId, round, pv, m, v, salt));
    }

    /// @dev §4.3's `TALLY -> TALLY` row. REGISTERS ONLY: no transfer, no phase
    ///      change, no seed armed, no deadline moved. The bond is COVERED, not
    ///      escrowed. A second call reverts (I17).
    ///
    ///      No eligibility test, for any round (§3.5) — it was circular, it excluded
    ///      the round-0 dissenting minority the mechanism depends on, and a
    ///      probabilistic filter on who may PAY is regressive.
    function challenge(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.TALLY)) revert WrongPhase();
        if (block.number >= c.phaseDeadline) revert DeadlinePassed();
        if (c.challenger != address(0)) revert AlreadyChallenged();

        Params storage p = _p(caseId);
        if (!stakeReg.mayChallenge(msg.sender, p.challengeBond)) revert CannotChallenge();

        c.challenger = msg.sender;
        stakeReg.createChallengeClaim(msg.sender, caseId, p.challengeBond);

        emit Challenged(caseId, msg.sender);
    }

    // =========================================================================
    // §4.3 — phase transitions. All permissionless.
    // =========================================================================

    /// @dev `COMMIT -> REVEAL` and `COMMIT(r=0) -> UNRESOLVED(NO_TURNOUT)`.
    ///      There is NO quorum gate: §4.8b removed `MIN_COMMITS` as a parameter
    ///      rather than lowering it. `NO_TURNOUT` means an EMPTY round, not a thin
    ///      one, and round 1 has no gate at all (§4.9).
    function closeCommit(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.COMMIT)) revert WrongPhase();
        if (block.number < c.phaseDeadline) revert DeadlineNotReached();

        if (c.round == 0 && c.commitsThisRound == 0) {
            _toUnresolved(caseId, Reason.NO_TURNOUT);
            return;
        }

        Params storage p = _p(caseId);
        c.phase = uint8(Phase.REVEAL);
        c.phaseDeadline = uint40(block.number + c.revealBlocks);
        p;
        emit PhaseChanged(caseId, uint8(Phase.COMMIT), uint8(Phase.REVEAL), c.round);
    }

    /// @dev `REVEAL(r=0) -> TALLY | UNRESOLVED(NO_REVEALS)` and
    ///      `REVEAL(r=1) -> DRAW`. Round 1 has no threshold (§4.6) and needs none
    ///      (§4.9): an empty round 1 leaves the pooled tally identical, so the draw
    ///      sees what it would have seen.
    function closeReveal(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.REVEAL)) revert WrongPhase();
        if (block.number < c.phaseDeadline) revert DeadlineNotReached();

        uint256 pooled = uint256(c.pooledApprove) + c.pooledReject;

        if (c.round == 1) {
            c.phase = uint8(Phase.DRAW);
            emit PhaseChanged(caseId, uint8(Phase.REVEAL), uint8(Phase.DRAW), 1);
            return;
        }

        if (pooled == 0) {
            _toUnresolved(caseId, Reason.NO_REVEALS);
            return;
        }

        // §4.2 — the plurality is TOTAL, ties included, and it is a FACT about the
        // votes. No randomness has been realized. It decides who OWES, never who
        // wins.
        c.plurality = c.pooledApprove > c.pooledReject ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);
        c.reveals0 = c.revealsThisRound;
        c.phase = uint8(Phase.TALLY);
        c.phaseDeadline = uint40(block.number + c.challengeBlocks);

        _writeIndex(caseId, c.plurality == uint8(Outcome.APPROVE) ? IndexStatus.PLURALITY_APPROVE : IndexStatus.PLURALITY_REJECT);

        emit PluralityPublished(caseId, c.plurality, c.pooledApprove, c.pooledReject);
        emit PhaseChanged(caseId, uint8(Phase.REVEAL), uint8(Phase.TALLY), 0);
    }

    /// @dev `TALLY -> COMMIT` (challenged) or `TALLY -> DRAW` (not).
    ///      On the challenged path this resets BOTH per-round counters (I19) and
    ///      arms the round-1 ELIGIBILITY seed only — there is no second outcome
    ///      seed (§7.1). `challengeReserve` is not touched: it activates at
    ///      settlement, so opening a round moves no value.
    function closeTally(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.TALLY)) revert WrongPhase();
        if (block.number < c.phaseDeadline) revert DeadlineNotReached();

        if (c.challenger == address(0)) {
            c.phase = uint8(Phase.DRAW);
            emit PhaseChanged(caseId, uint8(Phase.TALLY), uint8(Phase.DRAW), 0);
            return;
        }

        Params storage p = _p(caseId);
        c.round = 1;
        c.commitsThisRound = 0;
        c.revealsThisRound = 0; // I19 — the field this rule exists for
        c.phase = uint8(Phase.COMMIT);
        // §3.5b — round 1 opens at the SCHEDULED close, never at the challenge.
        c.eligSeedBlock = uint40(block.number + p.seedLag);
        c.phaseDeadline = uint40(block.number + c.commitBlocks);

        emit PhaseChanged(caseId, uint8(Phase.TALLY), uint8(Phase.COMMIT), 1);
    }

    /// @dev `DRAW -> FINALIZED` and `DRAW -> UNRESOLVED(NO_RANDOMNESS)`.
    ///
    ///      NOTE THE ABSENT GUARD. There is no `N > 0` check, deliberately. The draw
    ///      does not divide — `â`'s denominator is `N + 2` and the ticket comparison
    ///      is cross-multiplied — and `N >= 1` is a structural fact, not a
    ///      condition: §4.3 routes `pooled == 0` to `NO_REVEALS` and the pooled
    ///      tally never decreases, so `DRAW` is unreachable with an empty tally.
    ///      A revert inside `DRAW` strands the case forever, so adding the guard
    ///      would convert an impossible state into a permanent one.
    ///
    ///      The two height guards are I29 comparisons, never observations of the
    ///      returned hash. `DRAW` is entered up to ~40 minutes before
    ///      `outcomeSeedBlock` on the unchallenged path, and an implementation
    ///      testing the hash would let any party terminate a live case in that
    ///      window while collecting `DRAW_BOUNTY`.
    function draw(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        if (c.phase != uint8(Phase.DRAW)) revert WrongPhase();
        Params storage p = _p(caseId);

        // A re-review draws from stored entropy: one randomness per claim, for the
        // LIFE of the claim (§4.5, §8.5). It cannot expire and must not re-roll.
        if (c.outcomeEntropy != bytes32(0)) {
            _finalize(caseId, c.outcomeEntropy);
            return;
        }

        if (uint256(c.pooledApprove) + c.pooledReject == 0) revert WrongPhase();
        uint256 sb = c.outcomeSeedBlock;
        if (block.number > sb + p.blockhashHorizon) {
            _payBounty(caseId, false, msg.sender);
            _toUnresolved(caseId, Reason.NO_RANDOMNESS);
            return;
        }
        if (block.number <= sb) revert SeedNotYet();

        _finalize(caseId, blockhash(sb));
    }

    function _finalize(uint256 caseId, bytes32 entropy) internal {
        Case storage c = cases[caseId];
        Params storage p = _p(caseId);

        c.outcomeEntropy = entropy;
        (uint8 verdict, uint8 tickets) = _decide(caseId, entropy);

        c.verdict = verdict;
        c.unanimousDraw = (tickets == 0 || tickets == 3);
        c.terminal = verdict == uint8(Outcome.APPROVE) ? uint8(Terminal.APPROVED) : uint8(Terminal.REJECTED);
        c.phase = uint8(Phase.FINALIZED);
        c.finalizedAt = uint40(block.timestamp); // a record, never compared

        // §8.4 — APPROVED is reserved while listed; REJECTED permanently.
        reservationOf[c.claimKey] =
            verdict == uint8(Outcome.APPROVE) ? Reservation.LISTED : Reservation.PERMANENT;

        // §5.3 — the unspent reserve returns to the submitter, who prepaid for a
        // round that did not happen at the size it was priced for.
        uint256 activated = _activated(caseId);
        refundOwed[caseId] += uint256(c.challengeReserve) - activated;

        _writeIndex(caseId, verdict == uint8(Outcome.APPROVE) ? IndexStatus.APPROVED : IndexStatus.REJECTED);

        // §8.1's FIFTH WRITE — the only write that reaches outside its own claim
        // key, and the exit the circle lacked (D3-15).
        //
        // A removal that CARRIES sets the LIST entry to REMOVED and drops it from
        // the topic's listing. A removal that FAILS writes its own entry above and
        // touches nothing else: "RETAINED" is this case's terminal, not a status
        // any LIST entry takes.
        if (c.actionType == uint8(ActionType.REMOVE) && verdict == uint8(Outcome.APPROVE)) {
            bytes32 listKey = _listClaimKey(caseId);
            uint256 nt = c.topicCount;
            for (uint256 i; i < nt; ++i) {
                index.removeListing(listKey, caseTopics[caseId][i]);
            }

            // §2.4 — the LIST claim's reservation clears to FREE, and that single
            // assignment is what makes the content RESUBMITTABLE. §8.4 reserves an
            // APPROVED key "while listed"; the content is no longer listed, so the
            // condition the reservation was held under has lapsed and the key must
            // follow it. Leaving it LISTED is the permanence this order exists to
            // break: removed, unlistable, and unresubmittable at once.
            //
            // FREE and not PERMANENT: a removal says THIS content should not be
            // shown as it stands, which is a judgement about the content, not about
            // whether the question may ever be asked again. I26 is not engaged —
            // it binds the claim that was tallied, and the claim tallied here is the
            // REMOVE claim, whose own key stays reserved by the branch above.
            reservationOf[listKey] = Reservation.FREE;
            emit ListingRemoved(caseId, listKey);
        }

        _payBounty(caseId, true, msg.sender);

        emit Drawn(caseId, verdict, tickets, entropy);
        emit Terminated(caseId, c.terminal, uint8(Reason.NONE));
    }

    /// @notice §4.5's draw, as a pure function of the stored entropy and the pooled
    ///         tally — so a re-review re-derives an identical verdict after
    ///         `blockhash` has expired.
    /// @dev Two forms that are wrong and would pass a naive test:
    ///
    ///      `A/N` instead of `â`. At a unanimous tally `f(1) = 1` and one revealed
    ///      vote decides the case with certainty; I12 is false under it.
    ///
    ///      `u mod (N+2) < A+1` instead of the cross-multiplied comparison. Both are
    ///      uniform and both give `f(â)`; only the cross-multiplied form is MONOTONE
    ///      in `â` (I22), and monotonicity is the entire reason a challenge cannot
    ///      buy a re-roll. The modulo form reshuffles on every change of `N`, so one
    ///      added vote acts as a fresh draw.
    function _decide(uint256 caseId, bytes32 entropy) internal view returns (uint8 verdict, uint8 tickets) {
        Case storage c = cases[caseId];
        uint256 den = uint256(c.pooledApprove) + c.pooledReject + 2; // N + 2, >= 2 ALWAYS
        uint256 num = uint256(c.pooledApprove) + 1; // A + 1

        for (uint256 i; i < 3; ++i) {
            uint256 u = uint128(
                uint256(keccak256(abi.encode(OUTCOME_DOMAIN, block.chainid, address(this), caseId, i, entropy)))
            );
            if (u * den < num << 128) tickets += 1;
        }
        verdict = tickets >= 2 ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);
    }

    function decideAt(uint256 caseId, bytes32 entropy) external view returns (uint8 verdict, uint8 tickets) {
        return _decide(caseId, entropy);
    }

    /// @dev §4.8. `terminal` is written here and by `_finalize`, and by no other
    ///      site. The index entry is written at THIS transition, in
    ///      `O(MAX_TOPICS)` — never at settlement (§8.1, I15) — for all three
    ///      reasons, because a reader must distinguish "judged, undrawn" from
    ///      "never submitted".
    function _toUnresolved(uint256 caseId, Reason r) internal {
        Case storage c = cases[caseId];
        c.terminal = uint8(Terminal.UNRESOLVED);
        c.unresolvedReason = uint8(r);
        c.phase = uint8(Phase.UNRESOLVED);

        // §4.8's value flow: refund pot + challengeReserve IN FULL. The reserve
        // never activates here, because activation requires a verdict and none was
        // drawn. Maintenance and the finalization bounty are retained.
        refundOwed[caseId] += uint256(c.pot) + uint256(c.challengeReserve);

        // §8.4's retry rule, per reason.
        //
        // I26 — once a claim has been TALLIED, no reachable terminal releases its
        // key. The pooled tally never decreases and carries across a re-review
        // (§8.5), so `pooled >= 1` IS "this claim has been tallied". §8.4's table
        // is written for a first opening and its `NO_TURNOUT` and `NO_REVEALS`
        // rows would otherwise release the key of a claim a PREVIOUS opening had
        // tallied and permanently reserved. Stating the invariant here rather
        // than special-casing re-review keeps the two rows honest for both.
        bytes32 key = c.claimKey;
        bool tallied = (uint256(c.pooledApprove) + c.pooledReject) >= 1;
        if (tallied) {
            reservationOf[key] = Reservation.PERMANENT;
        } else if (r == Reason.NO_TURNOUT) {
            // Not reserved, free retry: no draw occurred and nobody could have
            // caused it (commits are blind).
            reservationOf[key] = Reservation.FREE;
        } else if (r == Reason.NO_REVEALS) {
            // Steerable by a party holding every commit, so not free; the submitter
            // did not cause it, so not levied. The pot carries forward.
            reservationOf[key] = Reservation.COOLDOWN;
            reservedUntil[key] = block.timestamp + _p(caseId).retryCooldown;
            carriedPot[key] = c.pot;
            refundOwed[caseId] -= c.pot;
        } else {
            // NO_RANDOMNESS is TALLIED, so I26 binds: no reachable terminal
            // releases the key. It carries REJECTED's reservation BY REFERENCE.
            reservationOf[key] = Reservation.PERMANENT;
        }

        _settleBounties(caseId);
        _writeIndex(caseId, IndexStatus.UNRESOLVED);

        emit Terminated(caseId, uint8(Terminal.UNRESOLVED), uint8(r));
    }

    /// @dev `O(MAX_TOPICS)`, at the transition establishing a terminal or at
    ///      `TALLY`. `NO_RANDOMNESS` retains the published plurality beside the
    ///      `UNRESOLVED` status, since that is what was established.
    function _writeIndex(uint256 caseId, IndexStatus s) internal {
        Case storage c = cases[caseId];
        uint256 n = c.topicCount;
        bytes32 key = c.claimKey;
        uint8 plur = c.plurality;
        uint8 act = c.actionType;
        bool strict = (s == IndexStatus.APPROVED) && _strict(caseId);
        for (uint256 i; i < n; ++i) {
            index.writeEntry(key, caseTopics[caseId][i], uint8(s), plur, strict, act);
        }

        // §8.3 — the question this re-review or removal opened is resolved at its
        // terminal. Guarded by `s`, because the interim TALLY write is not a
        // terminal. Closed against `_questionKey`, which is the LIST claim for a
        // removal and this claim for a re-review — the same function `openQuestion`
        // was called through, so the two cannot disagree.
        if (questionOpen[caseId] && s != IndexStatus.PLURALITY_APPROVE && s != IndexStatus.PLURALITY_REJECT) {
            questionOpen[caseId] = false;
            bytes32 qk = _questionKey(caseId);
            for (uint256 i; i < n; ++i) {
                index.closeQuestion(qk, caseTopics[caseId][i]);
            }
        }
    }

    /// @dev §8.3's STATIC half — every conjunct is a tally fact, all known at the
    ///      terminal, so the bit can never go stale. The live half (`openQuestions`)
    ///      is the index's, maintained from `reopen` and its terminal.
    ///
    ///      `SUPER_QUORUM` is open (§1, §10), so it is a governance parameter pinned
    ///      per case like every other. The 3/3 conjunct is included as §8.3 states
    ///      it; §10 has whether it should be there at all, and this order does not
    ///      decide it.
    ///      The `actionType` conjunct is not redundant with `verdict == APPROVE`.
    ///      On a REMOVE claim, Approve means *remove it*, so without it a unanimous
    ///      successful removal would stamp SUPER_SAFE onto the removal's own entry —
    ///      reading "certified safe" off the record of a takedown.
    function _strict(uint256 caseId) internal view returns (bool) {
        Case storage c = cases[caseId];
        uint256 reveals = uint256(c.pooledApprove) + c.pooledReject;
        return c.actionType == uint8(ActionType.LIST) && c.verdict == uint8(Outcome.APPROVE)
            && c.challenger == address(0) && c.unanimousDraw
            && reveals >= _p(caseId).superQuorum && c.pooledReject == 0 && reveals == uint256(c.commitsThisRound);
    }

    /// @dev Bounties were carved from the fee at submission and `pot` never held
    ///      them. Each is paid at most once and zeroed, so a re-review's second
    ///      draw cannot pay a bounty the first already spent.
    function _payBounty(uint256 caseId, bool alsoClaimBounty, address to) internal {
        Case storage c = cases[caseId];
        uint256 amount = c.drawBounty;
        c.drawBounty = 0;
        if (alsoClaimBounty) {
            amount += c.claimBounty;
            c.claimBounty = 0;
        }
        if (amount == 0) return;
        address(token).safeTransfer(to, amount);
        emit BountyPaid(caseId, to, amount);
    }

    /// @dev §4.8's deciding rule, as corrected at `6489bfd`:
    ///
    ///        A bounty is refunded where the transition it pays for cannot occur,
    ///        and paid where that transition was performed.
    ///
    ///      `DRAW_BOUNTY` is zeroed by `_payBounty` at the moment it is paid, so
    ///      refunding whatever REMAINS is that rule with no per-reason branch:
    ///      `NO_TURNOUT` and `NO_REVEALS` never reach `DRAW`, so the whole bounty
    ///      returns to the submitter; `NO_RANDOMNESS` already paid it to whoever
    ///      poked the expiry, so nothing remains to return. Retaining it charged
    ///      the submitter for a transition that cannot happen, on rows §4.8 calls
    ///      unsteerable and refunds in full.
    ///
    ///      `CLAIM_BOUNTY` is retained, and that is deliberate rather than an
    ///      oversight: the same argument applies to it, because every terminal
    ///      transition is permissionless and somebody paid gas to poke it. §10
    ///      carries that as an open question — it is a fee-schedule change rather
    ///      than a contradiction, and the two must not ride together.
    function _settleBounties(uint256 caseId) internal {
        Case storage c = cases[caseId];
        refundOwed[caseId] += c.drawBounty;
        c.drawBounty = 0;
        maintenanceAccrued += c.claimBounty;
        c.claimBounty = 0;
    }

    // =========================================================================
    // §5.3 — payment
    // =========================================================================

    /// @dev `reveals1` is DERIVED, never stored, and §5.3 says why at length. The
    ///      only stored binding available is `revealsThisRound`, and on the
    ///      unchallenged path that still holds round 0's count — so binding it that
    ///      way makes `activated` the ENTIRE reserve on cases nobody challenged and
    ///      the submitter's refund zero on most cases. Written as
    ///      `(pooledApprove + pooledReject) - reveals0` it is zero on that path by
    ///      ARITHMETIC, not by a reset someone has to remember.
    function _activated(uint256 caseId) internal view returns (uint256) {
        Case storage c = cases[caseId];
        uint256 reveals0 = c.reveals0;
        if (reveals0 == 0) return 0;
        uint256 reveals1 = (uint256(c.pooledApprove) + c.pooledReject) - reveals0;
        uint256 proportional = (uint256(c.pot) * reveals1) / reveals0;
        uint256 reserve = c.challengeReserve;
        return proportional < reserve ? proportional : reserve;
    }

    /// @notice `share` is fixed at the terminal (§8.1) and recomputed here from
    ///         fields that are immutable after it — no field is added for it.
    function shareOf(uint256 caseId) public view returns (uint256) {
        Case storage c = cases[caseId];
        if (c.terminal != uint8(Terminal.APPROVED) && c.terminal != uint8(Terminal.REJECTED)) return 0;
        uint256 W = c.verdict == uint8(Outcome.APPROVE) ? c.pooledApprove : c.pooledReject;
        if (W == 0) return 0;
        return (uint256(c.pot) + _activated(caseId)) / W;
    }

    // =========================================================================
    // §5.5 — settlement, pulled per moderator
    // =========================================================================

    /// @notice Settle ONE moderator's vote claim. Permissionless, self-funded,
    ///         order-independent, and it may never complete.
    /// @dev There is no case-level `SETTLED`: a case whose participants have all
    ///      claimed is indistinguishable from one where a single moderator has not
    ///      bothered, and a state the machine can be permanently unable to enter is
    ///      not a state.
    ///
    ///      Settlement NEVER touches the index (§8.1, I15).
    ///
    ///      Obligations fire by their own condition (I30), not by group:
    ///        non-reveal debit  <- a reveal phase OPENED   (every reason but NO_TURNOUT)
    ///        incoherence debit <- a settled side exists   (NO_RANDOMNESS, A/R)
    ///        payment, reputation <- a verdict was drawn   (A/R only)
    function claim(uint256 caseId, address m) external nonReentrant {
        Case storage c = cases[caseId];
        uint8 t = c.terminal;
        if (t == uint8(Terminal.NONE)) revert NotTerminal();
        if (voteSettled[caseId][m]) revert AlreadySettled();
        if (commitments[caseId][m] == bytes32(0)) revert NotCommitted();

        voteSettled[caseId][m] = true;
        openVoteClaims[caseId] -= 1;

        Params storage p = _p(caseId);
        uint8 v = revealedVote[caseId][m];
        bool drewVerdict = (t == uint8(Terminal.APPROVED) || t == uint8(Terminal.REJECTED));
        Reason r = Reason(c.unresolvedReason);

        if (v == 0) {
            // Non-revealer. The requirement is A REVEAL PHASE THAT OPENED, not a
            // terminal (I25) — in NO_TURNOUT none did, and every committer there is
            // vacuously a non-revealer, so quantifying over terminals would debit
            // everyone for a failure the same table calls unsteerable.
            if (drewVerdict || r != Reason.NO_TURNOUT) {
                stakeReg.debit(m, caseId, KIND_VOTE, p.revealBond);
            }
        } else if (drewVerdict) {
            if (v == c.verdict) {
                uint256 s = shareOf(caseId);
                if (s != 0) {
                    address(token).safeApprove(address(stakeReg), s);
                    stakeReg.reward(m, s);
                }
                stakeReg.recordParticipation(m, caseId, 1, p.trackDecay);
            } else {
                stakeReg.debit(m, caseId, KIND_VOTE, p.penaltyDebit);
            }
        } else if (r == Reason.NO_RANDOMNESS) {
            // A settled side exists: the POOLED plurality, where no verdict was
            // drawn. Nothing is paid and no reputation is credited — those require
            // a verdict.
            if (v != c.plurality) {
                stakeReg.debit(m, caseId, KIND_VOTE, p.penaltyDebit);
            }
        }

        // Every terminal discharges every liability it created (I20, I32). A claim
        // left open is a moderator's liability standing forever.
        stakeReg.discharge(m, caseId, KIND_VOTE);
        emit VoteClaimSettled(caseId, m);
    }

    /// @notice Settle the challenger's bond. `CHALLENGE_BOND` is debited
    ///         UNCONDITIONALLY (§4.6): there is no branch, so there is no test, so
    ///         there is nothing for a challenger to steer.
    /// @dev Its condition is "a challenge was registered", which no pre-`TALLY`
    ///      terminal can meet — the challenge window opens at `TALLY`.
    function claimChallenge(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        if (c.terminal == uint8(Terminal.NONE)) revert NotTerminal();
        address ch = c.challenger;
        if (ch == address(0)) revert NotCommitted();
        if (challengeSettled[caseId]) revert AlreadySettled();

        challengeSettled[caseId] = true;
        Params storage p = _p(caseId);
        stakeReg.debit(ch, caseId, KIND_CHALLENGE, p.challengeBond);
        stakeReg.discharge(ch, caseId, KIND_CHALLENGE);
        emit ChallengeClaimSettled(caseId, ch);
    }

    /// @notice Pull the submitter's refund. Push would let a submitter contract that
    ///         reverts brick a terminal transition for everyone.
    function withdrawRefund(uint256 caseId) external nonReentrant {
        uint256 amount = refundOwed[caseId];
        if (amount == 0) revert NothingToRefund();
        refundOwed[caseId] = 0;
        address to = cases[caseId].submitter;
        address(token).safeTransfer(to, amount);
        emit Refunded(caseId, to, amount);
    }

    // =========================================================================
    // §8.5 — re-review
    // =========================================================================

    /// @notice Reopen the `LIST` claim IN PLACE. Not a new claim and not an action
    ///         type — a re-review under a different key would make the permanent
    ///         reservation worth one byte.
    /// @dev Same `claimKey`, same `u` (re-derived from stored entropy), pooled tally
    ///      carries, prior voters are done. A re-review that attracts no votes
    ///      returns the IDENTICAL verdict; adding votes moves it only toward the
    ///      side added. Repetition is self-defeating.
    ///
    ///      §8.5 says prior voters "are already settled" but settlement is pull-based
    ///      and may never complete, so this REQUIRES what §8.5 assumes. `claim` is
    ///      permissionless, so anyone wanting a re-review can settle the stragglers.
    function reopen(uint256 caseId, uint256 fee) external nonReentrant {
        Case storage c = cases[caseId];
        uint8 t = c.terminal;
        bool fromRejected = (t == uint8(Terminal.REJECTED));
        bool fromNoRandomness =
            (t == uint8(Terminal.UNRESOLVED) && c.unresolvedReason == uint8(Reason.NO_RANDOMNESS));
        if (!fromRejected && !fromNoRandomness) revert NotReopenable();
        if (openVoteClaims[caseId] != 0) revert ClaimsOutstanding();

        Params storage p = _p(caseId);
        if (fee < uint256(p.feeBase) + uint256(p.feePerTopic) * c.topicCount) revert FeeTooLow();
        address(token).safeTransferFrom(msg.sender, address(this), fee);

        uint256 maint = (fee * p.maintenanceBps) / BPS;
        uint256 drawB = (fee * p.drawBountyBps) / BPS;
        uint256 claimB = (fee * p.claimBountyBps) / BPS;
        uint256 reserve = (fee * p.reserveBps) / BPS;
        maintenanceAccrued += maint;

        c.pot = uint128(uint256(c.pot) + fee - maint - drawB - claimB - reserve);
        c.challengeReserve = uint128(uint256(c.challengeReserve) + reserve);

        // A second opening carries its own single challenge round (I17), so the
        // challenger slot clears. `pooledApprove` / `pooledReject` do NOT.
        c.phase = uint8(Phase.COMMIT);
        c.round = 0;
        c.terminal = uint8(Terminal.NONE);
        c.unresolvedReason = uint8(Reason.NONE);
        c.verdict = uint8(Outcome.NONE);
        c.commitsThisRound = 0;
        c.revealsThisRound = 0;
        c.challenger = address(0);
        challengeSettled[caseId] = false;
        c.eligSeedBlock = uint40(block.number + p.seedLag);
        c.phaseDeadline = uint40(block.number + c.commitBlocks);

        // §8.3 — a re-review is an open question against the entries this claim
        // already wrote, and SUPER_SAFE must stop reading true while it stands.
        questionOpen[caseId] = true;
        uint256 nt = c.topicCount;
        bytes32 qk = _questionKey(caseId);
        for (uint256 i; i < nt; ++i) {
            index.openQuestion(qk, caseTopics[caseId][i]);
        }

        emit Reopened(caseId, msg.sender, fee);
        emit PhaseChanged(caseId, uint8(Phase.NONE), uint8(Phase.COMMIT), 0);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function caseInfo(uint256 caseId) external view returns (Case memory) {
        return cases[caseId];
    }

    function topicsOf(uint256 caseId) external view returns (bytes32[MAX_TOPICS] memory) {
        return caseTopics[caseId];
    }

    function commitmentOf(uint256 caseId, address m) external view returns (bytes32) {
        return commitments[caseId][m];
    }

    function revealOf(uint256 caseId, address m) external view returns (uint8) {
        return revealedVote[caseId][m];
    }

    function isVoteSettled(uint256 caseId, address m) external view returns (bool) {
        return voteSettled[caseId][m];
    }

    /// @notice Forward everything accrued into the registry's maintenance reserve
    ///         (§5.6.1). Permissionless.
    /// @dev Lazy, not per-terminal: forwarding at each terminal would put a token
    ///      transfer on the hot path of every case that ends, for no benefit —
    ///      nothing reads the reserve between sweeps.
    ///
    ///      Permissionless is safe for the same reason the deposit is: the call
    ///      moves value in exactly one direction, toward the pool it belongs in, and
    ///      a griefer who calls it repeatedly pays gas to do the protocol's
    ///      housekeeping.
    ///
    ///      A sweep with nothing accrued is a NO-OP, not a revert. Reverting would
    ///      make a permissionless housekeeping call fail on the common case and put
    ///      a state read on every caller before they may make it.
    function sweepMaintenance() external nonReentrant returns (uint256 amount) {
        amount = maintenanceAccrued;
        if (amount == 0) return 0;
        maintenanceAccrued = 0;
        address(token).safeApprove(address(stakeReg), amount);
        stakeReg.depositMaintenance(amount);
        emit MaintenanceSwept(msg.sender, amount);
    }

    function setGovernor(address next) external onlyGovernor {
        if (next == address(0)) revert ZeroAddress();
        governor = next;
    }
}
