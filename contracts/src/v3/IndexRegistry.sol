// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IndexRegistry (v3) — what a reader consults
/// @notice §8 end to end: the finality-independent write (§8.1), interim status as
///         a value (§8.2), content-derived identifiers (§8.2b), and the split
///         `SUPER_SAFE` query (§8.3).
///
/// @dev Every identifier this index exposes is a function of CONTENT. None is a
///      function of insertion order, of a counter, or of any state a particular
///      logic contract owns — so a replacement contract re-derives the same
///      identifier from the same content rather than issuing a new one. v1 paid a
///      CRITICAL (P0-1a) for a logic-local identifier that collided across a
///      migration, and §8.4 applied the lesson to claims and not to entries.
contract IndexRegistry {
    // =========================================================================
    // §8.2 — status is a VALUE, not an absence
    // =========================================================================

    /// @dev `NONE = 0` is not a status among the others; it is what makes the rest
    ///      mean anything. With the enum beginning at `PLURALITY_APPROVE`, an
    ///      unwritten slot and a case whose plurality leans Approve would read
    ///      IDENTICALLY — in the section whose entire purpose is that those two are
    ///      distinguishable.
    ///
    ///      `REMOVED` is the seventh slot and the §8 re-read found it missing.
    ///      `RETAINED` is deliberately NOT here: it is a removal case's terminal,
    ///      not an entry status. A failed removal disturbs no LIST answer, so there
    ///      is nothing to write.
    enum Status {
        NONE,
        PLURALITY_APPROVE,
        PLURALITY_REJECT,
        APPROVED,
        REJECTED,
        UNRESOLVED,
        REMOVED
    }

    /// @notice What the claim behind an entry ASKED. §8.5's `actionType`, carried
    ///         onto the entry because the listing predicate needs it.
    /// @dev These must agree with `Moderation.ActionType`. A claim key is
    ///      `H(actionType, ...)`, so the index cannot recover the action type from
    ///      the key it is handed — the writer states it and the index records it.
    ///      `test_s8_2_actionTypeConstantsAgreeWithModeration` pins the agreement.
    uint8 public constant ACTION_LIST = 0;
    uint8 public constant ACTION_REMOVE = 1;

    /// @notice One entry per `(content, topic)`. Its status is the latest RESOLVED
    ///         question about it.
    /// @dev `strict` and `openQuestions` are §8.3's split: the static half is fixed
    ///      at the terminal that wrote it and can never go stale, and the live half
    ///      is the only thing that moves.
    ///
    ///      `actionType` says what the entry's claim asked, and without it `status`
    ///      is ambiguous: `APPROVED` on a `LIST` claim means "show this", and
    ///      `APPROVED` on a `REMOVE` claim means "stop showing it". Those are
    ///      opposite instructions to a safe-search reader wearing one enum value.
    struct Entry {
        uint8 status;
        uint8 plurality;
        bool strict;
        uint32 openQuestions;
        uint8 actionType;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    address public governance;
    address public pendingGovernance;
    uint256 public immutable timelockDelay;

    /// @notice Logic contracts permitted to write. Granted behind the same
    ///         propose/cancel/execute timelock `StakeRegistry` uses — not
    ///         `msg.sender == owner`, and not a second idiom.
    mapping(address => bool) public writers;

    mapping(bytes32 => Entry) internal entries;

    /// @notice `topicKey -> entryKey[]` — the enumerable listing of LISTED content.
    /// @dev Membership is exactly `status == APPROVED && actionType == ACTION_LIST`.
    ///      A `REMOVED` entry leaves this list while the entry itself persists and
    ///      stays addressable at the same `entryKey`: the listing and the record are
    ///      two different objects, and an earlier reading of §8.2b conflated them.
    ///
    ///      **The second conjunct is not decoration.** The predicate read
    ///      `status == APPROVED` alone while every claim was a `LIST` claim, which
    ///      made it accidentally right. A `REMOVE` claim that carries — verdict
    ///      Approve, meaning *remove it* — writes `APPROVED` to its OWN entry, and
    ///      under the one-conjunct predicate that entry joins the topic's listing.
    ///      The successful removal would publish itself as approved content, in the
    ///      list a safe-search reader consults. Membership is a property of the
    ///      LISTING, not of whichever claim happened to be writing when it was
    ///      first stated.
    mapping(bytes32 => bytes32[]) internal listing;

    /// @notice `topicKey -> entryKey -> index + 1`.
    /// @dev **Plus one, and that is the whole of it.** A position map returning 0
    ///      for "absent" cannot distinguish absent from FIRST IN THE LIST — the same
    ///      defect as a legal `topicKey == 0`, both I29, and the second is
    ///      `M2.6-F1` verbatim, which this codebase has already fixed once.
    mapping(bytes32 => mapping(bytes32 => uint256)) internal posPlusOne;

    struct PendingWriter {
        address logic;
        bool allowed;
        uint40 eta;
        bool exists;
    }

    PendingWriter internal pendingWriter;

    // =========================================================================
    // Events
    // =========================================================================

    event EntryWritten(
        bytes32 indexed entryKey, bytes32 indexed topicKey, bytes32 indexed claimKey, uint8 status, bool strict
    );
    event ListingAdded(bytes32 indexed topicKey, bytes32 indexed entryKey);
    event ListingRemoved(bytes32 indexed topicKey, bytes32 indexed entryKey);
    event QuestionOpened(bytes32 indexed entryKey, uint32 openQuestions);
    event QuestionClosed(bytes32 indexed entryKey, uint32 openQuestions);
    event WriterProposed(address indexed logic, bool allowed, uint256 eta);
    event WriterProposalCancelled(address indexed logic);
    event WriterSet(address indexed logic, bool allowed);
    event GovernanceProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotGovernance();
    error NotWriter();
    error ZeroAddress();
    error ZeroTopicKey();
    error BadStatus();
    error BadActionType();
    error NotAListEntry();
    error NoSuchEntry();
    error NoQuestionOpen();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error BadPage();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyWriter() {
        if (!writers[msg.sender]) revert NotWriter();
        _;
    }

    constructor(uint256 _timelockDelay) {
        timelockDelay = _timelockDelay;
        governance = msg.sender;
    }

    // =========================================================================
    // §8.2b — identifiers
    // =========================================================================

    /// @notice An entry is addressed by `H(claimKey, topicKey)`.
    /// @dev A claim key names a SET of entries — §8.1 writes up to `MAX_TOPICS` per
    ///      claim — so it cannot name a member of that set, and deletion needs to
    ///      name a member.
    function entryKeyOf(bytes32 claimKey, bytes32 topicKey) public pure returns (bytes32) {
        return keccak256(abi.encode(claimKey, topicKey));
    }

    // =========================================================================
    // §8.1 — the writes
    // =========================================================================

    /// @notice The four per-claim writes: interim plurality at `TALLY`, and the
    ///         terminal at each of the four transitions that establish one.
    /// @dev Membership of the topic's listing is exactly `status == APPROVED`,
    ///      re-derived on every write, so the listing cannot drift from the status
    ///      it is supposed to reflect.
    function writeEntry(
        bytes32 claimKey,
        bytes32 topicKey,
        uint8 status,
        uint8 plurality,
        bool strict,
        uint8 actionType
    ) external onlyWriter returns (bytes32 entryKey) {
        // §8.2b, I29 — a claim carries up to MAX_TOPICS topics in a fixed-width
        // slot and unused slots read 0, so a legal zero topic would make "no topic
        // here" and "the topic whose key is 0" the same read.
        if (topicKey == bytes32(0)) revert ZeroTopicKey();
        if (status == uint8(Status.NONE) || status > uint8(Status.REMOVED)) revert BadStatus();
        if (actionType > ACTION_REMOVE) revert BadActionType();

        entryKey = entryKeyOf(claimKey, topicKey);
        Entry storage e = entries[entryKey];
        e.status = status;
        e.plurality = plurality;
        e.strict = strict;
        e.actionType = actionType;

        _syncListing(topicKey, entryKey, status, actionType);
        emit EntryWritten(entryKey, topicKey, claimKey, status, strict);
    }

    /// @notice §8.1's FIFTH write — the only one that reaches outside its own claim
    ///         key. A successful removal case sets the original `LIST` entry to
    ///         `REMOVED` and drops it from the topic's listing.
    /// @dev The caller supplies the LIST claim key. Both entry keys are derived from
    ///      content (§8.2b), so the removal case computes this from its own fields
    ///      and NO STORED POINTER is needed.
    ///
    ///      `REMOVED` is a status and not a deletion. For a safe-search client
    ///      `REMOVED` and `REJECTED` are the same instruction, and the distinction is
    ///      for the reader who wants to know why — deleting the entry destroys
    ///      exactly that reader's answer, and would make a content-derived
    ///      identifier resolve to nothing.
    function removeListing(bytes32 listClaimKey, bytes32 topicKey) external onlyWriter returns (bytes32 entryKey) {
        if (topicKey == bytes32(0)) revert ZeroTopicKey();
        entryKey = entryKeyOf(listClaimKey, topicKey);
        Entry storage e = entries[entryKey];
        if (e.status == uint8(Status.NONE)) revert NoSuchEntry();
        // The fifth write reaches outside its own claim key, so it states what it
        // is allowed to reach: a LIST answer. Pointing it at a REMOVE entry would
        // let a removal case mark another removal case's record REMOVED.
        if (e.actionType != ACTION_LIST) revert NotAListEntry();

        e.status = uint8(Status.REMOVED);

        // §8.3 — `strict` is the static half of SUPER_SAFE and survives everything
        // else, because every conjunct is a fact about a tally that already
        // happened. A removal is the one event that falsifies it, and it must be
        // cleared HERE rather than left to the counter: the removal case closes its
        // own question at the same terminal, so `openQuestions` returns to 0 and a
        // retained `strict` would make a REMOVED entry read SUPER_SAFE — the exact
        // claim the index exists to never make wrongly.
        e.strict = false;

        _syncListing(topicKey, entryKey, uint8(Status.REMOVED), e.actionType);
        emit EntryWritten(entryKey, topicKey, listClaimKey, uint8(Status.REMOVED), false);
    }

    /// @dev Swap-and-pop against the position map, `O(1)`. The moved element's
    ///      position is rewritten, which is the whole reason the map exists.
    function _syncListing(bytes32 topicKey, bytes32 entryKey, uint8 status, uint8 actionType) internal {
        bool shouldBeListed = (status == uint8(Status.APPROVED) && actionType == ACTION_LIST);
        uint256 p = posPlusOne[topicKey][entryKey];

        if (shouldBeListed) {
            if (p != 0) return; // already listed
            listing[topicKey].push(entryKey);
            posPlusOne[topicKey][entryKey] = listing[topicKey].length; // index + 1
            emit ListingAdded(topicKey, entryKey);
            return;
        }

        if (p == 0) return; // already absent
        bytes32[] storage arr = listing[topicKey];
        uint256 idx = p - 1;
        uint256 last = arr.length - 1;
        if (idx != last) {
            bytes32 moved = arr[last];
            arr[idx] = moved;
            posPlusOne[topicKey][moved] = idx + 1;
        }
        arr.pop();
        delete posPlusOne[topicKey][entryKey];
        emit ListingRemoved(topicKey, entryKey);
    }

    // =========================================================================
    // §8.3 — the live half of SUPER_SAFE
    // =========================================================================

    /// @notice A re-review or removal case has OPENED against this content.
    /// @dev A COUNTER, never a boolean: two concurrent questions closing one at a
    ///      time would clear a boolean while a question was still open, and "no
    ///      question is open" would read true in a state it must exclude (I29).
    function openQuestion(bytes32 claimKey, bytes32 topicKey) external onlyWriter {
        bytes32 entryKey = entryKeyOf(claimKey, topicKey);
        Entry storage e = entries[entryKey];
        if (e.status == uint8(Status.NONE)) revert NoSuchEntry();
        e.openQuestions += 1;
        emit QuestionOpened(entryKey, e.openQuestions);
    }

    function closeQuestion(bytes32 claimKey, bytes32 topicKey) external onlyWriter {
        bytes32 entryKey = entryKeyOf(claimKey, topicKey);
        Entry storage e = entries[entryKey];
        if (e.openQuestions == 0) revert NoQuestionOpen();
        e.openQuestions -= 1;
        emit QuestionClosed(entryKey, e.openQuestions);
    }

    // =========================================================================
    // Reads
    // =========================================================================

    function entryOf(bytes32 claimKey, bytes32 topicKey) external view returns (Entry memory) {
        return entries[entryKeyOf(claimKey, topicKey)];
    }

    function entryAt(bytes32 entryKey) external view returns (Entry memory) {
        return entries[entryKey];
    }

    function statusOf(bytes32 claimKey, bytes32 topicKey) external view returns (uint8) {
        return entries[entryKeyOf(claimKey, topicKey)].status;
    }

    /// @notice §8.3. `strict AND openQuestions == 0` — `O(1)` and local to the index,
    ///         so a reader consults one contract to answer the one question the
    ///         index exists to answer.
    function isSuperSafe(bytes32 claimKey, bytes32 topicKey) external view returns (bool) {
        Entry storage e = entries[entryKeyOf(claimKey, topicKey)];
        return e.strict && e.openQuestions == 0;
    }

    function isListed(bytes32 claimKey, bytes32 topicKey) external view returns (bool) {
        return posPlusOne[topicKey][entryKeyOf(claimKey, topicKey)] != 0;
    }

    function listedCount(bytes32 topicKey) external view returns (uint256) {
        return listing[topicKey].length;
    }

    /// @notice Paged enumeration. **No function here iterates an unbounded list.**
    /// @dev A topic accumulates entries without limit, so a function that walks a
    ///      whole topic is a contract that stops working at a size nobody chose.
    ///      The caller pages; the cost is `O(limit)` and independent of how large
    ///      the topic has grown.
    function listedPage(bytes32 topicKey, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page)
    {
        if (limit == 0) revert BadPage();
        bytes32[] storage arr = listing[topicKey];
        uint256 n = arr.length;
        if (offset >= n) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        page = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = arr[i];
        }
    }

    // =========================================================================
    // Writer capability — the timelock idiom this project already has
    // =========================================================================

    function proposeWriter(address logic, bool allowed) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + timelockDelay;
        pendingWriter = PendingWriter({logic: logic, allowed: allowed, eta: uint40(eta), exists: true});
        emit WriterProposed(logic, allowed, eta);
    }

    function cancelWriter() external onlyGovernance {
        PendingWriter memory w = pendingWriter;
        if (!w.exists) revert NoPendingProposal();
        delete pendingWriter;
        emit WriterProposalCancelled(w.logic);
    }

    function executeWriter() external onlyGovernance {
        PendingWriter memory w = pendingWriter;
        if (!w.exists) revert NoPendingProposal();
        if (block.timestamp < w.eta) revert TimelockNotElapsed();
        writers[w.logic] = w.allowed;
        delete pendingWriter;
        emit WriterSet(w.logic, w.allowed);
    }

    function pendingWriterProposal() external view returns (address logic, bool allowed, uint256 eta, bool exists) {
        PendingWriter memory w = pendingWriter;
        return (w.logic, w.allowed, w.eta, w.exists);
    }

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
}
