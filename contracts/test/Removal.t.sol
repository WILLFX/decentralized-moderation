// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice §8 — a removal targets a listed entry and runs through the same
///         engine. **Approve means remove.** The fee is paid whichever way it
///         goes, which is what stops removal being free censorship.
contract RemovalTest is Test {
    Moderation mod;
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;

    uint256 constant COMMIT_WINDOW = 15 minutes;
    uint256 constant REVEAL_WINDOW = 30 minutes;
    uint256 constant CHALLENGE_WINDOW = 1 hours;
    uint256 constant MAX_WAIT = 1 hours;
    uint256 constant FREEZE = 8 days;
    uint256 constant SEED_LAG = 2;
    uint256 constant FEE = 1000;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    address submitter = address(0x5011);
    address remover = address(0x7E11);
    address[8] mods;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(
            address(token),
            address(stakes),
            address(index),
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            CHALLENGE_WINDOW,
            MAX_WAIT,
            FREEZE,
            SEED_LAG,
            FEE
        );
        for (uint256 i; i < mods.length; ++i) {
            mods[i] = address(uint160(0x1000 + i));
            stakes.add(mods[i]);
        }
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? submitter : remover;
            token.mint(a, 1_000_000);
            vm.prank(a);
            token.approve(address(mod), type(uint256).max);
        }
        vm.roll(blk);
        vm.warp(ts);
    }

    function _advance(uint256 n) internal {
        blk += n;
        vm.roll(blk);
    }

    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function _commit(uint256 id, address m, uint8 v, uint8 round) internal {
        bytes32 h = mod.commitHash(id, round, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    /// @dev Drives a case from an open COMMIT_A through to FINALIZED, with the
    ///      given number of moderators all voting `v`.
    function _runToFinal(uint256 id, uint8 v, uint256 n) internal {
        _advance(SEED_LAG + 1);
        for (uint256 i; i < n; ++i) _commit(id, mods[i], v, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i; i < n; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, v, bytes32("s"));
        }
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);
    }

    function _list() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("biology");
        topics[1] = keccak256("geography");
        vm.prank(submitter);
        id = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
        _runToFinal(id, APPROVE, 4);
    }

    // -----------------------------------------------------------------

    function test_approveOnARemovalMeansRemove() public {
        uint256 listing = _list();
        assertEq(index.writes(), 2, "listed under both topics");

        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, APPROVE, 4);

        assertEq(mod.caseInfo(rem).preliminary, APPROVE);
        assertTrue(mod.removed(listing), "target marked removed");
        assertEq(index.removals(), 2, "removed from BOTH topics");
        assertEq(index.writes(), 2, "a removal writes no new entry");
    }

    /// @dev A removal that loses leaves the entry exactly where it was.
    function test_rejectOnARemovalLeavesItListed() public {
        uint256 listing = _list();

        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, REJECT, 4);

        assertEq(mod.caseInfo(rem).preliminary, REJECT);
        assertFalse(mod.removed(listing), "still listed");
        assertEq(index.removals(), 0);
    }

    /// @dev §8 — the fee is paid whether the removal succeeds or fails. A failed
    ///      removal refunds nothing; it pays the moderators who voted to keep.
    function test_failedRemovalStillCostsTheSubmitterTheFee() public {
        uint256 listing = _list();
        uint256 before = token.balanceOf(remover);

        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, REJECT, 4);

        assertEq(before - token.balanceOf(remover), FEE, "fee is gone");
        assertEq(mod.refundOwed(rem), 0, "and nothing is owed back");

        // it went to the moderators who correctly voted to keep
        mod.claim(rem, mods[0]);
        assertEq(token.balanceOf(mods[0]), FEE / 4);
    }

    /// @dev A removal runs the identical staged lifecycle — including the
    ///      property the staging exists for.
    function test_removalUsesTheSameStagedEngine() public {
        uint256 listing = _list();
        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);

        _advance(SEED_LAG + 1);
        assertEq(mod.caseInfo(rem).seedBlockB, 0, "B unknowable during A");
        for (uint256 i; i < 3; ++i) _commit(rem, mods[i], APPROVE, 0);
        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitA(rem);
        assertGt(mod.caseInfo(rem).seedBlockB, 0, "seeded only once A closed");
    }

    function test_onlyOneRemovalOpenAtATime() public {
        uint256 listing = _list();
        vm.prank(remover);
        mod.submitRemoval(listing, FEE);

        vm.prank(remover);
        vm.expectRevert(Moderation.RemovalAlreadyOpen.selector);
        mod.submitRemoval(listing, FEE);
    }

    function test_cannotRemoveTwice() public {
        uint256 listing = _list();
        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, APPROVE, 4);

        vm.prank(remover);
        vm.expectRevert(Moderation.AlreadyRemoved.selector);
        mod.submitRemoval(listing, FEE);
    }

    /// @dev A failed removal releases its hold, so the entry can be challenged
    ///      again later on fresh evidence.
    function test_failedRemovalReleasesTheHold() public {
        uint256 listing = _list();
        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, REJECT, 4);

        assertEq(mod.openRemovalOf(listing), 0, "hold released");
        vm.prank(remover);
        mod.submitRemoval(listing, FEE); // a second attempt is allowed, at full price
    }

    function test_cannotRemoveSomethingNeverListed() public {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        uint256 open = mod.submit(keccak256("x"), keccak256("y"), topics, FEE);

        vm.prank(remover);
        vm.expectRevert(Moderation.NotARemovableListing.selector);
        mod.submitRemoval(open, FEE); // still mid-lifecycle

        vm.prank(remover);
        vm.expectRevert(Moderation.NotARemovableListing.selector);
        mod.submitRemoval(9999, FEE); // never existed
    }

    function test_cannotRemoveARejectedCase() public {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        uint256 id = mod.submit(keccak256("x"), keccak256("y"), topics, FEE);
        _runToFinal(id, REJECT, 4);

        vm.prank(remover);
        vm.expectRevert(Moderation.NotARemovableListing.selector);
        mod.submitRemoval(id, FEE);
    }

    /// @dev A removal is not itself removable — otherwise a removal of a removal
    ///      is a recursion with no base case.
    function test_cannotRemoveARemoval() public {
        uint256 listing = _list();
        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);
        _runToFinal(rem, APPROVE, 4);

        vm.prank(remover);
        vm.expectRevert(Moderation.NotARemovableListing.selector);
        mod.submitRemoval(rem, FEE);
    }

    /// @dev The removal inherits the listing's hashes and topics rather than
    ///      re-declaring them, so the two cannot disagree about the target.
    function test_removalInheritsTheTargetsIdentity() public {
        uint256 listing = _list();
        vm.prank(remover);
        uint256 rem = mod.submitRemoval(listing, FEE);

        Moderation.Case memory l = mod.caseInfo(listing);
        Moderation.Case memory r = mod.caseInfo(rem);
        assertEq(r.contentHash, l.contentHash);
        assertEq(r.metaHash, l.metaHash);
        assertEq(r.claimKey, l.claimKey);
        assertEq(r.topicCount, l.topicCount);
        assertEq(r.targetCaseId, listing);
        assertEq(r.actionType, mod.ACTION_REMOVE());
        assertEq(mod.topicsOf(rem)[0], mod.topicsOf(listing)[0]);
        assertEq(mod.topicsOf(rem)[1], mod.topicsOf(listing)[1]);
    }
}
