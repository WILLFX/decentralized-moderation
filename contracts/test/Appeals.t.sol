// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract AppealsTest is ModerationTestBase {
    function _outcome(uint256 caseId, uint256 depth) internal view returns (Moderation.Outcome o) {
        (,,,,,,, o,,) = mod.roundInfo(caseId, depth);
    }

    // --- appeal advances depth, flips direction ------------------------------

    function test_appeal_meets_floor_opens_next_depth() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        assertEq(_depth(caseId), 0);
        assertEq(uint256(_outcome(caseId, 0)), uint256(Moderation.Outcome.Approve));

        (,,,, uint256 potBefore,,) = mod.caseInfo(caseId);
        uint256 floor = mod.appealFloor(caseId);
        assertEq(floor, 2 * potBefore, "floor = 2x pot");

        _appeal(caseId, makeAddr("challenger"));

        assertEq(_depth(caseId), 1, "advanced to depth 1");
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW));
        (uint256 bond, Moderation.Outcome appealFor, bool inPot) = mod.bondInfo(caseId, 0);
        assertEq(bond, floor);
        assertEq(uint256(appealFor), uint256(Moderation.Outcome.Reject), "appeal argues for the flip");
        assertTrue(inPot, "bond moved to pot");
        (,,,, uint256 potAfter,,) = mod.caseInfo(caseId);
        assertEq(potAfter, potBefore + floor, "bond joined the pot");
        _assertConservation();
    }

    // --- aggregation + exact-floor partial fill ------------------------------

    function test_multi_contributor_aggregation_and_partial_fill() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);

        uint256 floor = mod.appealFloor(caseId);
        address a = makeAddr("a");
        address b = makeAddr("b");

        // a fills most of the floor but not all.
        uint256 first = floor - 1000;
        _fund(a, first);
        vm.prank(a);
        mod.contributeAppealBond(caseId, first);
        assertEq(_depth(caseId), 0, "not yet at floor");
        (uint256 bond,,) = mod.bondInfo(caseId, 0);
        assertEq(bond, first);

        // b offers far more than the remaining 1000; only 1000 is accepted.
        _fund(b, floor);
        uint256 bBalBefore = bzz.balanceOf(b);
        vm.prank(b);
        uint256 accepted = mod.contributeAppealBond(caseId, floor);
        assertEq(accepted, 1000, "partial fill = exactly the remaining room");
        assertEq(bzz.balanceOf(b), bBalBefore - 1000, "only the accepted amount pulled");
        assertEq(mod.bondContribOf(caseId, 0, b), 1000);
        assertEq(_depth(caseId), 1, "floor met -> advanced");
        _assertConservation();
    }

    // --- unmet floor: reclaim after finalize ---------------------------------

    function test_unmet_floor_reclaim_after_finalize() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);

        uint256 floor = mod.appealFloor(caseId);
        address a = makeAddr("a");
        uint256 part = floor / 3;
        _fund(a, part);
        vm.prank(a);
        mod.contributeAppealBond(caseId, part);

        // Cannot reclaim while the case is live.
        vm.prank(a);
        vm.expectRevert(Moderation.CaseNotTerminal.selector);
        mod.reclaimBond(caseId, 0);

        // Window closes without meeting the floor -> finalize with the outcome.
        (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
        vm.warp(deadline);
        mod.finalize(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.FINALIZED));

        uint256 balBefore = bzz.balanceOf(a);
        vm.prank(a);
        mod.reclaimBond(caseId, 0);
        assertEq(bzz.balanceOf(a) - balBefore, part, "pending bond refunded in full");
        assertEq(mod.totalPendingBond(), 0);

        // Double reclaim reverts.
        vm.prank(a);
        vm.expectRevert(Moderation.NothingToReclaim.selector);
        mod.reclaimBond(caseId, 0);
        _assertConservation();
    }

    /// An in-pot (floored) bond cannot be reclaimed — it is settled in claim().
    function test_floored_bond_cannot_be_reclaimed() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        address challenger = makeAddr("challenger");
        _appeal(caseId, challenger); // floor met -> in pot, depth 1

        // Even after the case later finalizes, an in-pot bond is locked here.
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Reject);
        (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
        vm.warp(deadline);
        mod.finalize(caseId);

        vm.prank(challenger);
        vm.expectRevert(Moderation.BondLocked.selector);
        mod.reclaimBond(caseId, 0);
    }

    // --- self-appeal is allowed (and costly) ---------------------------------

    function test_self_appeal_allowed() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        // The submitter (or any winner) may bond an appeal of the round just won.
        _appeal(caseId, mods[0]);
        assertEq(_depth(caseId), 1, "self-appeal advances like any other");
        (, , bool inPot) = mod.bondInfo(caseId, 0);
        assertTrue(inPot, "self-appellant's bond is genuinely at risk in the pot");
    }

    // --- appeal round with no participation: prior outcome stands ------------

    function test_unparticipated_appeal_round_falls_back_to_prior_outcome() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _appeal(caseId, makeAddr("challenger")); // depth 1 DRAW
        _realizeSeats(caseId);

        // Nobody participates in the appeal round; drive widen cycles.
        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.FINALIZED) {
            require(guard++ < 12, "did not finalize");
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
        // The appeal failed for lack of a panel; the depth-0 Approve stands, and
        // the case is FINALIZED (not VOID).
        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Approve), "prior outcome stands");
    }

    // --- item 2b close-out: a depth the case never reached ---------------------

    /// **`reclaimBond` had no depth bound**, so an out-of-range depth resolved
    /// through `adjRoundAt`'s zero default to ROUND 0 and the call succeeded against
    /// depth 0's bookkeeping. It was safe only because a caller naming a bogus depth
    /// usually has nothing at round 0 either — safe on today's call sites, unsafe as
    /// a property. Same shape as `settleDuty`'s clamp, `unbackedSeats`,
    /// `penalizeNoShow` and the amnesty gate.
    ///
    /// The discriminating case is a contributor that DOES hold an unmet-floor bond at
    /// depth 0: pre-fix it could reclaim that bond by naming a depth the case never
    /// reached, which is a successful call that should not exist.
    function test_reclaim_bond_rejects_a_depth_the_case_never_reached() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);

        // An appeal contribution that never meets its floor, so it stays reclaimable.
        address ap = makeAddr("underfunded");
        uint256 small = mod.appealFloor(caseId) / 4;
        bzz.mint(ap, small);
        vm.prank(ap);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(ap);
        mod.contributeAppealBond(caseId, small);
        _finalize(caseId);
        assertEq(mod.bondContribOf(caseId, 0, ap), small, "the contribution is live at depth 0");

        // Naming a depth the case never reached must not reach depth 0's bond.
        vm.prank(ap);
        vm.expectRevert(Moderation.DepthNotAdjudicated.selector);
        mod.reclaimBond(caseId, 5);

        // And the real depth still works, so the bound did not break the path.
        uint256 before = bzz.balanceOf(ap);
        vm.prank(ap);
        mod.reclaimBond(caseId, 0);
        assertEq(bzz.balanceOf(ap) - before, small, "the genuine reclaim is unaffected");
    }

    /// **`claimAppealPayout` bounded the depth but not whether it ADJUDICATED.** A
    /// depth reached and then failed for want of a panel (`_failAppealRound`) never
    /// runs `_armOutcome`, so it has no adjudicating round — and the zero default
    /// resolved it to round 0, paying out the PREVIOUS depth's entitlement under the
    /// wrong index. It survived only because the second call finds `contrib == 0`.
    function test_claim_appeal_payout_rejects_a_depth_that_never_adjudicated() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        address challenger = makeAddr("challenger");
        _appeal(caseId, challenger); // depth 1 opens, funded from depth 0's round
        _realizeSeats(caseId);

        // Nobody participates at depth 1: the appeal fails and the prior outcome
        // stands, so depth 1 never adjudicates.
        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.FINALIZED) {
            require(guard++ < 20, "did not finalize");
            Moderation.Phase ph = _phase(caseId);
            if (ph == Moderation.Phase.DRAW) {
                _rollToSeed(caseId);
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
        mod.claim(caseId);

        (, bool adjudicated) = mod.adjudicatingRoundAt(caseId, 1);
        assertFalse(adjudicated, "depth 1 was reached but never adjudicated");
        assertGt(mod.appealPayoutOwed(caseId, challenger), 0, "and the challenger IS owed, at depth 0");

        // Claiming at the un-adjudicated depth must not pay depth 0's entitlement.
        vm.prank(challenger);
        vm.expectRevert(Moderation.DepthNotAdjudicated.selector);
        mod.claimAppealPayout(caseId, 1);

        // The genuine depth still pays.
        uint256 before = bzz.balanceOf(challenger);
        vm.prank(challenger);
        mod.claimAppealPayout(caseId, 0);
        assertGt(bzz.balanceOf(challenger) - before, 0, "the real depth is unaffected");
    }

    // --- F3: floor underflow guarded across a mid-window governance change ---

    // H-11: an open case's appeal floor is pinned to the ruleset live at submit,
    // so a mid-window governance change to bondMultiplier does not move it (and the
    // F3 floor<=bond underflow it used to cause can no longer arise).
    function test_appeal_floor_pinned_across_governance_change() public {
        // Queue lowering bondMultiplier 2 -> 1 (timelock 7 days).
        Moderation.Params memory p = mod.getParams();
        p.bondMultiplier = 1;
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        governor.proposeParameters(p, cts, aws);
        uint256 eta = vm.getBlockTimestamp() + 7 days;

        // Open the case ~3.5 days before eta so the 4-day appeal window is still
        // open when the timelock fires.
        vm.warp(vm.getBlockTimestamp() + 3 days + 12 hours);
        uint256 caseId = _submit(mods[0]); // pins ruleset v0 (bondMultiplier 2)
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);

        (,,,, uint256 pot,,) = mod.caseInfo(caseId);
        assertEq(mod.appealFloor(caseId), 2 * pot, "pinned 2x floor");

        uint256 partialBond = pot + pot / 2; // 1.5x pot: below the pinned 2x floor
        address c = makeAddr("c");
        _fund(c, partialBond);
        vm.prank(c);
        mod.contributeAppealBond(caseId, partialBond);

        // Governance executes mid-window: the LIVE multiplier drops to 1.
        vm.warp(eta);
        governor.executeParameters();
        assertEq(mod.getParams().bondMultiplier, 1, "live param changed");

        // The open case is unaffected: its floor is still the pinned 2x, so the
        // 1.5x bond has NOT met the floor and more can still be contributed — no
        // underflow, no premature AppealAlreadyFull.
        assertEq(mod.appealFloor(caseId), 2 * pot, "open case keeps its pinned 2x floor");
        _fund(c, pot);
        vm.prank(c);
        mod.contributeAppealBond(caseId, pot / 2); // completes to exactly 2x -> floors
        (,,, uint256 depth,,,) = mod.caseInfo(caseId);
        assertEq(depth, 1, "appeal floored at the pinned 2x and opened depth 1");
    }

    // --- appeals close at MAX_DEPTH ------------------------------------------

    function test_appeals_closed_at_max_depth() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _appeal(caseId, makeAddr("c0"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 1, Moderation.Vote.Reject);
        _appeal(caseId, makeAddr("c1"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 2, Moderation.Vote.Approve);
        _appeal(caseId, makeAddr("c2"));

        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 3, Moderation.Vote.Reject);
        assertEq(_depth(caseId), 3, "reached MAX_DEPTH");

        // No further appeal is accepted at MAX_DEPTH.
        vm.prank(makeAddr("c3"));
        vm.expectRevert(Moderation.AppealsClosed.selector);
        mod.contributeAppealBond(caseId, 1);
    }
}
