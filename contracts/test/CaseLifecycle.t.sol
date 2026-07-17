// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract CaseLifecycleTest is ModerationTestBase {
    // --- submit guards -------------------------------------------------------

    function test_submit_bad_topic_count_reverts() public {
        bytes32[] memory none = new bytes32[](0);
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.BadTopicCount.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, none, 0, 100 * XBZZ);

        bytes32[] memory six = new bytes32[](6);
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.BadTopicCount.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, six, 0, 100 * XBZZ);
    }

    function test_submit_fee_too_low_reverts() public {
        uint256 lowFee = mod.minFee(1) - 1;
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.FeeTooLow.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, lowFee);
    }

    function test_submit_duplicate_reverts() public {
        _submit(mods[0]);
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.DuplicateSubmission.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);
    }

    // --- happy path ----------------------------------------------------------

    function test_full_lifecycle_all_approve_finalizes_approve() public {
        uint256 caseId = _submit(mods[0]);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW));

        _realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT));

        _commitAll(caseId, 0, Moderation.Vote.Approve);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.REVEAL));

        _revealAll(caseId, 0, Moderation.Vote.Approve);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.TALLY));

        _realizeOutcome(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.APPEAL_WINDOW));

        (,,,, uint256 approveSeats, uint256 rejectSeats,, Moderation.Outcome outcome,,) = mod.roundInfo(caseId, 0);
        assertGt(approveSeats, 0);
        assertEq(rejectSeats, 0);
        assertEq(uint256(outcome), uint256(Moderation.Outcome.Approve), "all-approve -> Approve");

        (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
        vm.warp(deadline);
        mod.finalize(caseId);
        (,,,,,, Moderation.Outcome finalOutcome) = mod.caseInfo(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.FINALIZED));
        assertEq(uint256(finalOutcome), uint256(Moderation.Outcome.Approve));
    }

    function test_full_lifecycle_all_reject_finalizes_reject() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _commitAll(caseId, 0, Moderation.Vote.Reject);
        _revealAll(caseId, 0, Moderation.Vote.Reject);
        _realizeOutcome(caseId);
        (,,,,, uint256 rejectSeats,, Moderation.Outcome outcome,,) = mod.roundInfo(caseId, 0);
        assertGt(rejectSeats, 0);
        assertEq(uint256(outcome), uint256(Moderation.Outcome.Reject), "all-reject -> Reject");
    }

    // --- commit/reveal guards ------------------------------------------------

    function test_non_seatholder_cannot_commit() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address nonHolder;
        for (uint256 i = 0; i < mods.length; i++) {
            if (mod.seatsOf(caseId, 0, mods[i]) == 0) {
                nonHolder = mods[i];
                break;
            }
        }
        vm.assume(nonHolder != address(0));
        vm.prank(nonHolder);
        vm.expectRevert(Moderation.NotSeatHolder.selector);
        mod.commitVote(caseId, keccak256("x"));
    }

    function test_double_commit_reverts() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address sh = mod.seatHolderAt(caseId, 0, 0);
        bytes32 h = keccak256(abi.encode(uint8(Moderation.Vote.Approve), SALT));
        vm.prank(sh);
        mod.commitVote(caseId, h);
        vm.prank(sh);
        vm.expectRevert(Moderation.AlreadyCommitted.selector);
        mod.commitVote(caseId, h);
    }

    function test_bad_reveal_reverts() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address sh = mod.seatHolderAt(caseId, 0, 0);
        bytes32 h = keccak256(abi.encode(uint8(Moderation.Vote.Approve), SALT));
        vm.prank(sh);
        mod.commitVote(caseId, h);
        vm.warp(block.timestamp + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.prank(sh);
        vm.expectRevert(Moderation.BadReveal.selector);
        mod.revealVote(caseId, Moderation.Vote.Approve, keccak256("wrong"));
    }

    // --- two-seed ordering ---------------------------------------------------

    function test_outcome_seed_armed_after_reveals_close() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (,,,,,,,, uint256 seatSnap,) = mod.roundInfo(caseId, 0);

        _commitAll(caseId, 0, Moderation.Vote.Approve);
        uint256 revealCloseBlock = block.number;
        _revealAll(caseId, 0, Moderation.Vote.Approve);

        (,,,,,,,,, uint256 outcomeSnap) = mod.roundInfo(caseId, 0);
        assertGt(outcomeSnap, seatSnap, "outcome seed after seat seed");
        assertGt(outcomeSnap, revealCloseBlock, "outcome seed after reveals close");
    }

    // --- widen + VOID --------------------------------------------------------

    function test_void_on_total_underparticipation_refunds_and_clears_dedup() public {
        uint256 caseId = _submit(mods[0]);
        assertGt(mod.openPotsTotal(), 0);
        _realizeSeats(caseId);

        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.VOID) {
            require(guard++ < 10, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.COMMIT) {
                vm.warp(block.timestamp + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(block.timestamp + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase during void drive");
            }
        }

        (,,,,,, uint256 widenCount,,,) = mod.roundInfo(caseId, 0);
        assertEq(widenCount, MAX_WIDEN, "widened to the cap before voiding");
        assertEq(mod.openPotsTotal(), 0, "pot released on void");
        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Void));

        uint256 caseId2 = _submit(mods[1]);
        assertGt(caseId2, caseId);
    }

    function test_widen_draws_more_seats_then_proceeds() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (uint256 nSeats0,,,,,,,,,) = mod.roundInfo(caseId, 0);

        vm.warp(block.timestamp + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.warp(block.timestamp + REVEAL_WINDOW);
        mod.closeReveal(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "widened, back to commit");
        (uint256 nSeats1,,,,,, uint256 widen,,,) = mod.roundInfo(caseId, 0);
        assertEq(widen, 1);
        assertGt(nSeats1, nSeats0, "widen added seats");

        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.APPEAL_WINDOW));
    }

    // --- VOID applies the §6.3 brief freeze to commit-and-vanish (F1) --------

    function test_void_freezes_commit_and_vanish() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);

        // Cycle-1 seat-holders commit, then nobody ever reveals.
        (, uint256 sh0,,,,,,,,) = mod.roundInfo(caseId, 0);
        address[] memory committers = new address[](sh0);
        bytes32 h = keccak256(abi.encode(uint8(Moderation.Vote.Approve), SALT));
        for (uint256 i = 0; i < sh0; i++) {
            committers[i] = mod.seatHolderAt(caseId, 0, i);
            vm.prank(committers[i]);
            mod.commitVote(caseId, h);
        }

        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.VOID) {
            require(guard++ < 12, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.COMMIT) {
                vm.warp(block.timestamp + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(block.timestamp + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase");
            }
        }

        // Every committer that vanished is frozen for the brief duration and
        // excluded from the tree — the deterrent is present in the VOID path.
        for (uint256 i = 0; i < committers.length; i++) {
            (,,, uint256 frozen, uint256 frozenUntil,,,,) = mod.moderatorInfo(committers[i]);
            assertGt(frozen, 0, "vanisher's stake frozen, not released");
            assertGt(frozenUntil, block.timestamp, "vanisher frozen");
            assertLe(frozenUntil - block.timestamp, 1 days, "brief freeze only");
            assertEq(mod.eligibleWeightOf(committers[i]), 0, "frozen -> excluded");
        }
        _assertConservation();
    }

    /// The zero-commit VOID (nobody ever committed) still freezes nothing — there
    /// was no stake to lock.
    function test_void_with_no_commits_freezes_nothing() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.VOID) {
            require(guard++ < 12, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.COMMIT) {
                vm.warp(block.timestamp + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(block.timestamp + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase");
            }
        }
        assertEq(mod.totalFrozenStake(), 0, "no commits -> nothing frozen");
        _assertConservation();
    }

    // --- conservation across a lifecycle -------------------------------------

    function test_conservation_holds_through_lifecycle() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _commitAll(caseId, 0, Moderation.Vote.Approve);
        _revealAll(caseId, 0, Moderation.Vote.Approve);
        _realizeOutcome(caseId);
        _assertConservation();
    }

    // H-06: two cases opened in the SAME block share a snapshot block (hence the
    // same blockhash entropy), but domain separation by caseId must give them
    // distinct seat seeds — otherwise a batch of same-block submissions would be
    // judged by one identical panel.
    function test_H06_same_block_cases_get_distinct_seeds() public {
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[0], fee);
        vm.prank(mods[0]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[0]);
        uint256 a = mod.submit(Moderation.Kind.SUBMISSION, keccak256("A"), META, _topics(), 0, fee);

        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[1]);
        uint256 b = mod.submit(Moderation.Kind.SUBMISSION, keccak256("B"), META, _topics(), 0, fee);

        // Both were submitted in the same block -> identical seatSnapshotBlock.
        vm.roll(block.number + SEED_LAG + 1);
        mod.realizeSeats(a);
        mod.realizeSeats(b);
        assertTrue(mod.__seatSeed(a, 0) != mod.__seatSeed(b, 0), "domain separation -> distinct seat seeds");
    }
}
