// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract SettlementTest is ModerationTestBase {
    function _total(address a) internal view returns (uint256) {
        return stakeReg.totalStakeOf(a);
    }

    function _frozenUntil(address a) internal view returns (uint256 fu) {
        (,,,, fu,,,,) = stakeReg.moderatorInfo(a);
    }

    function _track(address a) internal view returns (uint256 t) {
        (,,,,,,,, t) = stakeReg.moderatorInfo(a);
    }

    // --- happy path: undisputed approve --------------------------------------

    function test_undisputed_claim_pays_coherent_and_conserves() public {
        // record every moderator's principal before.
        uint256[] memory before = new uint256[](mods.length);
        for (uint256 i = 0; i < mods.length; i++) {
            before[i] = _total(mods[i]);
        }

        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        address claimant = makeAddr("claimant");
        uint256 claimantBalBefore = bzz.balanceOf(claimant);

        vm.prank(claimant);
        mod.claim(caseId);

        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED));
        // Claimant received the bounty (dust-inclusive, so > 0 given a non-zero pot).
        assertGt(bzz.balanceOf(claimant) - claimantBalBefore, 0, "claimant paid the bounty");

        // No moderator lost principal; committed stake returned to free, plus
        // pot rewards make total >= before for participants.
        for (uint256 i = 0; i < mods.length; i++) {
            assertGe(_total(mods[i]), before[i], "no principal lost; rewards only add");
        }
        _assertConservation();
    }

    function test_undisputed_coherent_track_increments() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        // capture a seat-holder that will vote coherently.
        address sh = mod.seatHolderAt(caseId, 0, 0);
        uint256 trackBefore = _track(sh);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _finalize(caseId);
        mod.claim(caseId);
        // Undisputed + coherent -> track = track*decay + 1 (WAD). From 0 -> ~1.
        assertApproxEqAbs(_track(sh), 1e18, 1, "coherent undisputed track -> +1");
        assertGt(_track(sh), trackBefore);
    }

    // --- disputed flip-flop to MAX_DEPTH: the insolvency reproducer -----------

    /// Forces alternating deterministic outcomes up the full appeal ladder, so
    /// the case carries winning appeals, losing appeals, coherent and incoherent
    /// voters at once. Funds conservation (invariant 11) must be exact.
    function test_flipflop_to_max_depth_conserves_exactly() public {
        uint256 caseId = _submit(mods[0]);

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve); // outcome Approve
        _appeal(caseId, makeAddr("ap0"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Reject); // outcome Reject
        _appeal(caseId, makeAddr("ap1"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 2, Moderation.Vote.Approve); // outcome Approve
        _appeal(caseId, makeAddr("ap2"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 3, Moderation.Vote.Reject); // outcome Reject (final)
        _finalize(caseId);

        uint256 balBefore = bzz.balanceOf(address(mod));
        mod.claim(caseId);

        // The whole pot left as internal credits + a single bounty transfer; the
        // contract holds no unaccounted value.
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED));
        assertLe(bzz.balanceOf(address(mod)), balBefore, "no value minted");
        _assertConservation();
    }

    // --- freeze excludes an incoherent voter from later draws ----------------

    function test_incoherent_voter_frozen_and_excluded_then_thaws() public {
        // Disputed case whose final outcome flips the depth-0 panel to incoherent.
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        address victim = mod.seatHolderAt(caseId, 0, 0); // votes Approve at depth 0
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _appeal(caseId, makeAddr("ap"));
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Reject); // final Reject
        _finalize(caseId);
        mod.claim(caseId);

        // The depth-0 Approve voter is incoherent vs the final Reject -> frozen.
        assertGt(_frozenUntil(victim), vm.getBlockTimestamp(), "incoherent voter frozen");
        assertEq(stakeReg.eligibleWeightOf(victim), 0, "frozen -> excluded from the tree");

        // A fresh case never draws the frozen victim.
        uint256 case2 = _submit(mods[1]);
        _realizeSeats(case2);
        assertEq(mod.seatsOf(case2, 0, victim), 0, "frozen victim not drawn");

        // After the freeze elapses, thaw restores eligibility.
        vm.warp(_frozenUntil(victim) + 1);
        stakeReg.thaw(victim);
        assertGt(stakeReg.eligibleWeightOf(victim), 0, "thawed -> eligible again");
    }

    /// Stake a dominant moderator, so a single holder reliably lands several of the
    /// depth-0 seats. Weight buys REPEATS under a with-replacement draw, and a
    /// multi-seat holder is the only fixture in which a per-seat penalty differs
    /// from a per-holder one.
    function _spawnWhale(uint256 amount) internal returns (address whale) {
        whale = makeAddr("whale");
        bzz.mint(whale, amount);
        vm.prank(whale);
        bzz.approve(address(stakeReg), type(uint256).max);
        vm.prank(whale);
        stakeReg.stake(amount);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(whale);
        // Computed before pranking: an external call in the arg list eats the prank.
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(whale);
        uint256 units = free / riskPerSeat;
        vm.prank(whale);
        stakeReg.setDutyUnits(units);
        // M2.6-P0-3: new weight is drawable only at the next eligibility epoch.
        vm.roll(vm.getBlockNumber() + REG_EPOCH_BLOCKS);
        stakeReg.advanceEpoch(type(uint256).max);
    }

    // --- item 2b(3a): only an adjudicating round feeds a payoff ---------------

    /// **Guard.** This passes on today's code and is expected to: a round that did
    /// not adjudicate has zero reveals, so it contributes zero to `winnersSeats`
    /// whether or not the gate exists, and no seat in it can reach the reward
    /// branch. It is here to catch a FUTURE change, and specifically one shape of
    /// change — item 2b's stall rounds, where a depth holds several rounds and only
    /// one adjudicates.
    ///
    /// What it guards is not an overpayment. If the `adjudicated` gate is applied to
    /// `_settleInit`'s `winnersSeats` but not to `_disposeSeat`'s numerator, a seat
    /// in an excluded round pays against a denominator that no longer counts it,
    /// `s.distributed` passes `s.distributable`, and `_settleFinish`'s
    /// `s.bounty + (s.distributable - s.distributed)` UNDERFLOWS. `claim` reverts,
    /// permanently, with every seat-holder's stake locked — item 4's failure class.
    ///
    /// So the assertions are shaped for a revert, not for a bad number. Settlement
    /// is driven in single-seat batches and the boundary is checked BETWEEN them,
    /// because `_settleFinish` runs in the same call as the last `_disposeBatch` and
    /// an overshoot is not observable after a settlement that completed. Completion
    /// itself is asserted, and deliberately not wrapped in `expectRevert`: a
    /// conservation check placed after a successful settle cannot reach this at all,
    /// because under the defect there is no successful settle.
    function test_only_adjudicating_rounds_feed_a_payoff_and_settlement_never_overshoots() public {
        // A case whose appeal round never adjudicates: depth 0 decides, depth 1
        // draws no participation at all and falls back through `_failAppealRound`.
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _appeal(caseId, makeAddr("challenger"));
        _realizeSeats(caseId);

        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.FINALIZED) {
            require(guard++ < 12, "did not finalize");
            Moderation.Phase ph = _phase(caseId);
            if (ph == Moderation.Phase.DRAW) {
                vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
                mod.realizeSeats(caseId);
            } else if (ph == Moderation.Phase.COMMIT) {
                vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (ph == Moderation.Phase.REVEAL) {
                vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                revert("unexpected phase");
            }
        }

        assertEq(mod.__roundCount(caseId), 2, "fixture must carry two rounds");
        assertTrue(mod.__adjudicated(caseId, 0), "depth 0 drew the outcome");
        assertFalse(mod.__adjudicated(caseId, 1), "the failed appeal round never did");

        // Settle one seat at a time, checking the boundary between batches.
        uint256 steps;
        while (_phase(caseId) != Moderation.Phase.SETTLED) {
            require(steps++ < 200, "settlement did not complete");
            mod.claim(caseId, 1);
            (, uint256 distributable, uint256 distributed) = mod.__settleMoney(caseId);
            assertLe(distributed, distributable, "settlement overshot its own pool");
        }

        // Completion is the assertion the underflow would break, so it is asserted
        // rather than assumed by whatever runs after it.
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED), "settlement completed");

        // And the gate selected: `winnersSeats` is depth 0's winning side alone.
        (uint256 winnersSeats,,) = mod.__settleMoney(caseId);
        (,,,, uint256 approveSeats,,,,,) = mod.roundInfo(caseId, 0);
        assertEq(winnersSeats, approveSeats, "only the adjudicating round's seats count");
        assertGt(winnersSeats, 0, "and the fixture actually had winners");

        _assertConservation();
    }

    // --- item 8: withholding is priced exactly like being wrong ---------------

    /// M2.6-item-8. This test previously asserted `<= 1 days` — it froze the defect
    /// as intended behaviour, in the same way `test_draw_refuses_an_unsettled_epoch`
    /// asserted the epoch-discard as correct. Withholding a reveal took
    /// `failedRevealFreeze` while revealing incoherently took `freezeBase × power`,
    /// so at the shipped ruleset a moderator who suspected it was on the losing side
    /// could pay 1 day instead of 7 to 28 by going quiet. The reward term cancels —
    /// both rungs forfeit it — so that duration gap WAS the entire price difference.
    ///
    /// Asserted as PARITY rather than as a number: the two rungs now reach the same
    /// line in `_disposeSeat`, and a number would go stale the moment the ruleset
    /// changes while the parity is the property.
    function test_withholding_is_priced_like_revealing_incoherently() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        assertGe(shCount, 3, "fixture needs a withholder and both vote sides");

        // Everyone commits. Seat 1 commits Reject, the rest Approve, so that
        // whichever way the seat-weighted outcome draw falls there is a revealer on
        // the losing side to compare the withholder against.
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            Moderation.Vote v = i == 1 ? Moderation.Vote.Reject : Moderation.Vote.Approve;
            // Computed into a local FIRST: an external call in the argument list
            // consumes the prank (the trap this suite has hit three times).
            bytes32 h = mod.computeCommit(caseId, 0, sh, v, SALT);
            vm.prank(sh);
            mod.commitVote(caseId, h);
        }
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }

        // Seat 0 committed and then vanishes. Everyone else reveals what they bound.
        address vanisher = mod.seatHolderAt(caseId, 0, 0);
        for (uint256 i = 1; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            vm.prank(sh);
            mod.revealVote(caseId, i == 1 ? Moderation.Vote.Reject : Moderation.Vote.Approve, SALT);
        }
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
        _realizeOutcome(caseId);
        _finalize(caseId);
        mod.claim(caseId);

        // Pick the incoherent revealer AFTER reading the drawn outcome, so the
        // comparison does not depend on which way the seat-weighted draw fell.
        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        address wrong = fo == Moderation.Outcome.Approve
            ? mod.seatHolderAt(caseId, 0, 1) // revealed Reject
            : mod.seatHolderAt(caseId, 0, 2); // revealed Approve
        assertTrue(wrong != vanisher, "comparison must be a different moderator");

        uint256 fuVanisher = _frozenUntil(vanisher);
        uint256 fuWrong = _frozenUntil(wrong);
        assertGt(fuVanisher, vm.getBlockTimestamp(), "vanisher frozen");
        assertEq(fuVanisher, fuWrong, "withholding costs exactly what being wrong costs");
        // And it is emphatically no longer the old brief rung. This is the assertion
        // that fails against pre-item-8 code (86,400 vs 604,800 seconds).
        assertGt(fuVanisher - vm.getBlockTimestamp(), 1 days, "not the deleted brief freeze");
        _assertConservation();
    }

    /// The rung that also avoids committing must not be the cheapest of all.
    ///
    /// `_settleDuty` charged ONE `riskPerSeat` regardless of seats held, frozen for
    /// the same brief duration, so a moderator drawn onto k seats paid 1/k per seat
    /// for ignoring all k — the gradient ran the wrong way for exactly the actor
    /// this rung exists to price. Both halves are fixed here, and both are needed:
    /// pricing the withhold rung alone would only move a rational actor onto this one.
    function test_no_show_is_not_the_cheapest_rung() public {
        // Draws are stake-weighted WITH REPLACEMENT, and the base fixture's eight
        // equal moderators land one seat each — under which the old rule and the new
        // one agree exactly. A dominant staker is what makes the seat-count
        // dimension observable at all.
        //
        // The depth-0 panel is widened first, because a dominant staker on a
        // five-seat panel can hold enough of it that the remaining seats cannot
        // reach `minReveals`, and the round widens instead of reaching an outcome.
        // Twelve seats leaves slack in both directions. Defaults are READ FROM THE
        // LIVE RULESET and one field changed — never a re-declared copy, which would
        // silently drift from ruleset 0.
        Moderation.Params memory gp = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        cts[0] = 12;
        governor.proposeParameters(gp, cts, aws);
        vm.warp(vm.getBlockTimestamp() + GOV_TIMELOCK);
        governor.executeParameters();

        address whale = _spawnWhale(24_000 * XBZZ);

        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);

        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        assertGe(shCount, 2, "fixture needs a no-show and a participant");

        // The no-show must hold MORE THAN ONE seat or this fixture cannot see the
        // half of the fix that matters: the old rule charged one `riskPerSeat`
        // whatever the seat count, so at one seat old and new agree exactly. Draws
        // are stake-weighted WITH REPLACEMENT, so pick the holder that landed the
        // most seats rather than assuming seat 0 did.
        uint256 noShowIdx;
        uint256 noShowSeats;
        for (uint256 i = 0; i < shCount; i++) {
            uint256 n = mod.__seats(caseId, 0, mod.seatHolderAt(caseId, 0, i));
            if (n > noShowSeats) {
                noShowSeats = n;
                noShowIdx = i;
            }
        }
        address noShow = mod.seatHolderAt(caseId, 0, noShowIdx);
        assertEq(noShow, whale, "the dominant staker should be the multi-seat holder");
        assertGt(noShowSeats, 1, "fixture must give the no-show multiple seats to discriminate");

        for (uint256 i = 0; i < shCount; i++) {
            if (i == noShowIdx) continue;
            address sh = mod.seatHolderAt(caseId, 0, i);
            bytes32 h = mod.computeCommit(caseId, 0, sh, Moderation.Vote.Approve, SALT);
            vm.prank(sh);
            mod.commitVote(caseId, h);
        }
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        for (uint256 i = 0; i < shCount; i++) {
            if (i == noShowIdx) continue;
            address sh = mod.seatHolderAt(caseId, 0, i);
            vm.prank(sh);
            mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        }
        // Every committer revealed, so `revealVote` already closed the round.
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
        _realizeOutcome(caseId);
        _finalize(caseId);

        (,,, uint256 frozenBefore,,,,,) = stakeReg.moderatorInfo(noShow);
        mod.claim(caseId);
        (,,, uint256 frozenAfter,,,,,) = stakeReg.moderatorInfo(noShow);

        // Seats-scaled: the whole escrow these seats posted, not one seat's worth.
        // P0-2 makes the bound structural — escrow IS seats x riskPerSeat — so the
        // registry's own clamp sits exactly at this value and cannot overshoot.
        assertEq(
            frozenAfter - frozenBefore,
            noShowSeats * mod.getParams().riskPerSeat,
            "no-show forfeits every seat's escrow, not one seat's"
        );
        // And for the same duration the participating rungs take, so never
        // committing is not cheaper than committing and going quiet.
        assertGt(_frozenUntil(noShow) - vm.getBlockTimestamp(), 1 days, "not the deleted brief freeze");
        _assertConservation();
    }

    // --- winning appellant refund + bonus; losing forfeits -------------------

    function test_winning_appellant_refunded_with_bonus() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve); // Approve
        address winner = makeAddr("winner");
        uint256 floor = mod.appealFloor(caseId);
        _appeal(caseId, winner); // argues for Reject
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Reject); // final Reject == appealFor
        _finalize(caseId);
        mod.claim(caseId);

        // Winner's appeal matched the final outcome: refund (capital) + bonus.
        // The bond is stored on the round it appealed against (depth 0).
        uint256 owed = mod.appealPayoutOwed(caseId, winner);
        assertGt(owed, floor, "winning appellant gets capital back plus a bonus");
        uint256 balBefore = bzz.balanceOf(winner);
        vm.prank(winner);
        mod.claimAppealPayout(caseId, 0);
        assertEq(bzz.balanceOf(winner) - balBefore, owed);
        _assertConservation();
    }

    function test_losing_appellant_forfeits_bond() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        address loser = makeAddr("loser");
        _appeal(caseId, loser); // argues for Reject
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Approve); // final Approve != appealFor
        _finalize(caseId);
        mod.claim(caseId);

        // Losing appeal: nothing owed back; the bond was distributed as rewards.
        assertEq(mod.appealPayoutOwed(caseId, loser), 0, "losing appellant forfeits the bond");
        vm.prank(loser);
        vm.expectRevert(Moderation.NothingToReclaim.selector);
        mod.claimAppealPayout(caseId, 0);
        _assertConservation();
    }

    // H-10: an appeal round that draws NO quorum after max widen is a protocol
    // failure, not a loss on the merits. The prior outcome stands, but the honest
    // appeal bond's capital is REFUNDED (no bonus), never confiscated to the prior
    // winners. Built via injection: depth-1 appeal round empty (zero reveals),
    // round-0 bond marked refund-only as the real finalize-to-prior path does.
    function test_zero_quorum_appeal_refunds_bond_not_confiscated() public {
        uint256 bondAmt = 100 * XBZZ;
        uint256 fee = 1000 * XBZZ;
        uint256 pot = fee + bondAmt;

        uint256 caseId = mod.__injectFinalized(0, Moderation.Outcome.Reject, pot);
        bzz.mint(address(mod), pot);
        mod.__setDepth(caseId, 1);

        // round 0: original Reject outcome, one coherent Reject voter, plus a bond
        // that appealed FOR Approve (funded the depth-1 round).
        mod.__injectRound(caseId);
        address rejVoter = makeAddr("rejVoter");
        mod.__injectSeat(caseId, 0, rejVoter, 1, 10 * XBZZ, 2); // Reject == final
        bzz.mint(address(stakeReg), 10 * XBZZ); // committed backing lives in the registry
        mod.__injectBond(caseId, 0, Moderation.Outcome.Approve, true);
        address challenger = makeAddr("honestChallenger");
        mod.__injectBondContrib(caseId, 0, challenger, bondAmt);
        mod.__setBondRefundOnly(caseId, 0); // the depth-1 appeal it funded got no quorum

        // round 1: the appeal round, zero reveals.
        mod.__injectRound(caseId);

        mod.claim(caseId);

        // Capital back, no bonus.
        assertEq(mod.appealPayoutOwed(caseId, challenger), bondAmt, "refund is capital only, no bonus");
        uint256 before = bzz.balanceOf(challenger);
        vm.prank(challenger);
        mod.claimAppealPayout(caseId, 0);
        assertEq(bzz.balanceOf(challenger) - before, bondAmt, "honest appellant recovers its bond");
        _assertConservation();
    }

    // --- idempotence ---------------------------------------------------------

    function test_claim_is_idempotent() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        vm.expectRevert(Moderation.CaseNotFinalized.selector);
        mod.claim(caseId);
    }
}
