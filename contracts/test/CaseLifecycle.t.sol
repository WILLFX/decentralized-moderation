// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

contract CaseLifecycleTest is Test {
    ModerationHarness internal mod;
    MockBZZ internal bzz;

    uint256 internal constant XBZZ = 1e16;
    uint256 internal constant MIN_STAKE = 10 * XBZZ;
    uint256 internal constant ACTIVATION_DELAY = 7 days;

    // Working param mirrors (for the test's own bookkeeping).
    uint256 internal constant COMMIT_TIMEOUT = 24 hours;
    uint256 internal constant REVEAL_WINDOW = 24 hours;
    uint256 internal constant MAX_WIDEN = 3;
    uint256 internal constant SEED_LAG = 2;

    bytes32 internal constant SALT = keccak256("salt");
    bytes32 internal constant CONTENT = keccak256("content");
    bytes32 internal constant META = keccak256("meta");

    address[] internal mods;

    function setUp() public {
        bzz = new MockBZZ();
        mod = new ModerationHarness(IERC20(address(bzz)));
        for (uint256 i = 0; i < 8; i++) {
            address m = makeAddr(string(abi.encodePacked("mod", i)));
            mods.push(m);
            bzz.mint(m, 100_000 * XBZZ);
            vm.prank(m);
            bzz.approve(address(mod), type(uint256).max);
            vm.prank(m);
            mod.stake(1000 * XBZZ);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        for (uint256 i = 0; i < mods.length; i++) {
            mod.activate(mods[i]);
        }
        vm.roll(block.number + 1);
    }

    function _topics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = keccak256("marine biology");
    }

    function _submit(address who) internal returns (uint256 caseId) {
        // NOTE: compute minFee() before arming the prank — evaluating an external
        // call in the argument list would consume the prank, so submit would run
        // as the test contract, not `who`.
        uint256 fee = mod.minFee(1);
        bzz.mint(who, fee);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(who);
        caseId = mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);
    }

    function _phase(uint256 caseId) internal view returns (Moderation.Phase p) {
        (, , p, , , , ) = mod.caseInfo(caseId);
    }

    /// Roll past the seat snapshot and realize the panel (re-poke if re-armed).
    function _realizeSeats(uint256 caseId) internal {
        vm.roll(block.number + SEED_LAG + 1);
        mod.realizeSeats(caseId);
        // If the blockhash was unavailable it re-arms and stays in DRAW; retry.
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            vm.roll(block.number + SEED_LAG + 1);
            mod.realizeSeats(caseId);
        }
    }

    /// Every current seat-holder commits `vote`.
    function _commitAll(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, depth);
        bytes32 commitHash = keccak256(abi.encode(uint8(vote), SALT));
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, depth, i);
            vm.prank(sh);
            mod.commitVote(caseId, commitHash);
        }
    }

    /// Every seat-holder reveals `vote`.
    function _revealAll(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, depth);
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, depth, i);
            vm.prank(sh);
            mod.revealVote(caseId, vote, SALT);
        }
    }

    function _realizeOutcome(uint256 caseId) internal {
        vm.roll(block.number + SEED_LAG + 1);
        mod.realizeOutcome(caseId);
        while (_phase(caseId) == Moderation.Phase.TALLY) {
            vm.roll(block.number + SEED_LAG + 1);
            mod.realizeOutcome(caseId);
        }
    }

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
        // all seat-holders committed -> auto-advanced to REVEAL
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.REVEAL));

        _revealAll(caseId, 0, Moderation.Vote.Approve);
        // all revealed -> auto-closed -> TALLY (armed)
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.TALLY));

        _realizeOutcome(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.APPEAL_WINDOW));

        (,,,, uint256 approveSeats, uint256 rejectSeats,, Moderation.Outcome outcome,,) = mod.roundInfo(caseId, 0);
        assertGt(approveSeats, 0);
        assertEq(rejectSeats, 0);
        assertEq(uint256(outcome), uint256(Moderation.Outcome.Approve), "all-approve -> Approve");

        // Close the appeal window with no appeal -> FINALIZED.
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
        // Find a non-seat-holder among mods.
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
        // move to reveal
        vm.warp(block.timestamp + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        // reveal with wrong salt
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
        uint256 revealCloseBlock = block.number; // all revealed in this block
        _revealAll(caseId, 0, Moderation.Vote.Approve);

        (,,,,,,,,, uint256 outcomeSnap) = mod.roundInfo(caseId, 0);
        // Outcome seed's snapshot block is strictly after both the seat snapshot
        // and the block at which the tally was fixed (§7).
        assertGt(outcomeSnap, seatSnap, "outcome seed after seat seed");
        assertGt(outcomeSnap, revealCloseBlock, "outcome seed after reveals close");
    }

    // --- widen + VOID --------------------------------------------------------

    function test_void_on_total_underparticipation_refunds_and_clears_dedup() public {
        uint256 caseId = _submit(mods[0]);
        uint256 potStart = mod.openPotsTotal();
        assertGt(potStart, 0);
        _realizeSeats(caseId);

        // Nobody commits or reveals. Drive widen cycles until VOID.
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

        // Widen was exhausted before voiding.
        (,,,,,, uint256 widenCount,,,) = mod.roundInfo(caseId, 0);
        assertEq(widenCount, MAX_WIDEN, "widened to the cap before voiding");

        // Pot cleared; submitter refunded fee minus the poke bounty.
        assertEq(mod.openPotsTotal(), 0, "pot released on void");
        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Void));

        // Dedup cleared: the same content is resubmittable.
        uint256 caseId2 = _submit(mods[1]);
        assertGt(caseId2, caseId);
    }

    function test_widen_draws_more_seats_then_proceeds() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (uint256 nSeats0,,,,,,,,,) = mod.roundInfo(caseId, 0);

        // First cycle: nobody commits -> widen once.
        vm.warp(block.timestamp + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.warp(block.timestamp + REVEAL_WINDOW);
        mod.closeReveal(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "widened, back to commit");
        (uint256 nSeats1,,,,,, uint256 widen,,,) = mod.roundInfo(caseId, 0);
        assertEq(widen, 1);
        assertGt(nSeats1, nSeats0, "widen added seats");

        // Now enough seat-holders participate to clear MIN_REVEALS and finalize.
        _commitAll(caseId, 0, Moderation.Vote.Approve);
        // may auto-advance to REVEAL if all committed; else close it
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(block.timestamp + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        _revealAll(caseId, 0, Moderation.Vote.Approve);
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(block.timestamp + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.TALLY));
        _realizeOutcome(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.APPEAL_WINDOW));
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

    function _assertConservation() internal view {
        uint256 sumBuckets = mod.totalFreeStake() + mod.totalCommittedStake() + mod.totalFrozenStake();
        assertEq(
            bzz.balanceOf(address(mod)),
            sumBuckets + mod.openPotsTotal(),
            "conservation: balance == staked buckets + live pots"
        );
    }
}
