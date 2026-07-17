// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract GovernanceTest is ModerationTestBase {
    // The test contract deploys the harness, so it is `governance`.
    address internal stranger = makeAddr("stranger");
    uint256 internal constant TIMELOCK = 7 days;

    function _proposeMinReveals(uint256 newVal) internal {
        Moderation.Params memory p = mod.getParams();
        p.minReveals = newVal;
        mod.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
    }

    // --- H-11: immutable protocol caps ---------------------------------------

    function test_param_caps_reject_out_of_bounds() public {
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        Moderation.Params memory p = mod.getParams();
        p.maxDepth = 100; // > MAX_RULE_DEPTH
        vm.expectRevert(Moderation.BadParams.selector);
        mod.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.commitTimeout = 60 days; // > MAX_WINDOW
        vm.expectRevert(Moderation.BadParams.selector);
        mod.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.maxWiden = 50; // total reachable draws would blow past MAX_TOTAL_DRAWS
        vm.expectRevert(Moderation.BadParams.selector);
        mod.proposeParameters(p, cts, aws);
    }

    // H-11: a pending exit's cooldown end and min-stake decision are snapshotted at
    // request time, so governance cannot extend or invalidate it retroactively.
    function test_exit_terms_snapshotted_against_governance() public {
        // mods[0] already staked in setUp; request a full exit.
        (uint256 free,,,,,,,,) = mod.moderatorInfo(mods[0]);
        vm.prank(mods[0]);
        mod.requestExit(free);

        // Governance triples the exit cooldown mid-wait.
        Moderation.Params memory p = mod.getParams();
        p.exitCooldown = 21 days;
        mod.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeParameters();

        // The original 7-day cooldown still governs this exit.
        vm.warp(block.timestamp + 1); // now well past the original claimable time
        uint256 before = bzz.balanceOf(mods[0]);
        vm.prank(mods[0]);
        mod.withdraw();
        assertEq(bzz.balanceOf(mods[0]) - before, free, "exit honored on its snapshotted terms");
    }

    // --- access control ------------------------------------------------------

    function test_only_governance_can_propose() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernance.selector);
        mod.proposeParameters(p, cts, aws);
    }

    function test_only_governance_can_propose_guidelines() public {
        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernance.selector);
        mod.proposeGuidelines(keccak256("g"));
    }

    // --- timelock ------------------------------------------------------------

    function test_param_change_requires_timelock() public {
        _proposeMinReveals(5);
        // Cannot execute before the delay.
        vm.expectRevert(Moderation.TimelockNotElapsed.selector);
        mod.executeParameters();

        vm.warp(block.timestamp + TIMELOCK);
        mod.executeParameters();
        assertEq(mod.getParams().minReveals, 5, "param applied after timelock");
    }

    function test_execute_without_proposal_reverts() public {
        vm.expectRevert(Moderation.NoPendingProposal.selector);
        mod.executeParameters();
    }

    function test_cancel_clears_pending() public {
        _proposeMinReveals(9);
        (, bool exists) = mod.pendingParamsEta();
        assertTrue(exists);
        mod.cancelParameters();
        (, bool exists2) = mod.pendingParamsEta();
        assertFalse(exists2);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(Moderation.NoPendingProposal.selector);
        mod.executeParameters();
    }

    // --- parameter validation ------------------------------------------------

    function test_bad_params_rejected() public {
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        Moderation.Params memory p = mod.getParams();
        p.freezeCap = 5e17; // < WAD -> invalid power multiplier
        vm.expectRevert(Moderation.BadParams.selector);
        mod.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.claimBountyFrac = 6e17;
        p.bonusFrac = 6e17; // sum > WAD -> distributable would go negative
        vm.expectRevert(Moderation.BadParams.selector);
        mod.proposeParameters(p, cts, aws);
    }

    /// A changed parameter actually drives behavior: raise the fee floor and a
    /// previously-sufficient fee is now rejected.
    function test_changed_fee_floor_takes_effect() public {
        uint256 oldFee = mod.minFee(1);
        Moderation.Params memory p = mod.getParams();
        p.feeBase = p.feeBase * 10;
        mod.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeParameters();
        assertGt(mod.minFee(1), oldFee, "fee floor rose");
    }

    // --- guidelines append-only history --------------------------------------

    function test_guidelines_history_is_append_only() public {
        bytes32 h1 = keccak256("guidelines v1");
        bytes32 h2 = keccak256("guidelines v2");

        mod.proposeGuidelines(h1);
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 1);
        assertEq(mod.guidelinesHashByVersion(1), h1);

        mod.proposeGuidelines(h2);
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 2);
        assertEq(mod.guidelinesHashByVersion(2), h2);
        // Prior version is untouched (immutable history).
        assertEq(mod.guidelinesHashByVersion(1), h1, "v1 hash never mutated");
    }

    // --- §9.6 case pins guidelines version at submit -------------------------

    function test_case_guidelines_version_is_pinned() public {
        // Set v1.
        mod.proposeGuidelines(keccak256("v1"));
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 1);

        uint256 caseId = _submit(mods[0]);
        assertEq(mod.caseGuidelinesVersion(caseId), 1, "pinned to current version");

        // Update to v2; the live case still points at v1.
        mod.proposeGuidelines(keccak256("v2"));
        vm.warp(block.timestamp + TIMELOCK);
        mod.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 2);
        assertEq(mod.caseGuidelinesVersion(caseId), 1, "pinned version never changes");
    }

    // --- §9.5 withdrawals never pausable, governance live --------------------

    /// There is no pause surface: governance can touch only the numeric params
    /// and guidelines. A moderator's exit still completes with governance active.
    function test_withdraw_works_with_governance_live() public {
        // A pending governance proposal does not gate withdrawals.
        _proposeMinReveals(4);

        address m = mods[0];
        vm.prank(m);
        mod.requestExit(500 * XBZZ);
        vm.warp(block.timestamp + 7 days);
        uint256 balBefore = bzz.balanceOf(m);
        vm.prank(m);
        mod.withdraw();
        assertEq(bzz.balanceOf(m) - balBefore, 500 * XBZZ, "withdraw unaffected by governance");
    }

    // --- governance transfer -------------------------------------------------

    function test_transfer_governance() public {
        address newGov = makeAddr("newGov");
        mod.transferGovernance(newGov);
        assertEq(mod.governance(), newGov);

        // Old governance (this contract) can no longer propose.
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        vm.expectRevert(Moderation.NotGovernance.selector);
        mod.proposeParameters(p, cts, aws);

        // New governance can.
        vm.prank(newGov);
        mod.proposeGuidelines(keccak256("x"));
    }
}
