// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract IndexTest is ModerationTestBase {
    bytes32 internal constant TK = keccak256("marine biology");

    function _submitRemoval(address who, uint256 targetCaseId) internal returns (uint256 caseId) {
        uint256 fee = mod.minFee(1);
        bzz.mint(who, fee);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(who);
        caseId = mod.submitRemoval(targetCaseId, fee);
    }

    function _settleRemovalApprove(uint256 remId) internal {
        _realizeSeats(remId);
        _runRoundToAppealWindow(remId, 0, Moderation.Vote.Approve);
        _finalize(remId);
        mod.claim(remId);
    }

    // H-02: an obsolete removal must never clear a dedup reservation that a newer
    // resubmission now owns. Dedup is keyed by owner (caseId+1), so only the
    // current holder can release it.
    function test_obsolete_removal_cannot_wipe_newer_reservation() public {
        bytes32 key = keccak256(abi.encode(CONTENT, META, TK));

        uint256 t = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(t);
        assertEq(mod.dedupOwner(key), t, "T owns the reservation");

        // Two removals opened against T while it is still indexed.
        uint256 rem1 = _submitRemoval(mods[1], t);
        uint256 rem2 = _submitRemoval(mods[2], t);

        // First removal frees the reservation.
        _settleRemovalApprove(rem1);
        assertEq(mod.entryCount(TK), 0);
        assertEq(mod.dedupOwner(key), 0, "reservation freed after removal");

        // Same content resubmitted: N now owns the reservation and is indexed.
        uint256 nCase = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(nCase);
        assertEq(mod.dedupOwner(key), nCase, "N now owns the reservation");
        assertEq(mod.entryCount(TK), 1);

        // The obsolete removal (targets T) settles: it must not touch N's
        // reservation or entry.
        _settleRemovalApprove(rem2);
        assertEq(mod.dedupOwner(key), nCase, "obsolete removal leaves N's reservation intact");
        assertEq(mod.entryCount(TK), 1, "N's entry untouched");

        // Proof the reservation is really held: a duplicate is rejected.
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[3], fee);
        vm.prank(mods[3]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[3]);
        vm.expectRevert(Moderation.DuplicateSubmission.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);
    }

    // --- write happens only at settlement ------------------------------------

    function test_entry_written_only_at_settlement() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        assertEq(mod.entryCount(TK), 0, "no provisional write at the depth-0 tally");
        _finalize(caseId);
        assertEq(mod.entryCount(TK), 0, "nothing before claim");

        mod.claim(caseId);
        assertEq(mod.entryCount(TK), 1, "written at settlement");
        Moderation.Entry memory e = mod.entryAt(TK, 0);
        assertEq(e.contentHash, CONTENT);
        assertEq(e.metaHash, META);
        assertEq(e.caseId, caseId);
        assertTrue(e.uncontested, "all-approve -> uncontested");
    }

    function test_reject_writes_nothing_and_is_resubmittable() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Reject);
        mod.claim(caseId);
        assertEq(mod.entryCount(TK), 0, "reject writes no entry");
        // dedup cleared -> same content resubmittable
        uint256 caseId2 = _submit(mods[1]);
        assertGt(caseId2, caseId);
    }

    // --- §8.1 regression: approval won on appeal is written ------------------

    function test_approval_won_on_appeal_is_written_contested() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Reject); // rejected at depth 0
        _appeal(caseId, makeAddr("ap"));
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Approve); // flipped to Approve
        _finalize(caseId);
        mod.claim(caseId);

        assertEq(mod.entryCount(TK), 1, "approve-won-on-appeal writes an entry");
        Moderation.Entry memory e = mod.entryAt(TK, 0);
        assertFalse(e.uncontested, "a reject was revealed at depth 0 -> contested");
    }

    // --- uncontested semantics -----------------------------------------------

    function test_frivolous_appeal_keeps_uncontested() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve); // no reject
        _appeal(caseId, makeAddr("frivolous")); // argues Reject, but...
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Approve); // panel again approves
        _finalize(caseId);
        mod.claim(caseId);

        assertEq(mod.entryCount(TK), 1);
        Moderation.Entry memory e = mod.entryAt(TK, 0);
        assertTrue(e.uncontested, "no reject ever revealed -> appeal alone doesn't clear it");
    }

    // --- removal deletes entries and clears dedup ----------------------------

    function test_removal_deletes_entry_and_frees_dedup() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        assertEq(mod.entryCount(TK), 1);

        uint256 rem = _submitRemoval(mods[1], caseId);
        _realizeSeats(rem);
        _runRoundToAppealWindow(rem, 0, Moderation.Vote.Approve); // approve removal
        _finalize(rem);
        mod.claim(rem);

        assertEq(mod.entryCount(TK), 0, "entry deleted");
        // target's dedup cleared -> content resubmittable
        uint256 caseId2 = _submit(mods[2]);
        assertGt(caseId2, rem);
    }

    // H-01: two removals opened against the same still-indexed target. The first
    // deletes the entry; the second settles as a clean no-op (guarded by the
    // target's `indexed` generation signal), never reverting or touching a
    // now-unrelated entry.
    function test_concurrent_removals_second_settles_as_noop() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        assertEq(mod.entryCount(TK), 1);

        // Both submitted while the target is still indexed.
        uint256 rem1 = _submitRemoval(mods[1], caseId);
        uint256 rem2 = _submitRemoval(mods[2], caseId);

        _realizeSeats(rem1);
        _runRoundToAppealWindow(rem1, 0, Moderation.Vote.Approve);
        _finalize(rem1);
        mod.claim(rem1);
        assertEq(mod.entryCount(TK), 0, "first removal deletes the entry");

        _realizeSeats(rem2);
        _runRoundToAppealWindow(rem2, 0, Moderation.Vote.Approve);
        _finalize(rem2);
        mod.claim(rem2); // clean no-op, no revert
        assertEq(uint256(_phase(rem2)), uint256(Moderation.Phase.SETTLED));
        assertEq(mod.entryCount(TK), 0, "second removal changes nothing");
    }

    // H-01: a removal can only be opened against a target that is a settled,
    // approved submission currently in the index. Future IDs, rejected content,
    // and already-removed entries are rejected at submit — no more lazy target
    // resolution at claim time.
    function test_removal_requires_indexed_target() public {
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[1], 3 * fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);

        // (a) future / nonexistent case id
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitRemoval(999, fee);

        // (b) a rejected submission was never indexed
        uint256 rejected = _runUndisputed(mods[0], Moderation.Vote.Reject);
        mod.claim(rejected);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitRemoval(rejected, fee);

        // (c) an approved-then-removed target is no longer indexed
        uint256 approved = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(approved);
        uint256 rem = _submitRemoval(mods[2], approved);
        _realizeSeats(rem);
        _runRoundToAppealWindow(rem, 0, Moderation.Vote.Approve);
        _finalize(rem);
        mod.claim(rem);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitRemoval(approved, fee);
    }

    // --- supersafe view ------------------------------------------------------

    function test_supersafe_requires_uncontested_and_age() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        // Fresh uncontested entry: in the superset but not yet supersafe.
        assertEq(mod.entryCount(TK), 1);
        assertEq(mod.supersafeEntries(TK).length, 0, "too young for supersafe");

        vm.warp(block.timestamp + 96 hours);
        assertEq(mod.supersafeEntries(TK).length, 1, "aged uncontested -> supersafe");
    }

    function test_contested_entry_never_supersafe() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Reject);
        _appeal(caseId, makeAddr("ap"));
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Approve);
        _finalize(caseId);
        mod.claim(caseId);

        vm.warp(block.timestamp + 200 hours);
        assertEq(mod.entryCount(TK), 1, "in superset");
        assertEq(mod.supersafeEntries(TK).length, 0, "contested is never supersafe, regardless of age");
    }
}
