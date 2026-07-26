// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IndexRegistry
/// @notice The topic → approved-entries index, held independently of the
///         moderation game's business logic (M2.5-P0-b, third contract).
///
///         This is the protocol's actual product: the safe-search index. If it
///         lived inside the game contract, every logic redeployment would throw
///         away every approval ever made and the index would restart empty —
///         which would make improving the game prohibitively expensive forever.
///         So approvals live here permanently, and only the *game* is replaced.
///
///         The registry knows nothing about voting, appeals or settlement. It
///         accepts writes and deletions from the currently authorized logic
///         contract, and serves reads to anyone.
///
/// ## Trust model
///
/// Same shape as StakeRegistry: governance may name the authorized logic
/// contract, behind a timelock, and can do nothing else. Reads are permissionless
/// and can never be gated — a search front end keeps working across migrations.
/// Governance cannot write or delete entries itself; only the logic contract can,
/// and only as the outcome of an adjudicated case.
contract IndexRegistry {
    struct Entry {
        bytes32 contentHash;
        bytes32 metaHash;
        uint40 approvalTime; // drives the supersafe age filter
        bool uncontested; // no Reject vote was ever revealed
        bool fullQuorum; // decided at full quorum, no under-quorum fallback (H-09)
        // M2.6-P0-1: identity is minted HERE, by the permanent registry. A logic
        // contract's own caseId restarts at 0 on every redeployment, so keying the
        // index by it made a replacement logic's first case collide with the
        // original's — overwriting the reverse-map slot and orphaning the older
        // entry (readable, un-deletable, and reported absent by isIndexed).
        uint256 globalId; // registry-minted, unique for all time
        address originLogic; // which logic adjudicated this entry
        uint256 localCaseId; // that logic's own case id, for provenance
        uint256 rulesVersion; // provenance: ruleset the decision was made under
        uint256 guidelinesVersion; // provenance: guidelines in force at submission
        // M2.6-P0-1c: the reservation this entry is protected by. Deleting the
        // entry frees it — that is the ONLY way a reservation can be released by
        // anyone other than the case that took it, and it is what lets a
        // replacement logic make a legacy entry's content submittable again after
        // adjudicating its removal.
        bytes32 dedupKey;
    }

    /// Monotonic, never reused. Entry 0 is never minted so `globalId == 0` is a
    /// safe "absent" sentinel.
    uint256 public nextEntryId = 1;

    mapping(bytes32 => Entry[]) internal indexByTopic;
    mapping(bytes32 => bool) internal topicSeen;
    /// topic -> globalId -> position+1, so deletion is O(1) (H-03) AND cannot be
    /// collided across logic versions (M2.6-P0-1).
    mapping(bytes32 => mapping(uint256 => uint256)) internal entryPosPlusOne;
    /// globalId -> the topic it was written under, so a holder of the id alone can
    /// locate and remove it (needed for cross-version removal).
    mapping(uint256 => bytes32) public topicOfEntry;

    /// M2.6-P0-1b: the live-content reservation lives HERE, not in the logic
    /// contract. Held in `Moderation`, the dedup map restarted empty on every
    /// redeployment, so a replacement logic re-indexed content that was already
    /// live in this permanent index — the same content, twice, under one topic.
    /// A reservation must outlive the logic that took it, exactly as entries do.
    ///
    /// H-02 ownership keying is preserved and widened to (logic, caseId): only
    /// the case that took a reservation may release it, so neither a stale case
    /// nor a replacement logic can free a key a live case still holds.
    struct Reservation {
        address logic; // the logic contract holding it
        uint256 caseId; // that logic's own case id
        bool exists; // explicit: case 0 is a real owner
    }

    mapping(bytes32 => Reservation) internal contentReservations;

    address public governance;
    uint256 public immutable timelockDelay;

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
    address public pendingGovernance;

    event TopicCreated(bytes32 indexed topicKey);
    event EntryWritten(
        uint256 indexed globalId,
        bytes32 indexed topicKey,
        address indexed originLogic,
        uint256 localCaseId,
        bool uncontested,
        bool fullQuorum
    );
    event EntryRemoved(uint256 indexed globalId, bytes32 indexed topicKey);
    event ContentReserved(bytes32 indexed dedupKey, address indexed logic, uint256 caseId);
    event ContentReleased(bytes32 indexed dedupKey, address indexed logic, uint256 caseId);
    event LogicProposed(address indexed logic, uint256 eta);
    event LogicAuthorized(address indexed logic);
    event LogicRetiring(address indexed logic);
    event LogicRevoked(address indexed logic);
    event GovernanceTransferProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    error NotGovernance();
    error NotLogic();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error ZeroAddress();
    error BadRange();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLogic() {
        if (logicState[msg.sender] == LogicState.NONE) revert NotLogic();
        _;
    }

    constructor(uint256 _timelockDelay) {
        timelockDelay = _timelockDelay;
        governance = msg.sender;
    }

    // --- logic-facing --------------------------------------------------------

    /// @notice Write an approved entry and mint its permanent global id.
    /// @return globalId The registry-minted identity. The caller MUST record this;
    ///         it is the only safe handle for later removal.
    function writeEntry(
        bytes32 topicKey,
        uint256 localCaseId,
        bytes32 contentHash,
        bytes32 metaHash,
        bool uncontested,
        bool fullQuorum,
        uint256 rulesVersion,
        uint256 guidelinesVersion,
        bytes32 dedupKey
    ) external onlyLogic returns (uint256 globalId) {
        if (!topicSeen[topicKey]) {
            topicSeen[topicKey] = true;
            emit TopicCreated(topicKey);
        }
        globalId = nextEntryId++;
        indexByTopic[topicKey].push(
            Entry({
                contentHash: contentHash,
                metaHash: metaHash,
                approvalTime: uint40(block.timestamp),
                uncontested: uncontested,
                fullQuorum: fullQuorum,
                globalId: globalId,
                originLogic: msg.sender,
                localCaseId: localCaseId,
                rulesVersion: rulesVersion,
                guidelinesVersion: guidelinesVersion,
                dedupKey: dedupKey
            })
        );
        entryPosPlusOne[topicKey][globalId] = indexByTopic[topicKey].length;
        topicOfEntry[globalId] = topicKey;
        emit EntryWritten(globalId, topicKey, msg.sender, localCaseId, uncontested, fullQuorum);
    }

    /// O(1) swap-and-pop (H-03). No-op if absent, so a removal whose target was
    /// already deleted settles cleanly.
    /// @notice Delete an entry by its permanent global id. Any authorized logic may
    ///         remove any entry — including one written by a superseded logic — which
    ///         is what makes legacy entries adjudicable after a migration.
    /// @dev Deleting an entry ALSO frees the content reservation it carries
    ///      (M2.6-P0-1c). That is deliberate and is the only cross-logic release
    ///      path: without it, a legacy entry removed by a replacement logic would
    ///      leave its content permanently unsubmittable, because the reservation's
    ///      owning logic no longer exists to release it. Binding the release to an
    ///      actual deletion — rather than exposing a "release anyone's key" call —
    ///      is what keeps H-02 intact: an obsolete removal deletes nothing (the
    ///      position map is already clear) and therefore releases nothing.
    function deleteEntry(bytes32 topicKey, uint256 globalId) external onlyLogic {
        uint256 p = entryPosPlusOne[topicKey][globalId];
        if (p == 0) return;
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 idx = p - 1;
        bytes32 dedupKey = arr[idx].dedupKey;
        uint256 last = arr.length - 1;
        if (idx != last) {
            Entry storage moved = arr[last];
            arr[idx] = moved;
            entryPosPlusOne[topicKey][moved.globalId] = idx + 1;
        }
        arr.pop();
        delete entryPosPlusOne[topicKey][globalId];
        delete topicOfEntry[globalId];
        if (contentReservations[dedupKey].exists) {
            emit ContentReleased(dedupKey, contentReservations[dedupKey].logic, contentReservations[dedupKey].caseId);
            delete contentReservations[dedupKey];
        }
        emit EntryRemoved(globalId, topicKey);
    }

    // --- live-content reservation (M2.6-P0-1b) -------------------------------

    /// @notice Reserve a content key against duplicate submission, permanently and
    ///         across logic versions. This is the invariant: content live in the
    ///         permanent index cannot be re-submitted into it, and a migration
    ///         does not reset that.
    /// @param dedupKey The logic's content key, e.g. H(contentHash, metaHash, topicKey).
    /// @param localCaseId The reserving logic's own case id — the release handle.
    /// @return True if reserved; false if the key is ALREADY held, by any logic
    ///         including a superseded one. Callers must check — the `try` prefix
    ///         is the signal. `Moderation` turns false into `DuplicateSubmission`;
    ///         the boolean exists so it can, without paying twice at the contract
    ///         boundary on the EIP-170-bound side.
    function tryReserveContent(bytes32 dedupKey, uint256 localCaseId) external onlyLogic returns (bool) {
        Reservation storage r = contentReservations[dedupKey];
        if (r.exists) return false;
        r.logic = msg.sender;
        r.caseId = localCaseId;
        r.exists = true;
        emit ContentReserved(dedupKey, msg.sender, localCaseId);
        return true;
    }

    /// @notice Release a reservation. No-op unless the caller is the logic that
    ///         took it AND names the case that owns it (H-02): an obsolete case
    ///         must never wipe a key a newer submission now holds, and after a
    ///         migration a replacement logic must not be able to free another
    ///         version's live content by guessing a case id.
    function releaseContent(bytes32 dedupKey, uint256 localCaseId) external onlyLogic {
        Reservation storage r = contentReservations[dedupKey];
        if (!r.exists || r.logic != msg.sender || r.caseId != localCaseId) return;
        delete contentReservations[dedupKey];
        emit ContentReleased(dedupKey, msg.sender, localCaseId);
    }

    // --- reads (permissionless, never gated) ---------------------------------

    /// @notice The full reservation record. `exists` is explicit because case 0 is
    ///         a legitimate owner and cannot be distinguished by caseId alone.
    function contentReservation(bytes32 dedupKey)
        external
        view
        returns (bool exists, address logic, uint256 caseId)
    {
        Reservation storage r = contentReservations[dedupKey];
        return (r.exists, r.logic, r.caseId);
    }

    function isContentReserved(bytes32 dedupKey) external view returns (bool) {
        return contentReservations[dedupKey].exists;
    }

    /// @notice Everything a logic contract needs to open a removal case against an
    ///         entry it did not write (M2.6-P0-1c). Returns `topicKey == 0` when
    ///         the id is not live, which is the caller's existence check —
    ///         `globalId` starts at 1, so no live entry can sit under topic 0.
    /// @dev The payload comes from the registry, not the caller, so a removal
    ///      displays exactly what settlement will act on (H-01) even when the case
    ///      record that produced the entry lives in a contract this one cannot read.
    function legacyEntryInfo(uint256 globalId)
        external
        view
        returns (bytes32 topicKey, bytes32 contentHash, bytes32 metaHash, address originLogic)
    {
        topicKey = topicOfEntry[globalId];
        if (topicKey == bytes32(0)) return (bytes32(0), bytes32(0), bytes32(0), address(0));
        Entry storage e = indexByTopic[topicKey][entryPosPlusOne[topicKey][globalId] - 1];
        return (topicKey, e.contentHash, e.metaHash, e.originLogic);
    }

    /// @notice The owning case id alone, for the logic contract's compatibility
    ///         view. Single-word return: `Moderation` is the EIP-170-bound
    ///         contract, so the decode cost is kept on this side of the boundary.
    function reservationCaseId(bytes32 dedupKey) external view returns (uint256) {
        return contentReservations[dedupKey].caseId;
    }

    function entryCount(bytes32 topicKey) external view returns (uint256) {
        return indexByTopic[topicKey].length;
    }

    function entryAt(bytes32 topicKey, uint256 i) external view returns (Entry memory) {
        return indexByTopic[topicKey][i];
    }

    function isIndexed(bytes32 topicKey, uint256 globalId) external view returns (bool) {
        return entryPosPlusOne[topicKey][globalId] != 0;
    }

    /// @notice Provenance for an entry: who decided it, under which local case, and
    ///         under which ruleset/guidelines. Permanent entries must remain
    ///         interpretable after the logic that created them is gone.
    function entryProvenance(bytes32 topicKey, uint256 globalId)
        external
        view
        returns (address originLogic, uint256 localCaseId, uint256 rulesVersion, uint256 guidelinesVersion)
    {
        uint256 p = entryPosPlusOne[topicKey][globalId];
        if (p == 0) return (address(0), 0, 0, 0);
        Entry storage e = indexByTopic[topicKey][p - 1];
        return (e.originLogic, e.localCaseId, e.rulesVersion, e.guidelinesVersion);
    }

    /// @notice Paginated slice of a topic (M-04): an unbounded view eventually
    ///         exceeds practical RPC response limits on a large index.
    function entries(bytes32 topicKey, uint256 cursor, uint256 limit) external view returns (Entry[] memory out) {
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 len = arr.length;
        if (cursor > len) revert BadRange();
        uint256 n = len - cursor;
        if (n > limit) n = limit;
        out = new Entry[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = arr[cursor + i];
        }
    }

    /// @notice Paginated supersafe slice: uncontested AND decided at full quorum
    ///         (H-09) AND aged past `minAge`. Age is a display policy, so it is a
    ///         caller argument rather than registry state — the index outlives any
    ///         particular parameter set.
    function supersafeEntries(bytes32 topicKey, uint256 minAge, uint256 cursor, uint256 limit)
        external
        view
        returns (Entry[] memory out)
    {
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 len = arr.length;
        if (cursor > len) revert BadRange();
        uint256 end = cursor + limit;
        if (end > len) end = len;

        uint256 count;
        for (uint256 i = cursor; i < end; ++i) {
            if (_isSupersafe(arr[i], minAge)) count++;
        }
        out = new Entry[](count);
        uint256 j;
        for (uint256 i = cursor; i < end; ++i) {
            if (_isSupersafe(arr[i], minAge)) out[j++] = arr[i];
        }
    }

    function _isSupersafe(Entry storage e, uint256 minAge) internal view returns (bool) {
        return e.uncontested && e.fullQuorum && block.timestamp - e.approvalTime >= minAge;
    }

    // --- governance ----------------------------------------------------------

    function proposeLogic(address logic) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        pendingLogic = PendingLogic({logic: logic, eta: block.timestamp + timelockDelay, exists: true});
        emit LogicProposed(logic, block.timestamp + timelockDelay);
    }

    function executeLogic() external onlyGovernance {
        PendingLogic memory pl = pendingLogic;
        if (!pl.exists) revert NoPendingProposal();
        if (block.timestamp < pl.eta) revert TimelockNotElapsed();
        logicState[pl.logic] = LogicState.OPEN_AND_SETTLE;
        delete pendingLogic;
        emit LogicAuthorized(pl.logic);
    }

    function cancelLogic() external onlyGovernance {
        delete pendingLogic;
    }

    /// @notice Stop a logic writing new entries while it settles existing cases.
    function retireLogic(address logic) external onlyGovernance {
        if (logicState[logic] != LogicState.OPEN_AND_SETTLE) revert NotLogic();
        logicState[logic] = LogicState.SETTLE_ONLY;
        emit LogicRetiring(logic);
    }

    function revokeLogic(address logic) external onlyGovernance {
        logicState[logic] = LogicState.NONE;
        emit LogicRevoked(logic);
    }

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
}
