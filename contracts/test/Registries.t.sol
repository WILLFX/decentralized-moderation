// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// P0-b: the storage/logic split. These tests assert the properties the split
/// exists for — moderators never re-stake across a logic upgrade, approvals
/// survive it, and the repoint switch (the new trust root) is constrained so it
/// cannot be used against the people whose money is in the registry.
contract RegistriesTest is Test {
    uint256 internal constant XBZZ = 1e16;
    uint256 internal constant TIMELOCK = 7 days;
    uint256 internal constant MIN_STAKE = 10 * XBZZ;
    uint256 internal constant ACTIVATION = 7 days;
    uint256 internal constant COOLDOWN = 7 days;
    uint256 internal constant RISK_PER_SEAT = 10 * XBZZ;

    MockBZZ internal bzz;
    StakeRegistry internal stakeReg;
    IndexRegistry internal indexReg;

    address internal oldLogic = makeAddr("oldLogic");
    address internal newLogic = makeAddr("newLogic");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant TK = keccak256("marine biology");

    function setUp() public {
        bzz = new MockBZZ();
        stakeReg = new StakeRegistry(IERC20(address(bzz)), TIMELOCK, MIN_STAKE, ACTIVATION, COOLDOWN, RISK_PER_SEAT);
        indexReg = new IndexRegistry(TIMELOCK);
        _authorize(oldLogic);
    }

    function _authorize(address logic) internal {
        stakeReg.proposeLogic(logic);
        indexReg.proposeLogic(logic);
        vm.warp(block.timestamp + TIMELOCK);
        stakeReg.executeLogic();
        indexReg.executeLogic();
    }

    function _stake(address who, uint256 amount) internal {
        bzz.mint(who, amount);
        vm.prank(who);
        bzz.approve(address(stakeReg), type(uint256).max);
        vm.prank(who);
        stakeReg.stake(amount);
    }

    /// Stake, activate, and pledge full duty capacity (H-07: stake alone is not
    /// drawable).
    function _stakeActivatePledge(address who, uint256 amount) internal {
        _stake(who, amount);
        vm.warp(block.timestamp + ACTIVATION);
        stakeReg.activate(who);
        uint256 units = amount / RISK_PER_SEAT;
        vm.prank(who);
        stakeReg.setDutyUnits(units);
    }

    // --- the point of the split ---------------------------------------------

    /// The headline property: swapping the business logic must not require any
    /// moderator to withdraw and re-stake, and must not touch their balances.
    function test_moderators_do_not_restake_across_a_logic_upgrade() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        uint256 weightBefore = stakeReg.eligibleWeightOf(alice);
        uint256 totalBefore = stakeReg.totalStakeOf(alice);

        // Governance migrates the game to a new logic contract.
        _authorize(newLogic);
        stakeReg.revokeLogic(oldLogic);

        // Alice never lifted a finger; her stake and draw weight are untouched.
        assertEq(stakeReg.totalStakeOf(alice), totalBefore, "stake survives the upgrade");
        assertEq(stakeReg.eligibleWeightOf(alice), weightBefore, "draw weight survives the upgrade");

        // And the new logic can immediately use her stake.
        vm.prank(newLogic);
        stakeReg.lock(alice, 10 * XBZZ);
        (, , uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(committed, 10 * XBZZ, "new logic operates on the existing stake");
    }

    /// The third contract's reason to exist: approvals are not thrown away when
    /// the game is redeployed.
    function test_approvals_survive_a_logic_upgrade() public {
        vm.prank(oldLogic);
        indexReg.writeEntry(TK, 1, keccak256("c"), keccak256("m"), true, true);
        assertEq(indexReg.entryCount(TK), 1);

        _authorize(newLogic);
        indexReg.revokeLogic(oldLogic);

        assertEq(indexReg.entryCount(TK), 1, "index survives the upgrade");
        IndexRegistry.Entry memory e = indexReg.entryAt(TK, 0);
        assertEq(e.contentHash, keccak256("c"), "entry intact");

        // The new logic can remove it as the outcome of a removal case.
        vm.prank(newLogic);
        indexReg.deleteEntry(TK, 1);
        assertEq(indexReg.entryCount(TK), 0);
    }

    // --- the repoint switch is the new trust root, so it is constrained ------

    function test_repoint_is_timelocked() public {
        stakeReg.proposeLogic(newLogic);
        vm.expectRevert(StakeRegistry.TimelockNotElapsed.selector);
        stakeReg.executeLogic();

        vm.warp(block.timestamp + TIMELOCK);
        stakeReg.executeLogic();
        assertTrue(stakeReg.isLogic(newLogic));
    }

    /// Trust model #2: a moderator who rejects an announced migration can always
    /// leave during the timelock. Exit never consults the logic contract, so no
    /// logic (malicious or not) and no governance action can trap stake.
    function test_moderator_can_always_exit_during_a_migration_timelock() public {
        _stakeActivatePledge(alice, 100 * XBZZ);

        // A migration is announced.
        stakeReg.proposeLogic(newLogic);

        // Alice objects and leaves; the exit path is hers alone.
        vm.prank(alice);
        stakeReg.requestExit(100 * XBZZ);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = bzz.balanceOf(alice);
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(bzz.balanceOf(alice) - before, 100 * XBZZ, "exited before the migration landed");
        assertEq(stakeReg.totalStakeOf(alice), 0);
    }

    /// Trust model #3: the outgoing logic keeps its privileges during handover so
    /// it can settle in-flight cases; both are authorized at once.
    function test_handover_window_lets_old_logic_settle_in_flight_cases() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.prank(oldLogic);
        stakeReg.lock(alice, 10 * XBZZ); // an in-flight case

        _authorize(newLogic); // both authorized now
        assertTrue(stakeReg.isLogic(oldLogic), "old logic still authorized during handover");
        assertTrue(stakeReg.isLogic(newLogic));

        // The old logic settles its open case.
        vm.prank(oldLogic);
        stakeReg.release(alice, 10 * XBZZ);
        (, , uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(committed, 0, "in-flight case settled under the old logic");

        // Only once drained is it revoked.
        stakeReg.revokeLogic(oldLogic);
        vm.prank(oldLogic);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, 10 * XBZZ);
    }

    /// Governance may NAME the logic contract and nothing else: it can never move,
    /// lock, freeze or credit stake itself.
    function test_governance_cannot_touch_funds() public {
        _stakeActivatePledge(alice, 100 * XBZZ);

        // The test contract is governance; it is not a logic contract.
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, 10 * XBZZ);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.freeze(alice, 1, block.timestamp + 1 days);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.reward(alice, 1);
        vm.expectRevert(IndexRegistry.NotLogic.selector);
        indexReg.writeEntry(TK, 1, bytes32(0), bytes32(0), true, true);
    }

    function test_unauthorized_caller_cannot_use_the_privileged_api() public {
        _stake(alice, 100 * XBZZ);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, 1);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotGovernance.selector);
        stakeReg.proposeLogic(bob);
    }

    // --- registry-local invariants -------------------------------------------

    function test_conservation_across_the_privileged_api() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 50 * XBZZ);

        vm.startPrank(oldLogic);
        stakeReg.lock(alice, 30 * XBZZ);
        stakeReg.freeze(alice, 10 * XBZZ, block.timestamp + 1 days);
        stakeReg.release(alice, 20 * XBZZ);
        stakeReg.lock(bob, 10 * XBZZ);
        vm.stopPrank();

        // Every token held is somebody's stake, in exactly one bucket.
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "alice's principal never moved");
        assertEq(stakeReg.totalStakeOf(bob), 50 * XBZZ, "bob's principal never moved");
    }

    /// A reward is external money: the logic contract must fund the registry, and
    /// crediting it never reduces anyone else's balance (no internal transfer).
    function test_reward_is_external_money_not_an_internal_transfer() public {
        _stake(alice, 100 * XBZZ);
        _stake(bob, 50 * XBZZ);
        uint256 bobBefore = stakeReg.totalStakeOf(bob);

        bzz.mint(address(stakeReg), 5 * XBZZ); // fee money arriving with the reward
        vm.prank(oldLogic);
        stakeReg.reward(alice, 5 * XBZZ);

        assertEq(stakeReg.totalStakeOf(alice), 105 * XBZZ, "reward credited");
        assertEq(stakeReg.totalStakeOf(bob), bobBefore, "nobody else's stake moved");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    function test_frozen_stake_is_excluded_from_draws_until_thaw() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, 10 * XBZZ);
        stakeReg.freeze(alice, 10 * XBZZ, block.timestamp + 3 days);
        vm.stopPrank();

        assertEq(stakeReg.eligibleWeightOf(alice), 0, "frozen -> fully excluded from draws");
        vm.warp(block.timestamp + 3 days + 1);
        stakeReg.thaw(alice);
        assertGt(stakeReg.eligibleWeightOf(alice), 0, "eligible again after thaw");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "freezing never destroys principal");
    }

    // --- duty pool (H-07) ----------------------------------------------------

    function test_unpledged_stake_is_never_drawn() public {
        _stake(alice, 100 * XBZZ);
        vm.warp(block.timestamp + ACTIVATION);
        stakeReg.activate(alice); // activated but NOT pledged
        assertEq(stakeReg.totalEligibleWeight(), 0, "passive stake is not in the draw pool");

        vm.prank(oldLogic);
        (address[] memory seats,) = stakeReg.drawPanel(5, keccak256("s"), 0);
        assertEq(seats.length, 0, "nobody can be drafted into duty");
    }

    /// A panel never seats more units than a moderator pledged, even when it is the
    /// only staker — the draw excludes exhausted capacity instead of over-seating.
    function test_draw_never_exceeds_pledged_capacity() public {
        _stake(alice, 1000 * XBZZ);
        vm.warp(block.timestamp + ACTIVATION);
        stakeReg.activate(alice);
        vm.prank(alice);
        stakeReg.setDutyUnits(3); // only 3 seats pledged

        vm.prank(oldLogic);
        (address[] memory seats,) = stakeReg.drawPanel(10, keccak256("s"), 0);
        assertEq(seats.length, 3, "seated exactly the pledged capacity");
        (, uint256 reserved) = stakeReg.dutyOf(alice);
        assertEq(reserved, 3, "one unit reserved per seat");
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "capacity exhausted -> out of the pool");

        // Releasing capacity puts the moderator back in the pool.
        vm.prank(oldLogic);
        stakeReg.releaseDuty(alice, 3);
        (, reserved) = stakeReg.dutyOf(alice);
        assertEq(reserved, 0);
        assertGt(stakeReg.eligibleWeightOf(alice), 0, "eligible again once the case ends");
    }

    /// The no-show penalty (H-07/H-10): a pledged moderator that is drawn and does
    /// not serve pays a freeze of its OWN stake — never a transfer to anyone.
    function test_no_show_penalty_freezes_own_stake_only() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        uint256 bobBefore = stakeReg.totalStakeOf(bob);

        vm.prank(oldLogic);
        stakeReg.penalizeNoShow(alice, RISK_PER_SEAT, block.timestamp + 1 days);

        (, , , uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, RISK_PER_SEAT, "one seat's worth frozen");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "principal not destroyed, only locked");
        assertEq(stakeReg.totalStakeOf(bob), bobBefore, "nobody gained from the penalty");
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "frozen -> excluded from draws");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Stake that never opted in cannot be penalized — it was never drawable, so
    /// submission spam cannot grief passive stakers.
    function test_unpledged_stake_cannot_be_penalized() public {
        _stake(alice, 100 * XBZZ);
        vm.warp(block.timestamp + ACTIVATION);
        stakeReg.activate(alice);

        vm.prank(oldLogic);
        stakeReg.penalizeNoShow(alice, RISK_PER_SEAT, block.timestamp + 1 days);
        (, , , uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 0, "passive staker is untouchable");
    }

    // --- index registry ------------------------------------------------------

    function test_supersafe_requires_uncontested_full_quorum_and_age() public {
        vm.startPrank(oldLogic);
        indexReg.writeEntry(TK, 1, keccak256("a"), bytes32(0), true, true); // qualifies
        indexReg.writeEntry(TK, 2, keccak256("b"), bytes32(0), false, true); // contested
        indexReg.writeEntry(TK, 3, keccak256("c"), bytes32(0), true, false); // under-quorum
        vm.stopPrank();

        assertEq(indexReg.supersafeEntries(TK, 96 hours, 0, 10).length, 0, "too young");
        vm.warp(block.timestamp + 96 hours);
        IndexRegistry.Entry[] memory ss = indexReg.supersafeEntries(TK, 96 hours, 0, 10);
        assertEq(ss.length, 1, "only the uncontested full-quorum entry");
        assertEq(ss[0].caseId, 1);
    }

    function test_reads_are_paginated_and_never_gated() public {
        vm.startPrank(oldLogic);
        for (uint256 i = 0; i < 25; i++) {
            indexReg.writeEntry(TK, i, keccak256(abi.encode(i)), bytes32(0), true, true);
        }
        vm.stopPrank();

        // Anyone reads, including after the writing logic is revoked.
        stakeReg.revokeLogic(oldLogic);
        indexReg.revokeLogic(oldLogic);
        vm.prank(bob);
        IndexRegistry.Entry[] memory page = indexReg.entries(TK, 10, 10);
        assertEq(page.length, 10, "paginated slice");
        assertEq(page[0].caseId, 10);
        assertEq(indexReg.entries(TK, 20, 10).length, 5, "final short page");
    }

    function test_index_deletion_is_o1_and_relocates_positions() public {
        vm.startPrank(oldLogic);
        for (uint256 i = 0; i < 5; i++) {
            indexReg.writeEntry(TK, i, keccak256(abi.encode(i)), bytes32(0), true, true);
        }
        indexReg.deleteEntry(TK, 0); // front entry: swap-pop with the last
        vm.stopPrank();

        assertEq(indexReg.entryCount(TK), 4);
        assertFalse(indexReg.isIndexed(TK, 0), "deleted");
        assertTrue(indexReg.isIndexed(TK, 4), "moved entry still addressable");
        // The relocated entry can still be deleted by id (position map is correct).
        vm.prank(oldLogic);
        indexReg.deleteEntry(TK, 4);
        assertEq(indexReg.entryCount(TK), 3);
        assertFalse(indexReg.isIndexed(TK, 4));
    }

    function test_two_step_governance_transfer() public {
        stakeReg.proposeGovernance(bob);
        assertEq(stakeReg.governance(), address(this), "not transferred until accepted");
        vm.prank(bob);
        stakeReg.acceptGovernance();
        assertEq(stakeReg.governance(), bob);

        // The old governance is powerless afterwards.
        vm.expectRevert(StakeRegistry.NotGovernance.selector);
        stakeReg.proposeLogic(newLogic);
    }

    function test_zero_address_rejected() public {
        vm.expectRevert(StakeRegistry.ZeroAddress.selector);
        stakeReg.proposeLogic(address(0));
        vm.expectRevert(StakeRegistry.ZeroAddress.selector);
        stakeReg.proposeGovernance(address(0));
    }
}
