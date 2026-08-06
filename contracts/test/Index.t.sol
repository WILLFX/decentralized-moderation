// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";

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
    // resubmission now owns. The reservation is keyed by its owner — (logic,
    // caseId) since M2.6-P0-1b — so only the current holder can release it.
    //
    // Read through `_dedupOwner`, which reports the owning LOGIC as well as the
    // case. The removed `mod.dedupOwner` returned a bare caseId, and the target
    // here is case 0, so two of these assertions could not tell "T owns it" from
    // "nobody owns it" and passed either way.
    function test_obsolete_removal_cannot_wipe_newer_reservation() public {
        bytes32 key = keccak256(abi.encode(CONTENT, META, TK));

        uint256 t = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(t);
        (address ownerLogic, uint256 ownerCase) = _dedupOwner(key);
        assertEq(ownerLogic, address(mod), "T's reservation is held by this logic");
        assertEq(ownerCase, t, "T owns the reservation");

        // Two removals opened against T while it is still indexed.
        uint256 rem1 = _submitRemoval(mods[1], t);
        uint256 rem2 = _submitRemoval(mods[2], t);

        // First removal frees the reservation.
        _settleRemovalApprove(rem1);
        assertEq(mod.entryCount(TK), 0);
        (ownerLogic,) = _dedupOwner(key);
        assertEq(ownerLogic, address(0), "reservation freed after removal");

        // Same content resubmitted: N now owns the reservation and is indexed.
        uint256 nCase = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(nCase);
        (ownerLogic, ownerCase) = _dedupOwner(key);
        assertEq(ownerLogic, address(mod), "N's reservation is held by this logic");
        assertEq(ownerCase, nCase, "N now owns the reservation");
        assertEq(mod.entryCount(TK), 1);

        // The obsolete removal (targets T) settles: it must not touch N's
        // reservation or entry.
        _settleRemovalApprove(rem2);
        (ownerLogic, ownerCase) = _dedupOwner(key);
        assertEq(ownerLogic, address(mod), "obsolete removal leaves the holder intact");
        assertEq(ownerCase, nCase, "obsolete removal leaves N's reservation intact");
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
        IndexRegistry.Entry memory e = mod.entryAt(TK, 0);
        assertEq(e.contentHash, CONTENT);
        assertEq(e.metaHash, META);
        assertEq(e.localCaseId, caseId);
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
        IndexRegistry.Entry memory e = mod.entryAt(TK, 0);
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
        IndexRegistry.Entry memory e = mod.entryAt(TK, 0);
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

    // --- H-09: under-quorum approvals never reach the supersafe view ---------

    // A single approving seat (after max widen the outcome arms on `reveals != 0`)
    // must land in the superset but NEVER the supersafe subset, however long it
    // ages: supersafe now also requires MIN_REVEALS independent revealers.
    function test_one_seat_approval_never_supersafe() public {
        MockBZZ b = new MockBZZ();
        (ModerationHarness m, StakeRegistry sr,) = _deployStack(b);
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectTopic(caseId, TK);
        m.__injectRound(caseId);
        m.__injectSeat(caseId, 0, makeAddr("solo"), 1, 0, 1); // one Approve revealer
        m.claim(caseId);

        assertEq(m.entryCount(TK), 1, "one-seat approval is in the superset");
        IndexRegistry.Entry memory e = m.entryAt(TK, 0);
        assertTrue(e.uncontested, "no reject -> uncontested");
        assertFalse(e.fullQuorum, "one independent revealer is not full quorum");

        vm.warp(vm.getBlockTimestamp() + 200 hours);
        assertEq(_supersafe(m, TK).length, 0, "under-quorum approval never supersafe, regardless of age");
    }

    // H-09, the half the test above cannot reach. It uses ONE address holding ONE
    // seat, so `revealedCount` and `revealedSeats` are both 1 and the assertion
    // passes under either definition — the fix could be reverted with the suite
    // still green.
    //
    // The property is that quorum counts independent REVEALERS, not seats: one
    // multi-seat voter must not satisfy it alone. Seats are drawn with replacement,
    // so a single moderator holding a whole small panel is an ordinary outcome, and
    // supersafe is the strongest claim this protocol makes about a piece of content.
    //
    // Paired with a positive control that differs in exactly one dimension: the
    // same number of revealed seats, spread across `minReveals` addresses.
    function test_full_quorum_counts_revealers_not_seats() public {
        uint256 minReveals = mod.getParams().minReveals;

        MockBZZ b = new MockBZZ();
        (ModerationHarness m, StakeRegistry sr,) = _deployStack(b);
        sr;
        uint256 solo = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectTopic(solo, TK);
        m.__injectRound(solo);
        // One address, a whole quorum's worth of SEATS.
        m.__injectSeat(solo, 0, makeAddr("whale"), minReveals, 0, 1);
        m.claim(solo);

        (,, uint256 cCount, uint256 rCount,,,,,,) = m.roundInfo(solo, 0);
        cCount;
        assertEq(rCount, 1, "one independent revealer");
        IndexRegistry.Entry memory e = m.entryAt(TK, 0);
        assertFalse(e.fullQuorum, "one voter's seats are not a quorum, however many it holds");
        vm.warp(vm.getBlockTimestamp() + 200 hours);
        assertEq(_supersafe(m, TK).length, 0, "and it never reaches supersafe");

        // Control: the same revealed seats, spread across `minReveals` addresses.
        bytes32 tk2 = keccak256("control topic");
        uint256 spread = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectTopic(spread, tk2);
        m.__injectRound(spread);
        for (uint256 i = 0; i < minReveals; i++) {
            m.__injectSeat(spread, 0, makeAddr(string(abi.encodePacked("indep", i))), 1, 0, 1);
        }
        m.claim(spread);

        IndexRegistry.Entry memory e2 = m.entryAt(tk2, 0);
        assertTrue(e2.fullQuorum, "the same seats across enough revealers IS a quorum");
        vm.warp(vm.getBlockTimestamp() + 200 hours); // age past supersafeAge
        assertEq(_supersafe(m, tk2).length, 1, "and it does reach supersafe");
        assertEq(_supersafe(m, TK).length, 0, "while the multi-seat solo still does not");
    }

    // An appealed case whose EARLIER round was decided under quorum is also barred
    // from supersafe, even if the final round had a full panel.
    function test_appealed_case_with_degraded_earlier_round_never_supersafe() public {
        MockBZZ b = new MockBZZ();
        (ModerationHarness m, StakeRegistry sr,) = _deployStack(b);
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectTopic(caseId, TK);
        m.__setDepth(caseId, 1);
        // round 0: degraded (armed under quorum), round 1 (final): full panel.
        m.__injectRound(caseId);
        m.__injectSeat(caseId, 0, makeAddr("d0a"), 1, 0, 1);
        m.__setUnderQuorum(caseId, 0);
        m.__injectRound(caseId);
        m.__injectSeat(caseId, 1, makeAddr("d1a"), 1, 0, 1);
        m.__injectSeat(caseId, 1, makeAddr("d1b"), 1, 0, 1);
        m.__injectSeat(caseId, 1, makeAddr("d1c"), 1, 0, 1);
        m.claim(caseId);

        IndexRegistry.Entry memory e = m.entryAt(TK, 0);
        assertFalse(e.fullQuorum, "a degraded earlier round bars supersafe");
        vm.warp(vm.getBlockTimestamp() + 200 hours);
        assertEq(_supersafe(m, TK).length, 0, "not supersafe");
    }

    // --- supersafe view ------------------------------------------------------

    function test_supersafe_requires_uncontested_and_age() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        // Fresh uncontested entry: in the superset but not yet supersafe.
        assertEq(mod.entryCount(TK), 1);
        assertEq(_supersafe(mod, TK).length, 0, "too young for supersafe");

        vm.warp(vm.getBlockTimestamp() + 96 hours);
        assertEq(_supersafe(mod, TK).length, 1, "aged uncontested -> supersafe");
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

        vm.warp(vm.getBlockTimestamp() + 200 hours);
        assertEq(mod.entryCount(TK), 1, "in superset");
        assertEq(_supersafe(mod, TK).length, 0, "contested is never supersafe, regardless of age");
    }

    // --- M2.6-F1: topic 0 is a sentinel, not a topic --------------------------

    /// `IndexRegistry.legacyEntryInfo` returns `topicKey == 0` to mean "not live",
    /// and its docblock claimed no live entry could sit there because `globalId`
    /// starts at 1. Those are different sentinels: `nextEntryId = 1` says nothing
    /// about which topic an entry is filed under, and nothing rejected topic 0 at
    /// the mint.
    ///
    /// The bite is not that the sentinel is untidy. A live entry under topic 0
    /// reads as dead through `legacyEntryInfo`, so `submitLegacyRemoval` refuses it
    /// — while `deleteEntry` still works through the LOCAL route, because
    /// `entryPosPlusOne[0][globalId]` is non-zero. So the entry becomes unremovable
    /// at exactly the moment its writing logic is superseded, which is the one
    /// situation P0-1c exists to cover, and the content reservation goes with it:
    /// `deleteEntry` is the only release path, so that content is permanently
    /// unsubmittable too.
    ///
    /// Enforced in the PERMANENT registry, because it is the registry's docblock
    /// that claims the sentinel holds. A guard in `Moderation` alone would leave
    /// the claim false for the next logic.
    function test_F1_an_entry_cannot_be_minted_under_the_zero_topic() public {
        // Driven from the logic boundary, as a real settlement would call it.
        vm.prank(address(mod));
        vm.expectRevert(IndexRegistry.ZeroTopicKey.selector);
        indexReg.writeEntry(bytes32(0), 1, keccak256("c"), keccak256("m"), true, true, 1, 1, keccak256("d"));

        // The sentinel is only sound because of that refusal, so assert the pair:
        // a real topic still mints, and the id it mints is reachable.
        vm.prank(address(mod));
        uint256 gid = indexReg.writeEntry(TK, 1, keccak256("c"), keccak256("m"), true, true, 1, 1, keccak256("d"));
        (bytes32 topicKey,,,) = indexReg.legacyEntryInfo(gid);
        assertEq(topicKey, TK, "a live entry reports its topic, never zero");
    }

    /// The other half, and it is NOT a second home for the invariant. Settlement
    /// writes entries from `_settleFinish`, so a case carrying topic 0 that reached
    /// APPROVE would revert inside `claim()` on the registry's guard — permanently,
    /// with every seat-holder's stake locked behind it (item 4's failure class).
    /// That is strictly worse than the unremovable entry the registry guard exists
    /// to prevent. Refusing at submit is what makes the registry's revert
    /// unreachable from settlement.
    function test_F1_a_case_carrying_the_zero_topic_cannot_be_opened() public {
        bytes32[] memory withZero = new bytes32[](1);
        withZero[0] = bytes32(0);
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[0], fee);
        vm.prank(mods[0]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.ZeroTopicKey.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, withZero, 0, fee);

        // And in company: one good topic does not launder a zero one.
        bytes32[] memory mixed = new bytes32[](2);
        mixed[0] = TK;
        mixed[1] = bytes32(0);
        uint256 fee2 = mod.minFee(2);
        bzz.mint(mods[0], fee2);
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.ZeroTopicKey.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, mixed, 0, fee2);
    }
}
