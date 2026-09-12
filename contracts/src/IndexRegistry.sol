// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IndexRegistry
/// @notice The topic → entry index of `specs/protocol.md` §7 — what a reader
///         actually consults.
///
/// **There is no `SUPER_SAFE` flag, and that is the design decision this contract
/// embodies.** The previous revision answered "is this safe enough" itself, with
/// a `strict` predicate and an open-question counter. §7 replaces that with two
/// recorded facts and lets the client decide:
///
///   * `allTicketsApprove` — whether the draw was unanimous;
///   * `everChallenged` — whether anyone challenged it. A challenged entry is
///     never anonymous.
///
/// A client wanting a cautious filter reads those and applies its own rule. The
/// protocol does not decide what "safe enough" means on a reader's behalf, and a
/// client that wants a different bar does not need the protocol changed.
contract IndexRegistry {
    struct Entry {
        bool written;
        uint8 status; // Outcome: 1 = APPROVE, 2 = REJECT
        // --- §7's two facts
        bool allTicketsApprove;
        bool everChallenged;
        // --- the tally that produced it
        uint32 approve;
        uint32 reject;
        uint40 finalizedAt;
    }

    address public immutable deployer;
    address public moderation;

    mapping(bytes32 => Entry) internal entries;

    /// @dev Topic → the entries listed under it, plus a 1-based position so an
    ///      entry can be removed in O(1) by swapping the tail into its slot.
    mapping(bytes32 => bytes32[]) internal listing;
    mapping(bytes32 => mapping(bytes32 => uint256)) internal posPlusOne;

    event EntryWritten(
        bytes32 indexed entryKey,
        bytes32 indexed topicKey,
        uint8 status,
        bool allTicketsApprove,
        bool everChallenged
    );
    event ListingAdded(bytes32 indexed topicKey, bytes32 indexed entryKey);
    event ListingRemoved(bytes32 indexed topicKey, bytes32 indexed entryKey);

    error NotModeration();
    error NotDeployer();
    error AlreadySet();
    error ZeroTopicKey();
    error BadStatus();
    error NoSuchEntry();
    error BadPage();

    constructor() {
        deployer = msg.sender;
    }

    function setModeration(address m) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (moderation != address(0)) revert AlreadySet();
        moderation = m;
    }

    modifier onlyModeration() {
        if (msg.sender != moderation) revert NotModeration();
        _;
    }

    /// @dev An entry is per (claim, topic): the same content filed under two
    ///      topics is two rows, because a reader asks a topic for its entries.
    function entryKeyOf(bytes32 claimKey, bytes32 topicKey) public pure returns (bytes32) {
        return keccak256(abi.encode(claimKey, topicKey));
    }

    // --------------------------------------------------------------- writes

    function writeEntry(
        bytes32 claimKey,
        bytes32 topicKey,
        uint8 status,
        bool allTicketsApprove,
        bool everChallenged,
        uint32 approve,
        uint32 reject
    ) external onlyModeration {
        if (topicKey == bytes32(0)) revert ZeroTopicKey();
        if (status != 1 && status != 2) revert BadStatus();

        bytes32 k = entryKeyOf(claimKey, topicKey);
        entries[k] = Entry({
            written: true,
            status: status,
            allTicketsApprove: allTicketsApprove,
            everChallenged: everChallenged,
            approve: approve,
            reject: reject,
            finalizedAt: uint40(block.timestamp)
        });

        // only an approval is listed; a rejection is recorded and not surfaced
        if (status == 1 && posPlusOne[topicKey][k] == 0) {
            listing[topicKey].push(k);
            posPlusOne[topicKey][k] = listing[topicKey].length;
            emit ListingAdded(topicKey, k);
        }
        emit EntryWritten(k, topicKey, status, allTicketsApprove, everChallenged);
    }

    /// @dev §8 — a successful removal case takes the entry out. Approve on a
    ///      removal means remove, so `Moderation` calls this rather than
    ///      `writeEntry` when a removal finalizes as Approve.
    function removeListing(bytes32 claimKey, bytes32 topicKey) external onlyModeration {
        bytes32 k = entryKeyOf(claimKey, topicKey);
        if (!entries[k].written) revert NoSuchEntry();

        uint256 p = posPlusOne[topicKey][k];
        if (p != 0) {
            bytes32[] storage l = listing[topicKey];
            uint256 last = l.length - 1;
            uint256 i = p - 1;
            if (i != last) {
                bytes32 moved = l[last];
                l[i] = moved;
                posPlusOne[topicKey][moved] = p;
            }
            l.pop();
            posPlusOne[topicKey][k] = 0;
            emit ListingRemoved(topicKey, k);
        }
        entries[k].status = 2;
    }

    // ---------------------------------------------------------------- reads

    function entryOf(bytes32 claimKey, bytes32 topicKey) external view returns (Entry memory) {
        return entries[entryKeyOf(claimKey, topicKey)];
    }

    function isListed(bytes32 claimKey, bytes32 topicKey) external view returns (bool) {
        return posPlusOne[topicKey][entryKeyOf(claimKey, topicKey)] != 0;
    }

    function listedCount(bytes32 topicKey) external view returns (uint256) {
        return listing[topicKey].length;
    }

    /// @notice Paged enumeration. **Nothing here walks an unbounded list.**
    /// @dev A topic accumulates entries without limit, so a function that reads a
    ///      whole topic is one that stops working at a size nobody chose. The
    ///      caller pages; cost is O(limit) whatever the topic has grown to.
    function listedPage(bytes32 topicKey, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page)
    {
        if (limit == 0) revert BadPage();
        bytes32[] storage l = listing[topicKey];
        if (offset >= l.length) return new bytes32[](0);

        uint256 n = l.length + offset;
        if (n > limit) n = limit;
        page = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            page[i] = l[offset + i];
        }
    }
}
