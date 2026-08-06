// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";

/// M2.6-P0-6 / P0-6b / P0-6c: a draw that cannot complete must still end, and the
/// disposal of whoever was seated in it must depend on whether a commit window ever
/// opened — not on which terminal path the case happens to take.
///
/// Split out of `CaseLifecycle.t.sol`, which outgrew the `via_ir` pipeline ("Tag too
/// large for reserved space"). The family is self-contained, so this is a file move
/// rather than a change in coverage.
contract StalledDrawTest is ModerationTestBase {
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

    /// Un-pledge the capacity of every moderator NOT currently holding a seat, so
    /// a subsequent draw finds nothing. P0-2 refuses to let a seated moderator
    /// un-pledge below what a live panel holds, which is why the seated ones are
    /// left alone — they are the participants these tests are about.
    function _drainUnseatedCapacity() internal {
        for (uint256 i = 0; i < mods.length; i++) {
            (, uint256 reserved,) = stakeReg.dutyOf(mods[i]);
            if (reserved == 0) {
                vm.prank(mods[i]);
                stakeReg.setDutyUnits(0);
            }
        }
        _settleEpoch(stakeReg);
    }

    /// Moderators seated before a draw was abandoned are released, not penalised —
    /// but ONLY when the round never widened, because a widen is proof that a
    /// commit window opened and closed (M2.6-P0-6c).
    ///
    /// The never-widened shape: capacity is squeezed so the first batch comes back
    /// under target and the round stays in DRAW, then the deadline passes. COMMIT
    /// never opened, so nobody could have shown up.
    ///
    /// This test previously drove the round through COMMIT and a widen and asserted
    /// the same amnesty. That was asserting the H-10 evasion below as correct.
    function test_abandoned_draw_before_any_commit_window_releases_without_penalty() public {
        // Two moderators keep a little spare capacity; the rest keep only what
        // nothing holds. The depth-0 target is 5, so the draw comes back short.
        for (uint256 i = 0; i < mods.length; i++) {
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(i < 2 ? 2 : 0);
        }
        _settleEpoch(stakeReg);

        uint256 caseId = _submit(mods[0]);
        uint256 tries;
        while (mod.__seatCount(caseId, 0) == 0 && _phase(caseId) == Moderation.Phase.DRAW) {
            _rollToSeed(caseId);
            mod.realizeSeats(caseId);
            assertLt(++tries, 8, "somebody is seated");
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "short of target, still drawing");
        assertGt(mod.__seatCount(caseId, 0), 0, "but moderators WERE seated");
        (,,,,,, uint256 widenCount,,,) = mod.roundInfo(caseId, 0);
        assertEq(widenCount, 0, "and no commit window ever opened");

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

    /// M2.6-P0-6c: the blanket abandoned-draw amnesty was H-10 evasion, and cheap.
    ///
    /// The attack, using nothing but the protocol as designed: moderators pledging
    /// exactly the depth-0 target get seated, refuse to commit, the round widens,
    /// and the re-draw stalls on the very capacity they are still holding. Under
    /// `c.drawAbandoned` alone, `resolveStalledDraw` then released every one of them
    /// — while `test_void_with_no_commits_penalizes_no_shows` freezes the identical
    /// refusal when the draw happens to complete. So the penalty depended on
    /// whether the attacker left capacity for the widen, which the attacker chooses.
    ///
    /// `widenCount > 0` is proof that a commit window opened and closed. The
    /// holders who sat through it are no-shows regardless of what became of the
    /// later draw.
    function test_refusing_to_commit_then_stalling_the_widen_is_still_penalised() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.COMMIT), "a window IS open");
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        assertGt(shCount, 0);

        // Every seat-holder simply refuses to commit. Everyone else un-pledges, so
        // the widen re-draw will find nothing and the case stalls in DRAW.
        _drainUnseatedCapacity();

        // M2.6-item-2b: zero COMMITMENT widens at close-of-commit; there is no
        // reveal window to pass through first.
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId); // zero commitment -> widen -> back to DRAW
        if (_phase(caseId) != Moderation.Phase.DRAW) return; // widen exhausted: not this path
        (,,,,,, uint256 widenCount,,,) = mod.roundInfo(caseId, 0);
        assertGt(widenCount, 0, "a window opened and closed before the stall");

        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.resolveStalledDraw(caseId);
        while (_phase(caseId) == Moderation.Phase.VOID_SETTLING) mod.claim(caseId);

        uint256 penalised;
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        for (uint256 i = 0; i < mods.length; i++) {
            if (mod.__seats(caseId, 0, mods[i]) == 0) continue;
            (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(mods[i]);
            assertEq(frozen, riskPerSeat, "a seat-holder that refused its window pays one seat");
            penalised++;
        }
        assertGt(penalised, 0, "the refusal was actually exercised");
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
}
