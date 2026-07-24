// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {StakeRegistryHarness} from "./harnesses/StakeRegistryHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

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
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.prank(sh);
        vm.expectRevert(Moderation.BadReveal.selector);
        mod.revealVote(caseId, Moderation.Vote.Approve, keccak256("wrong"));
    }

    // H-08: seats a widen re-draws onto a voter AFTER it committed are
    // uncollateralized, so the reveal must tally only the seats collateralized at
    // commit. Otherwise a voter could withhold, trigger a widen, and get extra
    // voting weight for free.
    function test_H08_widen_added_seats_not_tallied() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address sh = mod.seatHolderAt(caseId, 0, 0);

        // Commit with whatever seat count it holds now.
        bytes32 h = mod.computeCommit(caseId, 0, sh, Moderation.Vote.Approve, SALT);
        vm.prank(sh);
        mod.commitVote(caseId, h);
        uint256 collateralized = mod.__committedSeats(caseId, 0, sh);

        // A widen lands 7 extra seats on this already-committed voter.
        mod.__injectWidenSeats(caseId, 0, sh, 7);
        assertEq(mod.__seats(caseId, 0, sh), collateralized + 7, "post-widen seat count is inflated");

        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.prank(sh);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);

        // Tally is capped to the collateralized (commit-time) seat count.
        assertEq(mod.__talliedSeats(caseId, 0, sh), collateralized, "tally == collateralized seats, not inflated");
    }

    // M-01: a commitment is bound to its voter, so copying another voter's commit
    // hash is useless — the copier cannot reveal it.
    function test_M01_copied_commitment_cannot_be_revealed() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (, uint256 shc,,,,,,,,) = mod.roundInfo(caseId, 0);
        require(shc >= 2, "need two distinct seat-holders");
        address a = mod.seatHolderAt(caseId, 0, 0);
        address b = mod.seatHolderAt(caseId, 0, 1);

        bytes32 hA = mod.computeCommit(caseId, 0, a, Moderation.Vote.Approve, SALT);
        vm.prank(a);
        mod.commitVote(caseId, hA);
        vm.prank(b);
        mod.commitVote(caseId, hA); // b copies a's commitment

        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);

        // a reveals its own vote fine; b cannot reveal the copied commitment.
        vm.prank(a);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        vm.prank(b);
        vm.expectRevert(Moderation.BadReveal.selector);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
    }

    // M-02: reveal is a hard-deadline window. Past the reveal deadline (but before
    // anyone closes the phase) a reveal must revert, so a late voter cannot watch
    // the tally and front-run the closing transaction.
    function test_M02_reveal_after_deadline_reverts() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _commitAll(caseId, 0, Moderation.Vote.Approve);
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.REVEAL));

        (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
        vm.warp(deadline); // exactly at the deadline: window is [open, deadline)
        address sh = mod.seatHolderAt(caseId, 0, 0);
        vm.prank(sh);
        vm.expectRevert(Moderation.PhaseDeadlinePassed.selector);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
    }

    // --- two-seed ordering ---------------------------------------------------

    function test_outcome_seed_armed_after_reveals_close() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (,,,,,,,, uint256 seatSnap,) = mod.roundInfo(caseId, 0);

        _commitAll(caseId, 0, Moderation.Vote.Approve);
        uint256 revealCloseBlock = vm.getBlockNumber();
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
            require(guard++ < 24, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.DRAW) {
                // H-05: each widen re-arms fresh entropy, so a widen returns to DRAW.
                vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
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

        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
        mod.closeReveal(caseId);
        // H-05: a widen re-arms fresh entropy, so the round goes back to DRAW;
        // realizing the new seed draws the added seats and reopens COMMIT.
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "widened, back to draw");
        _realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "fresh seed drawn, commit reopened");
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
            require(guard++ < 24, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.DRAW) {
                // H-05: each widen re-arms fresh entropy, so a widen returns to DRAW.
                vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase");
            }
        }

        // Every committer that vanished is frozen for the brief duration and
        // excluded from the tree — the deterrent is present in the VOID path.
        for (uint256 i = 0; i < committers.length; i++) {
            (,,, uint256 frozen, uint256 frozenUntil,,,,) = stakeReg.moderatorInfo(committers[i]);
            assertGt(frozen, 0, "vanisher's stake frozen, not released");
            assertGt(frozenUntil, vm.getBlockTimestamp(), "vanisher frozen");
            assertLe(frozenUntil - vm.getBlockTimestamp(), 1 days, "brief freeze only");
            assertEq(stakeReg.eligibleWeightOf(committers[i]), 0, "frozen -> excluded");
        }
        _assertConservation();
    }

    /// The zero-commit VOID (nobody ever committed) still freezes nothing — there
    /// was no stake to lock.
    // H-07/H-10: seat-holders were drawn on capacity they PLEDGED, so failing to
    // show up is a choice with a cost — each no-show takes a bounded freeze of one
    // seat's worth of its own stake. (Before the duty pool, occupying seats and
    // refusing to commit was free, which is what let an attacker kill an appeal
    // panel and confiscate the challenger's bond.) Principal is never transferred.
    function test_void_with_no_commits_penalizes_no_shows() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.VOID) {
            require(guard++ < 24, "did not void");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.DRAW) {
                // H-05: each widen re-arms fresh entropy, so a widen returns to DRAW.
                vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase");
            }
        }
        assertGt(stakeReg.totalFrozenStake(), 0, "pledged no-shows are penalized, not free");
        // The penalty is a freeze of their own stake, never a transfer: total
        // stake across the system is unchanged.
        uint256 totalStaked;
        for (uint256 i = 0; i < mods.length; i++) {
            totalStaked += stakeReg.totalStakeOf(mods[i]);
        }
        assertEq(totalStaked, 8 * 3000 * XBZZ, "no principal was moved or destroyed");
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

    // H-07: seats are drawn with replacement, so a moderator can win more seats
    // than its free stake collateralizes. Requiring the full riskPerSeat x seats
    // made commitVote revert outright — it could not serve even one of its seats,
    // and a panel of such holders could never reach quorum. It must now commit as
    // many seats as it can back, with the rest uncollateralized and untallied.
    function test_H07_overdrawn_moderator_commits_what_it_can_afford() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address sh = mod.seatHolderAt(caseId, 0, 0);

        // Force the seat count above what this holder can collateralize: give it
        // 5 seats but only enough eligible free stake for a couple.
        mod.__injectWidenSeats(caseId, 0, sh, 5);
        uint256 seats = mod.__seats(caseId, 0, sh);
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(sh);
        // Exit-reserve most of the stake so only 1 seat is affordable.
        uint256 keep = riskPerSeat; // exactly one seat's worth
        vm.prank(sh);
        stakeReg.requestExit(free - keep);
        assertLt(keep / riskPerSeat, seats, "holder is genuinely overdrawn");

        bytes32 h = mod.computeCommit(caseId, 0, sh, Moderation.Vote.Approve, SALT);
        vm.prank(sh);
        mod.commitVote(caseId, h); // must NOT revert

        // It committed exactly what it could afford, and the tally follows (H-08).
        assertEq(mod.__committedSeats(caseId, 0, sh), keep / riskPerSeat, "committed only affordable seats");
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.prank(sh);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        assertEq(mod.__talliedSeats(caseId, 0, sh), keep / riskPerSeat, "tally <= collateralized seats");
    }

    // H-05: adaptive activation. An attacker with mature-but-unactivated stake
    // waits until the seat seed's blockhash is public, then activates a favourable
    // subset immediately before realizeSeats. The draw must NOT proceed on that
    // now-known seed: adding draw-eligible weight re-arms fresh entropy, so the
    // attacker only destroyed the seed it was trying to exploit.
    function test_H05_activation_after_seed_known_rearms() public {
        uint256 caseId = _submit(mods[0]);

        // Stake matures but is deliberately left unactivated.
        address lurker = makeAddr("lurker");
        bzz.mint(lurker, 1000 * XBZZ);
        vm.prank(lurker);
        bzz.approve(address(stakeReg), type(uint256).max);
        vm.prank(lurker);
        stakeReg.stake(500 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);

        // The seed's snapshot block is now mined: its blockhash is public.
        vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
        (,,,,,,,, uint256 snapBefore,) = mod.roundInfo(caseId, 0);

        // Attacker activates now, reshaping the tree against a known seed.
        stakeReg.activate(lurker);

        // The draw does not proceed — it re-arms to a fresh, unknown block.
        mod.realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "still in DRAW: seed re-armed");
        (,,,,,,,, uint256 snapAfter,) = mod.roundInfo(caseId, 0);
        assertGt(snapAfter, snapBefore, "re-armed to a later, not-yet-known block");

        // With no further eligibility changes, the next poke draws normally.
        vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
        mod.realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "draw proceeds on untainted entropy");
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
        vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
        mod.realizeSeats(a);
        mod.realizeSeats(b);
        assertTrue(mod.__seatSeed(a, 0) != mod.__seatSeed(b, 0), "domain separation -> distinct seat seeds");
    }

    // --- capacity-limited panels (H-07 + M2.5 port) --------------------------

    /// The registry seats only where collateral exists, so a panel can come back
    /// SHORT of the commit target when pledged duty capacity is scarce. The
    /// round must report what was actually seated — an inflated nSeats would
    /// misreport the panel — and must still make progress rather than revert.
    function test_panel_short_of_target_when_capacity_is_scarce() public {
        MockBZZ b = new MockBZZ();
        (ModerationHarness m, StakeRegistryHarness sr,) = _deployStack(b);

        // Two moderators pledging ONE concurrent seat each: a depth-0 target of
        // 5 can never be filled, however much stake they hold.
        address[2] memory few = [makeAddr("few0"), makeAddr("few1")];
        for (uint256 i = 0; i < 2; i++) {
            b.mint(few[i], 1000 * XBZZ);
            vm.prank(few[i]);
            b.approve(address(sr), type(uint256).max);
            vm.prank(few[i]);
            sr.stake(100 * XBZZ);
        }
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        for (uint256 i = 0; i < 2; i++) {
            sr.activate(few[i]);
            vm.prank(few[i]);
            sr.setDutyUnits(1);
        }
        vm.roll(vm.getBlockNumber() + 1);

        // Compute the fee BEFORE any prank: an external call in the argument
        // list would consume it.
        uint256 fee = m.minFee(1);
        b.mint(address(this), fee);
        b.approve(address(m), type(uint256).max);
        uint256 caseId = m.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);

        // H-05: a widen or an eligibility change returns the round to DRAW, so
        // the poke has to be driven in a loop.
        uint256 guard;
        do {
            require(guard++ < 24, "never left DRAW");
            vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
            m.realizeSeats(caseId);
        } while (uint256(_phaseOfLocal(m, caseId)) == uint256(Moderation.Phase.DRAW));

        assertEq(m.commitTargetAt(0), 5, "depth-0 commit target is 5");
        (uint256 nSeats, uint256 shCount,,,,,,,,) = m.roundInfo(caseId, 0);
        assertEq(nSeats, 2, "reports seats actually seated, not the target");
        assertEq(shCount, 2, "one seat each, both distinct");
        assertEq(uint256(_phaseOfLocal(m, caseId)), uint256(Moderation.Phase.COMMIT), "short panel still opens commit");

        // Capacity is fully reserved while the panel is live, so neither is
        // drawable again until the case ends.
        assertEq(sr.totalEligibleWeight(), 0, "both moderators' capacity is in use");
    }

    function _phaseOfLocal(ModerationHarness m, uint256 caseId) internal view returns (Moderation.Phase p) {
        (,, p,,,,) = m.caseInfo(caseId);
    }
}
