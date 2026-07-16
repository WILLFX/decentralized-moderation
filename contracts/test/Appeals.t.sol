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
        // The appeal failed for lack of a panel; the depth-0 Approve stands, and
        // the case is FINALIZED (not VOID).
        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Approve), "prior outcome stands");
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
