// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";
import {ModerationAuthority} from "./ModerationAuthority.sol";

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
///   * `everChallenged` — whether any identity volunteered a position against the
///     published outcome. Every other vote on a case is the discharge of a
///     commitment made blind; a challenge is the one deliberate objection, so it is
///     the one thing an entry can carry that somebody chose to put their name to.
///     §7 retired the word "anonymous" for this: nothing here is anonymous, and the
///     absence of a challenge is partly the absence of appetite for the freeze
///     liability rather than the absence of doubt.
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

    struct Origin {
        address moderation;
        uint256 caseId;
        uint32 guidelinesVersion;
        bytes32 guidelinesHash;
    }
    ModerationAuthority public immutable authority;
    mapping(bytes32 => Origin) public originOf;
    mapping(address => mapping(uint256 => bool)) public applied;
    event OutcomeApplied(address indexed moderation, uint256 indexed caseId, uint8 actionType);
    error InvalidOutcome();

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

    error ZeroTopicKey();
    error BadStatus();
    error NoSuchEntry();
    error BadPage();

    constructor(ModerationAuthority authority_) {
        authority = authority_;
    }

    /// @dev An entry is per (claim, topic): the same content filed under two
    ///      topics is two rows, because a reader asks a topic for its entries.
    function entryKeyOf(bytes32 claimKey, bytes32 topicKey) public pure returns (bytes32) {
        return keccak256(abi.encode(claimKey, topicKey));
    }

    // --------------------------------------------------------------- writes

    function _writeEntry(bytes32 claimKey, bytes32 topicKey, uint8 status,
        bool allTicketsApprove, bool everChallenged, uint32 approve, uint32 reject) internal {
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

    /// @dev An approved removal takes the entry out; its origin remains recorded.

    function _removeListing(bytes32 claimKey, bytes32 topicKey) internal {
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

        // Both boundaries below are EQUIVALENT mutants and mutation testing reports
        // both as survivors forever. At `offset == l.length`, `>=` returns the empty
        // page and `>` falls through to `n = 0` and builds the same empty page. At
        // `n == limit`, `>` leaves `n` alone and `>=` assigns it its own value. Do
        // not chase either; neither changes what a caller observes.
        if (offset >= l.length) return new bytes32[](0);

        uint256 n = l.length - offset;
        if (n > limit) n = limit;
        page = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            page[i] = l[offset + i];
        }
    }

    function applyOutcome(uint256 id) external {
        authority.requireCase(msg.sender, id, true);
        Moderation m = Moderation(msg.sender);
        Moderation.Case memory c = m.caseInfo(id);
        if (c.phase != uint8(Moderation.Phase.FINALIZED) || applied[msg.sender][id]) revert InvalidOutcome();
        applied[msg.sender][id] = true;
        bytes32[5] memory topics = m.topicsOf(id);
        if (c.preliminary == 1) {
            for (uint256 i; i < c.topicCount; ++i) {
                if (c.actionType == 1) {
                    _removeListing(c.claimKey, topics[i]);
                } else {
                    _writeEntry(
                        c.claimKey,
                        topics[i],
                        1,
                        c.ticketsApprove == 3,
                        c.everChallenged,
                        c.pooledApprove,
                        c.pooledReject
                    );
                    originOf[entryKeyOf(c.claimKey, topics[i])] =
                        Origin(msg.sender, id, m.guidelinesVersion(), m.guidelinesHash());
                }
            }
        }
        emit OutcomeApplied(msg.sender, id, c.actionType);
    }
}
