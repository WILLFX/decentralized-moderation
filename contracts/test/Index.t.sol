// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";

contract IndexTest is Test {
    IndexRegistry idx;

    address constant CASES = address(0xCA5E5);
    bytes32 constant BIO = keccak256("biology");
    bytes32 constant GEO = keccak256("geography");

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    function setUp() public {
        idx = new IndexRegistry();
        idx.setModeration(CASES);
    }

    function _write(bytes32 claim, bytes32 topic, uint8 status, bool unanimous, bool challenged)
        internal
    {
        vm.prank(CASES);
        idx.writeEntry(claim, topic, status, unanimous, challenged, 5, 1);
    }

    // -----------------------------------------------------------------

    /// @dev §7 — the index records facts and does not judge. There is no
    ///      `isSuperSafe`; a client reads these two and applies its own rule.
    function test_recordsTheTwoFactsRatherThanALabel() public {
        _write(keccak256("a"), BIO, APPROVE, true, false);
        _write(keccak256("b"), BIO, APPROVE, false, true);

        IndexRegistry.Entry memory a = idx.entryOf(keccak256("a"), BIO);
        assertTrue(a.allTicketsApprove, "unanimous draw");
        assertFalse(a.everChallenged, "and never challenged");

        IndexRegistry.Entry memory b = idx.entryOf(keccak256("b"), BIO);
        assertFalse(b.allTicketsApprove);
        assertTrue(b.everChallenged, "challenged: never anonymous");

        // both are listed. the index does not filter on the reader's behalf
        assertTrue(idx.isListed(keccak256("a"), BIO));
        assertTrue(idx.isListed(keccak256("b"), BIO));
        assertEq(idx.listedCount(BIO), 2);
    }

    function test_carriesTheTallyThatProducedIt() public {
        _write(keccak256("a"), BIO, APPROVE, true, false);
        IndexRegistry.Entry memory e = idx.entryOf(keccak256("a"), BIO);
        assertEq(e.approve, 5);
        assertEq(e.reject, 1);
        assertGt(e.finalizedAt, 0);
    }

    /// @dev An entry is per (claim, topic): one claim filed under two topics is
    ///      two rows, because a reader asks a topic for its entries.
    function test_oneClaimUnderTwoTopicsIsTwoRows() public {
        bytes32 claim = keccak256("a");
        _write(claim, BIO, APPROVE, true, false);
        _write(claim, GEO, APPROVE, true, false);

        assertEq(idx.listedCount(BIO), 1);
        assertEq(idx.listedCount(GEO), 1);
        assertTrue(idx.entryKeyOf(claim, BIO) != idx.entryKeyOf(claim, GEO));
    }

    function test_rejectionIsRecordedButNotListed() public {
        _write(keccak256("a"), BIO, REJECT, false, false);
        assertTrue(idx.entryOf(keccak256("a"), BIO).written, "recorded");
        assertFalse(idx.isListed(keccak256("a"), BIO), "not surfaced");
        assertEq(idx.listedCount(BIO), 0);
    }

    /// @dev §8 — Approve on a removal means remove. The swap-remove has to keep
    ///      every surviving entry addressable, which is where this shape of
    ///      contract usually breaks: removing from the middle moves the tail.
    function test_removalKeepsSurvivorsAddressable() public {
        bytes32[5] memory claims;
        for (uint256 i; i < 5; ++i) {
            claims[i] = keccak256(abi.encode("c", i));
            _write(claims[i], BIO, APPROVE, true, false);
        }
        assertEq(idx.listedCount(BIO), 5);

        // remove from the middle — the tail gets swapped into slot 1
        vm.prank(CASES);
        idx.removeListing(claims[1], BIO);

        assertEq(idx.listedCount(BIO), 4);
        assertFalse(idx.isListed(claims[1], BIO), "removed");
        for (uint256 i; i < 5; ++i) {
            if (i == 1) continue;
            assertTrue(idx.isListed(claims[i], BIO), "survivor still addressable");
        }

        // and the moved one can itself still be removed
        vm.prank(CASES);
        idx.removeListing(claims[4], BIO);
        assertEq(idx.listedCount(BIO), 3);
        assertFalse(idx.isListed(claims[4], BIO));
        assertTrue(idx.isListed(claims[0], BIO));
        assertTrue(idx.isListed(claims[2], BIO));
        assertTrue(idx.isListed(claims[3], BIO));
    }

    /// @dev `isListed` reads the position map; the listing ARRAY is what a reader
    ///      actually enumerates. Mutation testing found the two can disagree:
    ///      inverting the swap-remove guard makes `pop()` delete the tail entry
    ///      instead of the removed one, and the tail's map entry survives — so it
    ///      still reports as listed while being gone from the page.
    ///
    ///      Every removal test that only asked `isListed` passed on that mutant.
    function test_removalKeepsThePageItselfCorrect() public {
        bytes32[5] memory claims;
        for (uint256 i; i < 5; ++i) {
            claims[i] = keccak256(abi.encode("c", i));
            _write(claims[i], BIO, APPROVE, true, false);
        }

        vm.prank(CASES);
        idx.removeListing(claims[1], BIO); // from the middle: the tail moves

        bytes32[] memory page = idx.listedPage(BIO, 0, 10);
        assertEq(page.length, 4, "the page shrank by exactly one");

        bool[5] memory seen;
        for (uint256 i; i < page.length; ++i) {
            for (uint256 j; j < 5; ++j) {
                if (page[i] == idx.entryKeyOf(claims[j], BIO)) seen[j] = true;
            }
        }
        assertFalse(seen[1], "the removed entry is off the page");
        for (uint256 j; j < 5; ++j) {
            if (j == 1) continue;
            assertTrue(seen[j], "a survivor vanished from the page");
        }
    }

    function test_removalMarksTheEntryRejected() public {
        _write(keccak256("a"), BIO, APPROVE, true, false);
        vm.prank(CASES);
        idx.removeListing(keccak256("a"), BIO);
        assertEq(idx.entryOf(keccak256("a"), BIO).status, REJECT);
    }

    function test_removingLastEntry() public {
        _write(keccak256("a"), BIO, APPROVE, true, false);
        vm.prank(CASES);
        idx.removeListing(keccak256("a"), BIO);
        assertEq(idx.listedCount(BIO), 0);
        assertFalse(idx.isListed(keccak256("a"), BIO));
    }

    function test_pagingNeverWalksTheWholeTopic() public {
        for (uint256 i; i < 12; ++i) {
            _write(keccak256(abi.encode("c", i)), BIO, APPROVE, true, false);
        }
        assertEq(idx.listedPage(BIO, 0, 5).length, 5);
        assertEq(idx.listedPage(BIO, 10, 5).length, 2, "short final page");
        assertEq(idx.listedPage(BIO, 12, 5).length, 0, "past the end");
        assertEq(idx.listedPage(BIO, 99, 5).length, 0);

        vm.expectRevert(IndexRegistry.BadPage.selector);
        idx.listedPage(BIO, 0, 0);
    }

    function test_onlyModerationMayWrite() public {
        vm.expectRevert(IndexRegistry.NotModeration.selector);
        idx.writeEntry(keccak256("a"), BIO, APPROVE, true, false, 1, 0);

        vm.expectRevert(IndexRegistry.NotModeration.selector);
        idx.removeListing(keccak256("a"), BIO);
    }

    function test_rejectsBadInput() public {
        vm.prank(CASES);
        vm.expectRevert(IndexRegistry.ZeroTopicKey.selector);
        idx.writeEntry(keccak256("a"), bytes32(0), APPROVE, true, false, 1, 0);

        vm.prank(CASES);
        vm.expectRevert(IndexRegistry.BadStatus.selector);
        idx.writeEntry(keccak256("a"), BIO, 7, true, false, 1, 0);

        vm.prank(CASES);
        vm.expectRevert(IndexRegistry.NoSuchEntry.selector);
        idx.removeListing(keccak256("never"), BIO);
    }
}
