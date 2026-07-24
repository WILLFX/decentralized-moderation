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
        uint256 caseId; // back-reference of the approving case
    }

    mapping(bytes32 => Entry[]) internal indexByTopic;
    mapping(bytes32 => bool) internal topicSeen;
    /// topic -> caseId -> position+1, so deletion is O(1) (H-03).
    mapping(bytes32 => mapping(uint256 => uint256)) internal entryPosPlusOne;

    address public governance;
    uint256 public immutable timelockDelay;
    mapping(address => bool) public isLogic;

    struct PendingLogic {
        address logic;
        uint256 eta;
        bool exists;
    }

    PendingLogic public pendingLogic;
    address public pendingGovernance;

    event TopicCreated(bytes32 indexed topicKey);
    event EntryWritten(uint256 indexed caseId, bytes32 indexed topicKey, bool uncontested, bool fullQuorum);
    event EntryRemoved(uint256 indexed caseId, bytes32 indexed topicKey);
    event LogicProposed(address indexed logic, uint256 eta);
    event LogicAuthorized(address indexed logic);
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
        if (!isLogic[msg.sender]) revert NotLogic();
        _;
    }

    constructor(uint256 _timelockDelay) {
        timelockDelay = _timelockDelay;
        governance = msg.sender;
    }

    // --- logic-facing --------------------------------------------------------

    function writeEntry(
        bytes32 topicKey,
        uint256 caseId,
        bytes32 contentHash,
        bytes32 metaHash,
        bool uncontested,
        bool fullQuorum
    ) external onlyLogic {
        if (!topicSeen[topicKey]) {
            topicSeen[topicKey] = true;
            emit TopicCreated(topicKey);
        }
        indexByTopic[topicKey].push(
            Entry({
                contentHash: contentHash,
                metaHash: metaHash,
                approvalTime: uint40(block.timestamp),
                uncontested: uncontested,
                fullQuorum: fullQuorum,
                caseId: caseId
            })
        );
        entryPosPlusOne[topicKey][caseId] = indexByTopic[topicKey].length;
        emit EntryWritten(caseId, topicKey, uncontested, fullQuorum);
    }

    /// O(1) swap-and-pop (H-03). No-op if absent, so a removal whose target was
    /// already deleted settles cleanly.
    function deleteEntry(bytes32 topicKey, uint256 caseId) external onlyLogic {
        uint256 p = entryPosPlusOne[topicKey][caseId];
        if (p == 0) return;
        Entry[] storage arr = indexByTopic[topicKey];
        uint256 idx = p - 1;
        uint256 last = arr.length - 1;
        if (idx != last) {
            Entry storage moved = arr[last];
            arr[idx] = moved;
            entryPosPlusOne[topicKey][moved.caseId] = idx + 1;
        }
        arr.pop();
        delete entryPosPlusOne[topicKey][caseId];
        emit EntryRemoved(caseId, topicKey);
    }

    // --- reads (permissionless, never gated) ---------------------------------

    function entryCount(bytes32 topicKey) external view returns (uint256) {
        return indexByTopic[topicKey].length;
    }

    function entryAt(bytes32 topicKey, uint256 i) external view returns (Entry memory) {
        return indexByTopic[topicKey][i];
    }

    function isIndexed(bytes32 topicKey, uint256 caseId) external view returns (bool) {
        return entryPosPlusOne[topicKey][caseId] != 0;
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
        isLogic[pl.logic] = true;
        delete pendingLogic;
        emit LogicAuthorized(pl.logic);
    }

    function cancelLogic() external onlyGovernance {
        delete pendingLogic;
    }

    function revokeLogic(address logic) external onlyGovernance {
        isLogic[logic] = false;
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
