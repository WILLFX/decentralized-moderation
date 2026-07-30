// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {RulesetGovernor} from "../src/RulesetGovernor.sol";
import {ProtocolLimits as L} from "../src/lib/ProtocolLimits.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

contract GovernanceTest is ModerationTestBase {
    // The test contract deploys the harness, so it is `governance`.
    address internal stranger = makeAddr("stranger");
    uint256 internal constant TIMELOCK = 7 days;

    function _proposeMinReveals(uint256 newVal) internal {
        Moderation.Params memory p = mod.getParams();
        p.minReveals = newVal;
        governor.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
    }

    // --- H-11: immutable protocol caps ---------------------------------------

    function test_param_caps_reject_out_of_bounds() public {
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        Moderation.Params memory p = mod.getParams();
        p.maxDepth = 100; // > MAX_RULE_DEPTH
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.commitTimeout = 60 days; // > MAX_WINDOW
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.maxWiden = 50; // total reachable draws would blow past MAX_TOTAL_DRAWS
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);
    }

    // H-11 + M2.5 port: a pending exit's terms are snapshotted at request time,
    // and after the split they are doubly out of reach — the cooldown that
    // governs a withdrawal belongs to the registry, and this contract's
    // governance has no path to it at all. (Before the split this test changed
    // Moderation's own exitCooldown; that field is gone, precisely so governance
    // cannot appear to move a number the exit path never reads.)
    function test_exit_terms_are_beyond_governance_reach() public {
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(mods[0]);
        vm.prank(mods[0]);
        stakeReg.requestExit(free);
        (,,,,,,, uint256 claimableAt,) = stakeReg.moderatorInfo(mods[0]);
        assertGt(claimableAt, 0, "cooldown end snapshotted at request");

        // Governance executes a full parameter change on the logic contract.
        Moderation.Params memory p = mod.getParams();
        p.revealWindow = 3 days;
        governor.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();

        (,,,,,,, uint256 claimableAfter,) = stakeReg.moderatorInfo(mods[0]);
        assertEq(claimableAfter, claimableAt, "a pending exit's terms never move once requested");
        assertEq(stakeReg.exitCooldown(), REG_COOLDOWN, "the registry's cooldown is not governable from here");

        uint256 before = bzz.balanceOf(mods[0]);
        vm.prank(mods[0]);
        stakeReg.withdraw();
        assertEq(bzz.balanceOf(mods[0]) - before, free, "exit honored on its snapshotted terms");
    }

    // --- seat collateral is bounded by the registry's duty unit (D-13) -------

    /// `riskPerSeat` lives in both contracts on purpose: in the registry it is
    /// what one pledged DUTY UNIT is worth, here it is what a case LOCKS per
    /// seat (pinned per case, H-11). The harmful direction is a case locking
    /// MORE than the unit reserved for it — a panel seated on collateral that
    /// cannot cover it. Governance must not be able to create that state.
    function test_ruleset_locking_more_than_a_duty_unit_is_rejected() public {
        uint256 unit = stakeReg.riskPerSeat();
        // Hoist every external call out of the argument list: one in there would
        // consume the expectRevert and propose as an ordinary call (work order
        // trap #1 — the same hazard as vm.prank).
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        Moderation.Params memory p = mod.getParams();
        p.riskPerSeat = unit + 1;
        vm.expectRevert(RulesetGovernor.RiskPerSeatExceedsDutyUnit.selector);
        governor.proposeParameters(p, cts, aws);

        // Exactly one unit is the boundary and is allowed.
        p.riskPerSeat = unit;
        governor.proposeParameters(p, cts, aws);

        // So is locking LESS: seats are simply over-collateralized relative to
        // eligibility, which costs the moderator nothing it did not pledge.
        p.riskPerSeat = unit / 2;
        governor.proposeParameters(p, cts, aws);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();
        assertEq(mod.getParams().riskPerSeat, unit / 2, "under-locking ruleset accepted");
    }

    /// The registry's duty unit is immutable, so a ruleset validated against it
    /// cannot be undermined later by lowering it.
    function test_registry_duty_unit_is_immutable() public view {
        assertEq(stakeReg.riskPerSeat(), REG_RISK_PER_SEAT, "duty unit fixed at construction");
        // No setter exists: the only way to change it is a registry migration,
        // which moderators can exit ahead of (trust model #2).
    }

    // --- access control ------------------------------------------------------

    function test_only_governance_can_propose() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        governor.proposeParameters(p, cts, aws);
    }

    function test_only_governance_can_propose_guidelines() public {
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        governor.proposeGuidelines(keccak256("g"));
    }

    // --- timelock ------------------------------------------------------------

    function test_param_change_requires_timelock() public {
        _proposeMinReveals(5);
        // Cannot execute before the delay.
        vm.expectRevert(RulesetGovernor.TimelockNotElapsed.selector);
        governor.executeParameters();

        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();
        assertEq(mod.getParams().minReveals, 5, "param applied after timelock");
    }

    function test_execute_without_proposal_reverts() public {
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        governor.executeParameters();
    }

    function test_cancel_clears_pending() public {
        _proposeMinReveals(9);
        (, bool exists) = governor.pendingParamsEta();
        assertTrue(exists);
        governor.cancelParameters();
        (, bool exists2) = governor.pendingParamsEta();
        assertFalse(exists2);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        governor.executeParameters();
    }

    // --- parameter validation ------------------------------------------------

    function test_bad_params_rejected() public {
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        Moderation.Params memory p = mod.getParams();
        p.freezeCap = 5e17; // < WAD -> invalid power multiplier
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);

        p = mod.getParams();
        p.claimBountyFrac = 6e17;
        p.bonusFrac = 6e17; // sum > WAD -> distributable would go negative
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);
    }

    /// A changed parameter actually drives behavior: raise the fee floor and a
    /// previously-sufficient fee is now rejected.
    function test_changed_fee_floor_takes_effect() public {
        uint256 oldFee = mod.minFee(1);
        Moderation.Params memory p = mod.getParams();
        p.feeBase = p.feeBase * 10;
        governor.proposeParameters(p, mod.getCommitTargets(), mod.getAppealWindows());
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();
        assertGt(mod.minFee(1), oldFee, "fee floor rose");
    }

    // --- guidelines append-only history --------------------------------------

    function test_guidelines_history_is_append_only() public {
        bytes32 h1 = keccak256("guidelines v1");
        bytes32 h2 = keccak256("guidelines v2");

        governor.proposeGuidelines(h1);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 1);
        assertEq(mod.guidelinesHashByVersion(1), h1);

        governor.proposeGuidelines(h2);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 2);
        assertEq(mod.guidelinesHashByVersion(2), h2);
        // Prior version is untouched (immutable history).
        assertEq(mod.guidelinesHashByVersion(1), h1, "v1 hash never mutated");
    }

    // --- §9.6 case pins guidelines version at submit -------------------------

    function test_case_guidelines_version_is_pinned() public {
        // Set v1.
        governor.proposeGuidelines(keccak256("v1"));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeGuidelines();
        assertEq(mod.guidelinesVersion(), 1);

        uint256 caseId = _submit(mods[0]);
        assertEq(mod.caseGuidelinesVersion(caseId), 1, "pinned to current version");

        // Update to v2; the live case still points at v1.
        governor.proposeGuidelines(keccak256("v2"));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeGuidelines();
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
        stakeReg.requestExit(500 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = bzz.balanceOf(m);
        vm.prank(m);
        stakeReg.withdraw();
        assertEq(bzz.balanceOf(m) - balBefore, 500 * XBZZ, "withdraw unaffected by governance");
    }

    // --- governance transfer -------------------------------------------------

    function test_transfer_governance() public {
        address newGov = makeAddr("newGov");
        governor.proposeGovernance(newGov);
        assertEq(governor.governance(), address(this), "not transferred until accepted");
        vm.prank(newGov);
        governor.acceptGovernance();
        assertEq(governor.governance(), newGov);

        // Old governance (this contract) can no longer propose.
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        governor.proposeParameters(p, cts, aws);

        // New governance can.
        vm.prank(newGov);
        governor.proposeGuidelines(keccak256("x"));
    }

    /// The governor holds the protocol's whole ruleset authority, and
    /// `Moderation.governor` is immutable — so a governor handed to an address
    /// nobody controls cannot be replaced, and ruleset and guidelines governance is
    /// bricked permanently. The one-step `transferGovernance` it was split out of
    /// `Moderation` with accepted any address, `address(0)` included, and took
    /// effect immediately. Both registries have had propose/accept since the
    /// L-series; this brings the governor in line.
    function test_governance_transfer_is_two_step_and_rejects_zero() public {
        vm.expectRevert(RulesetGovernor.ZeroAddress.selector);
        governor.proposeGovernance(address(0));
        assertEq(governor.governance(), address(this), "still ours");

        // A nomination alone changes nothing, and only the nominee can claim it.
        address newGov = makeAddr("newGov2");
        governor.proposeGovernance(newGov);
        assertEq(governor.pendingGovernance(), newGov);
        assertEq(governor.governance(), address(this), "a mistyped nominee is still recoverable");

        vm.prank(makeAddr("impostor"));
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        governor.acceptGovernance();

        // Recoverable right up until it is accepted.
        governor.cancelGovernanceTransfer();
        assertEq(governor.pendingGovernance(), address(0));
        vm.prank(newGov);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        governor.acceptGovernance();
        assertEq(governor.governance(), address(this), "authority never left");
    }

    /// M2.6: `MAX_PANEL` is a solvency-of-liveness bound, not a style choice.
    ///
    /// It was 512, so governance could enact a ruleset whose `realizeSeats` cannot
    /// fit in a block. H-11 pins a ruleset per case at submit, so every case opened
    /// under it would be permanently unfinalizable with no path forward — no
    /// attacker needed, just a plausible parameter choice. The cap is now derived
    /// from a measured per-seat cost (~123k gas) against the 8M single-transaction
    /// ceiling; `GasBounds.test_max_panel_draw_fits_the_ceiling` asserts a panel at
    /// the cap actually fits.
    function test_commit_target_above_the_drawable_cap_is_rejected() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory aws = mod.getAppealWindows();

        uint256[] memory tooBig = new uint256[](1);
        tooBig[0] = L.MAX_PANEL + 1;
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, tooBig, aws);

        // The old cap is now firmly out of reach.
        tooBig[0] = 512;
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, tooBig, aws);

        // A target AT the cap is accepted — the bound is exact, not conservative
        // by accident.
        uint256[] memory atCap = new uint256[](1);
        atCap[0] = L.MAX_PANEL;
        Moderation.Params memory q = mod.getParams();
        q.maxDepth = 0;
        q.minReveals = 1;
        governor.proposeParameters(q, atCap, aws);
    }

    /// M2.6-P0-7: with every panel-scaled loop batched, the binding constraint on
    /// panel size is the AGGREGATE reachability check, not a single transaction.
    /// The two bounds must compose: a target at the cap is fine on its own, and
    /// still rejected when repeated across enough depths to blow MAX_TOTAL_DRAWS.
    function test_aggregate_draw_bound_is_what_now_limits_large_panels() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory aws = mod.getAppealWindows();

        // A single depth at the cap: accepted.
        uint256[] memory one = new uint256[](1);
        one[0] = L.MAX_PANEL;
        Moderation.Params memory q = p;
        q.maxDepth = 0;
        q.minReveals = 1;
        governor.proposeParameters(q, one, aws);

        // The cap repeated across depths: the aggregate check catches it.
        uint256[] memory many = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) many[i] = L.MAX_PANEL;
        Moderation.Params memory big = p;
        big.maxDepth = 7;
        big.maxWiden = 8;
        big.minReveals = 1;
        uint256[] memory aws8 = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) aws8[i] = 3 days;
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(big, many, aws8);
    }

    /// M2.6-P1-3: validation READ the target array; the runtime CLAMPS it.
    ///
    /// `_validateParams` looped `i < commitTargets.length` and counted only entries
    /// at or below `maxDepth`, while `Moderation._commitTarget` returns the LAST
    /// entry for every depth past the array's end. A ruleset supplying fewer targets
    /// than `maxDepth + 1` was therefore bounded over the entries it gave and then
    /// run over more depths than that, each of the uncounted ones silently drawing
    /// the last entry's worth. `MAX_TOTAL_DRAWS` bounded something the runtime does
    /// not do.
    ///
    /// No attacker and no exotic choice: one target at the cap, both retry budgets at
    /// theirs. H-11 pins a ruleset per case, so every case opened under this one was
    /// bounded by a number that did not apply to it.
    function test_short_target_array_cannot_smuggle_draws_past_the_aggregate_bound() public {
        uint256[] memory one = new uint256[](1);
        one[0] = L.MAX_PANEL;
        uint256[] memory aws = new uint256[](1);
        aws[0] = 3 days;

        Moderation.Params memory p = mod.getParams();
        p.maxDepth = L.MAX_RULE_DEPTH; // nine depths reachable
        p.maxWiden = L.MAX_RULE_WIDEN; // nine attempts at each
        p.minReveals = 1;

        // Both numbers spelled out, because the defect is the gap between them.
        uint256 asValidated = (1 + p.maxWiden) * one[0];
        uint256 asRun = (1 + p.maxWiden) * (1 + p.maxDepth) * one[0];
        assertEq(asValidated, 1152, "what the array-indexed loop computed");
        assertEq(asRun, 10368, "what nine clamped depths actually draw");
        assertLe(asValidated, L.MAX_TOTAL_DRAWS, "so the old validator accepted it");
        assertGt(asRun, L.MAX_TOTAL_DRAWS, "and the runtime blew the bound");

        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, one, aws);
    }

    /// The composability guarantee behind the P1-3 rewrite: acceptance is a function
    /// of the RUNTIME-clamped aggregate and of one per-depth attempt budget — not of
    /// how many entries the array happens to hold.
    ///
    /// Targets ascend, so the clamped tail is the array's LARGEST entry and an
    /// under-count is maximally wrong. A uniform array could not discriminate: every
    /// depth would read the same number whether the loop clamped or not.
    function testFuzz_aggregate_bound_tracks_the_runtime_clamped_sum(
        uint8 nTargets,
        uint8 target,
        uint8 maxDepth,
        uint8 maxWiden
    ) public {
        uint256 n = 1 + (uint256(nTargets) % L.MAX_ARRAY_LEN);
        uint256 d = uint256(maxDepth) % (L.MAX_RULE_DEPTH + 1);
        uint256 w = uint256(maxWiden) % (L.MAX_RULE_WIDEN + 1);

        uint256[] memory cts = new uint256[](n);
        uint256[] memory aws = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            cts[i] = 1 + ((uint256(target) + i) % L.MAX_PANEL);
            aws[i] = 3 days;
        }

        Moderation.Params memory p = mod.getParams();
        p.maxDepth = d;
        p.maxWiden = w;
        p.minReveals = 1;

        // Recomputed the way the RUNTIME reaches it: every depth 0..maxDepth, each
        // using the target `_commitTarget` will really clamp to.
        uint256 reachable;
        for (uint256 i; i <= d; ++i) {
            reachable += (1 + w) * cts[i < n ? i : n - 1];
        }

        if (reachable > L.MAX_TOTAL_DRAWS) vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);
    }

    // --- M2.6-P0-8: the freeze arithmetic is bounded at both ends -------------

    /// `freezeCap` had only a LOWER bound (`>= WAD`). `FreezeMath` computes
    /// `(freezeCap - WAD) * oneMinusExp` and then `freezeBase * power`, and
    /// `_settleInit` calls it BEFORE the case reaches any recoverable state — so an
    /// accepted-but-large cap made every settlement attempt revert, permanently,
    /// with H-11 pinning that ruleset per case. `MAX_FREEZE` bounded `freezeBase`
    /// and `failedRevealFreeze` but never the amplified product of the two.
    function test_unbounded_freeze_cap_is_rejected() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        // The overflow case: a cap so large the multiplication cannot be done.
        p.freezeCap = type(uint256).max;
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);

        // Just past the multiplier bound.
        p = mod.getParams();
        p.freezeCap = L.MAX_FREEZE_MULTIPLIER + 1;
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);

        // And the composite bound: each factor legal on its own, the PRODUCT not.
        // This is the one the old validator could not see at all.
        p = mod.getParams();
        p.freezeCap = L.MAX_FREEZE_MULTIPLIER;   // legal
        p.freezeBase = L.MAX_FREEZE;             // legal
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        governor.proposeParameters(p, cts, aws);
    }

    /// The maximum ACCEPTED freeze configuration must still settle — the bound has
    /// to be tight enough to prevent the brick and loose enough to be usable.
    function test_maximum_accepted_freeze_configuration_settles() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        p.freezeCap = L.MAX_FREEZE_MULTIPLIER;
        p.freezeBase = L.MAX_FREEZE / (L.MAX_FREEZE_MULTIPLIER / 1e18); // product exactly at the bound
        governor.proposeParameters(p, cts, aws);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();

        // A full case under that ruleset settles rather than reverting forever.
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED), "settles at the freeze bound");
        _assertConservation();
    }

    /// The ruleset the protocol actually ships must survive its own validator.
    function test_default_ruleset_still_validates_under_the_cap() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();
        assertEq(cts[cts.length - 1], 47, "deepest shipped target");
        assertLe(cts[cts.length - 1], L.MAX_PANEL, "and it is within the cap");
        governor.proposeParameters(p, cts, aws); // must not revert
    }

    // --- M2.6 split: the Moderation <-> RulesetGovernor boundary -------------

    /// Applying a ruleset is the governor's alone. Nobody else can seal a version,
    /// including the multisig that authors proposals — it must go through the
    /// timelock in the governor.
    function test_only_the_governor_can_apply() public {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyRuleset(p, cts, aws); // this contract is `governance`, not the governor

        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyRuleset(p, cts, aws);

        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyGuidelines(keccak256("g"));
    }

    /// The boundary re-check. Full validation lives in the governor, so a governor
    /// bug could hand `Moderation` a ruleset that never passed it. One bound is
    /// re-enforced on arrival — the one whose violation is a solvency failure
    /// rather than a liveness one: a case must never lock more per seat than a
    /// pledged duty unit is worth, or panels get seated on collateral that cannot
    /// cover them. Every other validation failure can brick a case; only this one
    /// can seat an uncollateralized panel.
    function test_apply_rechecks_the_solvency_bound_even_from_the_governor() public {
        Moderation.Params memory p = mod.getParams();
        p.riskPerSeat = stakeReg.riskPerSeat() + 1;
        uint256[] memory cts = mod.getCommitTargets();
        uint256[] memory aws = mod.getAppealWindows();

        // Straight from the governor address, bypassing the governor's own
        // validation entirely — this is the "governor is buggy" case.
        vm.prank(address(governor));
        vm.expectRevert(Moderation.RiskPerSeatExceedsDutyUnit.selector);
        mod.applyRuleset(p, cts, aws);

        // And the same ruleset is refused at proposal time, before the timelock.
        vm.expectRevert(RulesetGovernor.RiskPerSeatExceedsDutyUnit.selector);
        governor.proposeParameters(p, cts, aws);
    }

    /// A ruleset that IS valid still applies normally through the governor, and
    /// seals a new version rather than mutating the old one (H-11).
    function test_governor_apply_seals_a_new_version() public {
        uint256 v0 = mod.currentRulesVersion();
        _proposeMinReveals(4);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        governor.executeParameters();

        assertEq(mod.currentRulesVersion(), v0 + 1, "a new immutable version");
        assertEq(mod.getParams().minReveals, 4, "and it is live");
    }

    /// The governor binds to one game contract, once. `Moderation.governor` is
    /// immutable on the other side, so a rebind could only produce a governor
    /// that governs nothing.
    function test_bind_is_one_way() public {
        vm.expectRevert(RulesetGovernor.AlreadyBound.selector);
        governor.bindModeration(mod);

        RulesetGovernor fresh = new RulesetGovernor(address(this), TIMELOCK);
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        fresh.bindModeration(mod);
    }

    /// An unbound governor cannot execute anything — it has nothing to apply to.
    function test_unbound_governor_cannot_execute() public {
        RulesetGovernor fresh = new RulesetGovernor(address(this), TIMELOCK);
        fresh.proposeGuidelines(keccak256("x"));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        vm.expectRevert(RulesetGovernor.NotBound.selector);
        fresh.executeGuidelines();
    }
}
