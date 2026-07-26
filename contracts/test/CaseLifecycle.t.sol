// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
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
                _rollToSeed(caseId);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else if (p == Moderation.Phase.VOID_SETTLING) {
                // M2.6-P0-7: `closeReveal` no longer disposes participants inline;
                // it opens VOID_SETTLING and a keeper drains the cursor.
                mod.claim(caseId);
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
                _rollToSeed(caseId);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else if (p == Moderation.Phase.VOID_SETTLING) {
                // M2.6-P0-7: `closeReveal` no longer disposes participants inline;
                // it opens VOID_SETTLING and a keeper drains the cursor.
                mod.claim(caseId);
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
                _rollToSeed(caseId);
                mod.realizeSeats(caseId);
            } else if (p == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else if (p == Moderation.Phase.VOID_SETTLING) {
                // M2.6-P0-7: `closeReveal` no longer disposes participants inline;
                // it opens VOID_SETTLING and a keeper drains the cursor.
                mod.claim(caseId);
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

        // Force the seat count above what this holder can collateralize. Note
        // WHERE the excess comes from: injected widen seats, which are added to
        // `r.seats` without going through `drawPanel` and therefore carry no
        // escrow. Since M2.6-P0-2 a DRAWN seat always has its collateral bonded
        // at draw time, so the draw can no longer overdraw a holder — widening
        // is the remaining source, and that is P1-1's open finding.
        mod.__injectWidenSeats(caseId, 0, sh, 5);
        uint256 seats = mod.__seats(caseId, 0, sh);
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(sh);
        // Exit-reserve most of the stake so only one seat's worth stays free.
        uint256 keep = riskPerSeat;
        vm.prank(sh);
        stakeReg.requestExit(free - keep);

        // Backing is free stake PLUS the escrow already posted for this holder's
        // real drawn seats — that escrow exists precisely to back them, and
        // ignoring it here would make a fully-bonded holder unable to commit at
        // all (the H-07 liveness failure this path exists to prevent).
        uint256 affordable = (keep + stakeReg.dutyBondedOf(sh)) / riskPerSeat;
        assertLt(affordable, seats, "holder is genuinely overdrawn");

        bytes32 h = mod.computeCommit(caseId, 0, sh, Moderation.Vote.Approve, SALT);
        vm.prank(sh);
        mod.commitVote(caseId, h); // must NOT revert

        // It committed exactly what it could back, and the tally follows (H-08).
        assertEq(mod.__committedSeats(caseId, 0, sh), affordable, "committed only affordable seats");
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.prank(sh);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        assertEq(mod.__talliedSeats(caseId, 0, sh), affordable, "tally <= collateralized seats");
    }

    /// M2.6-P0-2b: the invariant that makes the clamp above non-binding, and
    /// therefore makes the `unbackedSeats` counter that recorded its shortfall
    /// unreachable in production. Escrow ALONE — every scrap of free stake reserved
    /// for exit — backs every seat the registry drew.
    ///
    /// The argument the deletion rests on: `drawPanel` escrows the registry's
    /// `riskPerSeat` into THIS case's obligation for every seat it issues, that
    /// escrow is spendable only by this case's `lock` or `settleDuty`, and a
    /// ruleset may never lock more per seat than the registry's unit. So
    /// `dutyBonded >= seats * caseRisk` at commit time, always.
    ///
    /// The only way to violate it is `__injectWidenSeats`, which writes `r.seats`
    /// without going through the registry. Reasoning off that harness rather than
    /// off production is what put the wrong description into P1-1.
    function test_every_drawn_seat_is_backed_by_its_own_escrow_at_commit() public {
        // Only two moderators are drawable, so a 5-seat panel MUST land several
        // seats on the same address — the multi-seat holder is the case the clamp
        // exists for, and leaving it to chance would let this pass vacuously.
        for (uint256 i = 2; i < mods.length; i++) {
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(0);
        }
        _settleEpoch(stakeReg);

        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        assertGt(shCount, 0, "a panel was seated");

        uint256 multiSeat;
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            uint256 seats = mod.__seats(caseId, 0, sh);
            if (seats > 1) multiSeat++;

            // Strip every unbonded token: reserve all free stake for exit, so the
            // escrow is the ONLY backing left.
            (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(sh);
            if (free > 0) {
                vm.prank(sh);
                stakeReg.requestExit(free);
            }
            assertEq(
                stakeReg.dutyBondedOf(sh), seats * riskPerSeat, "escrow is exactly one unit per drawn seat"
            );

            bytes32 h = mod.computeCommit(caseId, 0, sh, Moderation.Vote.Approve, SALT);
            vm.prank(sh);
            mod.commitVote(caseId, h);
            assertEq(mod.__committedSeats(caseId, 0, sh), seats, "every drawn seat is collateralized");
        }
        assertGt(multiSeat, 0, "the multi-seat case IS exercised");
        _assertConservation();
    }

    // --- M2.6-P0-6: a draw that cannot complete still ends -------------------

    /// A case opened when the network has NO drawable capacity must reach a
    /// terminal state without external intervention, and anyone must be able to
    /// push it there.
    ///
    /// `realizeSeats` reverts `NoEligibleModerators` in this state, so the case
    /// sat in DRAW with its fee taken and no autonomous way out.
    function test_case_with_no_network_capacity_reaches_a_terminal_state() public {
        // Every moderator un-pledges: the tree empties at the next epoch.
        uint256 units = mod.getParams().riskPerSeat; // before pranking
        units;
        for (uint256 i = 0; i < mods.length; i++) {
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(0);
        }
        _settleEpoch(stakeReg);
        assertEq(stakeReg.totalEligibleWeight(), 0, "no drawable capacity anywhere");

        uint256 caseId = _submit(mods[0]);
        uint256 submitterBefore = bzz.balanceOf(mods[0]);

        // The draw genuinely cannot proceed.
        vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
        stakeReg.advanceEpoch(type(uint256).max);
        vm.expectRevert(Moderation.NoEligibleModerators.selector);
        mod.realizeSeats(caseId);

        // Before the deadline the case is still allowed to hope.
        vm.expectRevert(Moderation.PhaseDeadlineNotPassed.selector);
        mod.resolveStalledDraw(caseId);

        // After it, ANYONE can end the case — here a party with no stake in it.
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        mod.resolveStalledDraw(caseId);
        while (_phase(caseId) == Moderation.Phase.VOID_SETTLING) {
            vm.prank(stranger);
            mod.claim(caseId);
        }

        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.VOID), "terminal");
        assertGt(bzz.balanceOf(mods[0]), submitterBefore, "the submitter got the pot back");
        _assertConservation();
    }

    /// Moderators seated before a draw was abandoned are released, not penalised:
    /// the case never reached COMMIT, so there was nothing for them to fail to do.
    function test_abandoned_draw_releases_seated_duty_without_penalty() public {
        uint256 caseId = _submit(mods[0]);
        _rollToSeed(caseId);
        stakeReg.advanceEpoch(type(uint256).max);
        mod.realizeSeats(caseId); // a panel IS seated here

        // Drain the capacity of everyone NOT already holding a seat. P0-2 refuses
        // to let a seated moderator un-pledge below what a live panel holds, which
        // is exactly right — so the seated ones keep their reservations and are the
        // participants whose disposal this test is about.
        for (uint256 i = 0; i < mods.length; i++) {
            (, uint256 reserved,) = stakeReg.dutyOf(mods[i]);
            if (reserved == 0) {
                vm.prank(mods[i]);
                stakeReg.setDutyUnits(0);
            }
        }
        _settleEpoch(stakeReg);

        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
            vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
            mod.closeReveal(caseId); // zero reveals -> widen -> back to DRAW
        }
        if (_phase(caseId) != Moderation.Phase.DRAW) return; // widen exhausted: not this path

        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.resolveStalledDraw(caseId);
        while (_phase(caseId) == Moderation.Phase.VOID_SETTLING) mod.claim(caseId);

        for (uint256 i = 0; i < mods.length; i++) {
            (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(mods[i]);
            assertEq(frozen, 0, "seated-but-never-asked moderators are not penalised");
            (, uint256 reserved, uint256 bonded) = stakeReg.dutyOf(mods[i]);
            assertEq(reserved, 0, "duty capacity returned");
            assertEq(bonded, 0, "and so did the escrow");
        }
        _assertConservation();
    }

    /// M2.6-P0-6b. The same property as the test above, on the path P0-6 did not
    /// reach.
    ///
    /// `resolveStalledDraw` at depth 0 VOIDs, and `_voidStep` checks
    /// `c.drawAbandoned`. At depth > 0 it calls `_failAppealRound` instead — the
    /// prior outcome stands — so the case FINALIZES and drains through
    /// `_settleStep`, which did not check it. Moderators seated in an appeal round
    /// whose draw was abandoned were frozen for missing a commit window that never
    /// opened.
    function test_abandoned_appeal_draw_does_not_penalise_on_the_settle_path() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _appeal(caseId, mods[1]); // depth 1 opens, seeking 11 seats
        assertEq(_depth(caseId), 1, "an appeal round is open");

        // Squeeze pledged capacity so the depth-1 draw comes back SHORT and the
        // round stays in DRAW: `realizeSeats` returns when a batch seats some but
        // not all of the target. Everyone keeps the capacity their depth-0 seats
        // already hold (P0-2 refuses to un-pledge that), and two moderators keep a
        // little spare — so a few seats are drawn and the rest never are.
        for (uint256 i = 0; i < mods.length; i++) {
            (, uint256 reserved,) = stakeReg.dutyOf(mods[i]);
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(i < 2 ? reserved + 2 : reserved);
        }
        _settleEpoch(stakeReg);

        // Crossing the epoch boundary above invalidated the seed armed with the
        // appeal, so the first pokes only re-arm it. Poke until seats land, then
        // stop: the batch that seats some but not all of the target leaves the
        // round in DRAW, which is the state being tested.
        uint256 tries;
        while (mod.__seatCount(caseId, 1) == 0 && _phase(caseId) == Moderation.Phase.DRAW) {
            _rollToSeed(caseId);
            mod.realizeSeats(caseId);
            assertLt(++tries, 8, "the depth-1 draw seats somebody");
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "still short of the target");
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 1);
        assertGt(shCount, 0, "but moderators WERE seated in it");

        // Nobody pokes again; the deadline passes and the appeal round is abandoned.
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.resolveStalledDraw(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.FINALIZED), "prior outcome stands");

        while (_phase(caseId) != Moderation.Phase.SETTLED) mod.claim(caseId);

        // Round 0 was unanimous and coherent with the surviving outcome, so no
        // participant anywhere in this case deserves a freeze.
        for (uint256 i = 0; i < mods.length; i++) {
            (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(mods[i]);
            assertEq(frozen, 0, "seated in an abandoned appeal draw, never asked to commit");
            (, uint256 reserved, uint256 bonded) = stakeReg.dutyOf(mods[i]);
            assertEq(reserved, 0, "duty capacity returned");
            assertEq(bonded, 0, "and so did the escrow");
        }
        _assertConservation();
    }

    /// M2.6-P0-3, the widen path. `_closeReveal` re-arms the seed when it widens,
    /// and that arm must fit inside ONE eligibility epoch exactly as the arm at
    /// `_openRound` does — otherwise a widen re-draw straddles a boundary, the
    /// eligible set moves under a seed whose entropy source is already fixed, and
    /// H-05 is open again on the one path a voter can trigger at will by
    /// withholding a reveal.
    ///
    /// Only `_openRound`'s call was covered. This asserts the property at the widen
    /// arm, driven from a block position late in an epoch so the "does not fit,
    /// defer to the next epoch start" branch is the one taken.
    function test_widen_arms_its_seed_inside_one_epoch() public {
        uint256 epochLen = REG_EPOCH_BLOCKS;
        uint256 slack = mod.__realizeSlack();
        uint256 seedLag = mod.getParams().seedLag;

        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);

        // Land close to a boundary, so the widen's window cannot fit in the epoch
        // it is armed from and must be deferred.
        uint256 pos = vm.getBlockNumber() % epochLen;
        uint256 toBoundary = epochLen - pos;
        if (toBoundary > seedLag + slack) {
            // One block INSIDE the boundary case, so an unfitted arm would leave
            // strictly less than `slack` blocks — the margin assertion below bites
            // as well as the deferral one.
            vm.roll(vm.getBlockNumber() + (toBoundary - (seedLag + slack) + 1));
        }
        assertLe(
            epochLen - (vm.getBlockNumber() % epochLen), seedLag + slack, "positioned where the window cannot fit"
        );

        // Nobody commits: the round widens and re-arms.
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
        mod.closeReveal(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "widened back to DRAW");
        (,,,,, , uint256 widenCount,, uint256 snap,) = mod.roundInfo(caseId, 0);
        assertEq(widenCount, 1, "and it is a widen, not a fresh round");

        uint256 armEpoch = mod.__epochAtArm(caseId, 0);
        assertEq(snap / epochLen, armEpoch, "the snapshot block lies in the epoch it was armed for");
        assertGe(
            (armEpoch + 1) * epochLen - snap, slack, "and the whole realize window fits inside that epoch"
        );
        assertGt(armEpoch, vm.getBlockNumber() / epochLen, "deferred to a later epoch rather than armed unfit");

        // And the deferred window really is realizable: the draw completes there.
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            _rollToSeed(caseId);
            mod.realizeSeats(caseId);
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "widen re-draw seated");
    }

    // --- M2.6-P0-3b: the epoch drain must not roll back its own work ----------

    /// An epoch that staged more weight changes than one drain batch covers used
    /// to halt every draw in the protocol.
    ///
    /// `drawPanel` drained a bounded budget and then reverted `EpochNotSettled` if
    /// that had not finished the epoch — and the revert unwound the drain with it.
    /// Every subsequent draw redid the same first batch and discarded it again. The
    /// only way out was a separate `advanceEpoch` call, whose progress survives
    /// because it does not revert. So the protocol needed an external keeper to
    /// stay live, and nothing said so.
    ///
    /// The trigger is ordinary traffic. `_stageSeated` skips the dedupe flag by
    /// design (the flag's cold SSTORE is not affordable per seat), so panels stage
    /// one entry per seat, and joiners stage one each. This test uses joining alone
    /// — no attacker, no oversized panel.
    ///
    /// NOTE: this test never calls `advanceEpoch`. That is the property.
    function test_epoch_drain_progress_survives_a_failed_draw() public {
        uint256 joiners = 200; // > EPOCH_DRAIN_STEPS, so one poke cannot finish it
        for (uint256 i = 0; i < joiners; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("joiner", i)))));
            bzz.mint(a, 1000 * XBZZ);
            vm.prank(a);
            bzz.approve(address(stakeReg), type(uint256).max);
            vm.prank(a);
            stakeReg.stake(100 * XBZZ);
        }
        // `vm.warp` does not advance the block, so every activation below stages
        // inside ONE epoch — which is exactly the situation being tested.
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        for (uint256 i = 0; i < joiners; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("joiner", i)))));
            stakeReg.activate(a);
        }

        uint256 caseId = _submit(mods[0]);
        vm.roll(vm.getBlockNumber() + REG_EPOCH_BLOCKS); // the staged epoch elapses
        (,,,,,,,, uint256 snapshotBlock,) = mod.roundInfo(caseId, 0);
        if (vm.getBlockNumber() <= snapshotBlock) vm.roll(snapshotBlock + 1);
        assertFalse(stakeReg.epochSettled(), "a backlog is waiting");

        // Poke 1. Pre-fix this reverted `EpochNotSettled` and threw away the batch
        // it had just drained, so the assertions below were unreachable.
        mod.realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "no seats yet");
        assertFalse(stakeReg.epochSettled(), "one batch cannot clear 200 entries");
        uint256 cursor = stakeReg.drainCursor();
        assertGt(cursor, 0, "the batch it drained is PERSISTED, not unwound");

        // Poke 2 resumes from the cursor rather than restarting.
        mod.realizeSeats(caseId);
        assertTrue(stakeReg.epochSettled(), "the backlog cleared across two pokes");

        // And the draw completes off its own pokes. The rolls below only advance
        // to each re-armed snapshot block, as any client would; `advanceEpoch` is
        // never called, which is the property under test.
        uint256 pokes;
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            (,,,,,,,, uint256 snap,) = mod.roundInfo(caseId, 0);
            if (vm.getBlockNumber() <= snap) vm.roll(snap + 1);
            mod.realizeSeats(caseId);
            assertLt(++pokes, 32, "the draw terminates without a keeper");
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "the draw recovered on its own");
        assertGt(stakeReg.totalEligibleWeight(), 0, "and the joiners are drawable");
    }

    /// The same backlog, hit through the registry's own entry point: `drawPanel`
    /// must refuse an unsettled epoch WITHOUT doing rollback-able work first.
    function test_draw_panel_does_no_work_it_would_have_to_unwind() public {
        for (uint256 i = 0; i < 40; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("late", i)))));
            bzz.mint(a, 1000 * XBZZ);
            vm.prank(a);
            bzz.approve(address(stakeReg), type(uint256).max);
            vm.prank(a);
            stakeReg.stake(100 * XBZZ);
        }
        vm.roll(vm.getBlockNumber() + REG_EPOCH_BLOCKS);
        assertFalse(stakeReg.epochSettled());

        uint256 caseId = mod.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        mod.__injectRound(caseId);
        vm.expectRevert(StakeRegistry.EpochNotSettled.selector);
        mod.__drawPanel(caseId, 0, 1, keccak256("seed"));

        // Nothing moved. The old shape would have left this true only because the
        // revert erased 64 items' worth of drain along with the failed draw.
        assertEq(stakeReg.drainCursor(), 0, "no partial drain to lose");
    }

    // H-05, restated for M2.6-P0-3. The old defence was a change counter: any
    // eligibility change re-armed the seed to fresh entropy. It failed both ways —
    // `setDutyUnits(sameValue)` bumped it with no change, so a griefer could
    // re-arm every pending case forever; while `release`, `reward` and
    // `releaseDuty` grew the drawable set and never bumped it at all.
    //
    // Eligibility now changes only at epoch boundaries, and a seed's window is
    // armed to fit inside one epoch. So the attacker's activation cannot touch
    // this draw — and, unlike the old behaviour, the draw is NOT delayed either.
    // Nothing re-arms, because nothing can change.
    function test_H05_activation_after_seed_known_cannot_reshape_the_draw() public {
        uint256 caseId = _submit(mods[0]);

        // Stake matures but is deliberately left unactivated and unpledged, so it
        // carries no draw weight until the attacker chooses to add it.
        address lurker = makeAddr("lurker");
        bzz.mint(lurker, 1000 * XBZZ);
        vm.prank(lurker);
        bzz.approve(address(stakeReg), type(uint256).max);
        vm.prank(lurker);
        stakeReg.stake(500 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);

        uint256 weightBefore = stakeReg.totalEligibleWeight();
        uint256 units = 500 * XBZZ / mod.getParams().riskPerSeat; // before pranking

        // Roll to just past the snapshot block: its blockhash is now public.
        (,,,,,,,, uint256 snapBefore,) = mod.roundInfo(caseId, 0);
        vm.roll(snapBefore + 1);

        // The attacker activates AND pledges NOW — the full adaptive-activation
        // move — trying to reshape the tree against a seed whose entropy it can
        // already see. Under the duty pool it takes both steps to gain draw
        // weight, and both must be powerless.
        stakeReg.activate(lurker);
        vm.prank(lurker);
        stakeReg.setDutyUnits(units);
        assertEq(
            stakeReg.totalEligibleWeight(),
            weightBefore,
            "the attacker's weight cannot enter this epoch's eligible set"
        );

        // The draw proceeds immediately on the entropy it was armed for. No
        // re-arm, no delay, and the attacker is not in the pool.
        mod.realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "draw proceeds, undisturbed");
        (,,,,,,,, uint256 snapAfter,) = mod.roundInfo(caseId, 0);
        assertEq(snapAfter, snapBefore, "the seed was never re-armed");

        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        for (uint256 i = 0; i < shCount; i++) {
            assertTrue(mod.seatHolderAt(caseId, 0, i) != lurker, "attacker never seated");
        }
    }

    /// The griefing half, end to end: a no-op `setDutyUnits` used to bump the
    /// global counter and re-arm EVERY pending case. Repeating it must now leave a
    /// pending draw completely alone.
    function test_H05_noop_repledge_cannot_delay_a_pending_draw() public {
        uint256 caseId = _submit(mods[0]);
        (,,,,,,,, uint256 snapBefore,) = mod.roundInfo(caseId, 0);
        vm.roll(snapBefore + 1);

        uint256 units = mod.getParams().riskPerSeat; // compute before pranking
        units = 3000 * XBZZ / units;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(mods[1]);
            stakeReg.setDutyUnits(units); // same value, repeatedly
        }

        mod.realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "draw was not delayed");
        (,,,,,,,, uint256 snapAfter,) = mod.roundInfo(caseId, 0);
        assertEq(snapAfter, snapBefore, "and the seed was not re-armed");
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
        _settleEpoch(sr); // P0-3: pledged capacity is drawable next epoch

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
        // P0-3: the TREE does not shrink mid-epoch — the struct is the authority.
        (, uint256 r0,) = sr.dutyOf(few[0]);
        (, uint256 r1,) = sr.dutyOf(few[1]);
        assertEq(r0 + r1, 2, "both moderators' capacity is in use");
    }

    function _phaseOfLocal(ModerationHarness m, uint256 caseId) internal view returns (Moderation.Phase p) {
        (,, p,,,,) = m.caseInfo(caseId);
    }
}
