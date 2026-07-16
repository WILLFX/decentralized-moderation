// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract SettlementTest is ModerationTestBase {
    function _total(address a) internal view returns (uint256) {
        return mod.totalStakeOf(a);
    }

    function _frozenUntil(address a) internal view returns (uint256 fu) {
        (,,,, fu,,,,) = mod.moderatorInfo(a);
    }

    function _track(address a) internal view returns (uint256 t) {
        (,,,,,,,, t) = mod.moderatorInfo(a);
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
        assertGt(_frozenUntil(victim), block.timestamp, "incoherent voter frozen");
        assertEq(mod.eligibleWeightOf(victim), 0, "frozen -> excluded from the tree");

        // A fresh case never draws the frozen victim.
        uint256 case2 = _submit(mods[1]);
        _realizeSeats(case2);
        assertEq(mod.seatsOf(case2, 0, victim), 0, "frozen victim not drawn");

        // After the freeze elapses, thaw restores eligibility.
        vm.warp(_frozenUntil(victim) + 1);
        mod.thaw(victim);
        assertGt(mod.eligibleWeightOf(victim), 0, "thawed -> eligible again");
    }

    // --- failed reveal: brief freeze -----------------------------------------

    function test_failed_reveal_brief_freeze() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        // Everyone commits; one seat-holder never reveals.
        _commitAll(caseId, 0, Moderation.Vote.Approve);
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(block.timestamp + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        address vanisher = mod.seatHolderAt(caseId, 0, 0);
        // reveal everyone except the vanisher.
        for (uint256 i = 1; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            vm.prank(sh);
            mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        }
        vm.warp(block.timestamp + REVEAL_WINDOW);
        mod.closeReveal(caseId);
        _realizeOutcome(caseId);
        _finalize(caseId);
        mod.claim(caseId);

        // Vanisher took a brief (1 day) freeze, not the full incoherent freeze.
        uint256 fu = _frozenUntil(vanisher);
        assertGt(fu, block.timestamp, "vanisher frozen");
        assertLe(fu - block.timestamp, 1 days, "brief freeze only");
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
        uint256 owed = mod.pendingPayout(winner);
        assertGt(owed, floor, "winning appellant gets capital back plus a bonus");
        uint256 balBefore = bzz.balanceOf(winner);
        vm.prank(winner);
        mod.claimPayout();
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
        assertEq(mod.pendingPayout(loser), 0, "losing appellant forfeits the bond");
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
