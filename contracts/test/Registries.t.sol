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
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
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
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
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
        indexReg.writeEntry(TK, 1, keccak256("c"), keccak256("m"), true, true, 0, 0, bytes32(0));
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

        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
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
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
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
        stakeReg.freeze(alice, 1, vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.reward(alice, 1);
        vm.expectRevert(IndexRegistry.NotLogic.selector);
        indexReg.writeEntry(TK, 1, bytes32(0), bytes32(0), true, true, 0, 0, bytes32(0));
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
        stakeReg.freeze(alice, 10 * XBZZ, vm.getBlockTimestamp() + 1 days);
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

        // M2.6-P0-4: the logic contract must HOLD the reward and let the registry
        // pull it. Previously this test minted straight into the registry, which
        // masked the fact that reward() never checked its own funding.
        bzz.mint(oldLogic, 5 * XBZZ);
        vm.prank(oldLogic);
        bzz.approve(address(stakeReg), 5 * XBZZ);
        vm.prank(oldLogic);
        stakeReg.reward(alice, 5 * XBZZ);

        assertEq(stakeReg.totalStakeOf(alice), 105 * XBZZ, "reward credited");
        assertEq(stakeReg.totalStakeOf(bob), bobBefore, "nobody else's stake moved");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// M2.6-P0-4. The registry must not credit stake it was not funded for.
    /// Before this fix, an authorized logic — superseded, buggy, or malicious —
    /// could mint withdrawable claims from nothing and drain real stakers'
    /// principal via requestExit/withdraw. The funding rule lived only in a
    /// comment; now the registry pulls and verifies it.
    function test_unfunded_reward_reverts() public {
        _stake(alice, 100 * XBZZ);
        uint256 liabilitiesBefore = stakeReg.stakeBuckets();

        // oldLogic is authorized but holds nothing and approved nothing.
        vm.prank(oldLogic);
        vm.expectRevert();
        stakeReg.reward(alice, 5 * XBZZ);

        assertEq(stakeReg.stakeBuckets(), liabilitiesBefore, "no liability was created");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation intact");
    }

    /// The full attack the audit described, end to end: an authorized logic mints
    /// itself a balance and walks it out through the ordinary exit path, taking
    /// other stakers' tokens. It must be impossible at step one.
    function test_authorized_logic_cannot_mint_and_drain() public {
        _stake(alice, 100 * XBZZ); // a real staker's principal sits in the registry
        address attacker = makeAddr("attacker");
        uint256 registryFunds = bzz.balanceOf(address(stakeReg));

        // Step 1: the malicious logic tries to conjure a balance.
        vm.prank(oldLogic);
        vm.expectRevert();
        stakeReg.reward(attacker, registryFunds);

        // Nothing was created, so there is nothing to exit with.
        assertEq(stakeReg.totalStakeOf(attacker), 0, "no phantom balance");
        vm.prank(attacker);
        vm.expectRevert(StakeRegistry.AmountZero.selector);
        stakeReg.requestExit(0);

        // Alice's principal is untouched and still fully backed.
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ);
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "still solvent");
    }

    /// Approving less than the credit must fail too — the registry verifies the
    /// measured balance delta, not the caller's word.
    function test_underfunded_reward_reverts() public {
        _stake(alice, 100 * XBZZ);
        bzz.mint(oldLogic, 2 * XBZZ);
        vm.prank(oldLogic);
        bzz.approve(address(stakeReg), 5 * XBZZ); // approves 5, holds only 2

        vm.prank(oldLogic);
        vm.expectRevert();
        stakeReg.reward(alice, 5 * XBZZ);
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation intact");
    }

    function test_frozen_stake_is_excluded_from_draws_until_thaw() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, 10 * XBZZ);
        stakeReg.freeze(alice, 10 * XBZZ, vm.getBlockTimestamp() + 3 days);
        vm.stopPrank();

        assertEq(stakeReg.eligibleWeightOf(alice), 0, "frozen -> fully excluded from draws");
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        stakeReg.thaw(alice);
        assertGt(stakeReg.eligibleWeightOf(alice), 0, "eligible again after thaw");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "freezing never destroys principal");
    }

    // --- duty pool (H-07) ----------------------------------------------------

    function test_unpledged_stake_is_never_drawn() public {
        _stake(alice, 100 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
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
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
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
        stakeReg.penalizeNoShow(alice, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);

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
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);

        vm.prank(oldLogic);
        stakeReg.penalizeNoShow(alice, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (, , , uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 0, "passive staker is untouchable");
    }

    // --- index registry ------------------------------------------------------

    function test_supersafe_requires_uncontested_full_quorum_and_age() public {
        vm.startPrank(oldLogic);
        indexReg.writeEntry(TK, 1, keccak256("a"), bytes32(0), true, true, 0, 0, bytes32(0)); // qualifies
        indexReg.writeEntry(TK, 2, keccak256("b"), bytes32(0), false, true, 0, 0, bytes32(0)); // contested
        indexReg.writeEntry(TK, 3, keccak256("c"), bytes32(0), true, false, 0, 0, bytes32(0)); // under-quorum
        vm.stopPrank();

        assertEq(indexReg.supersafeEntries(TK, 96 hours, 0, 10).length, 0, "too young");
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        IndexRegistry.Entry[] memory ss = indexReg.supersafeEntries(TK, 96 hours, 0, 10);
        assertEq(ss.length, 1, "only the uncontested full-quorum entry");
        assertEq(ss[0].localCaseId, 1);
    }

    function test_reads_are_paginated_and_never_gated() public {
        vm.startPrank(oldLogic);
        for (uint256 i = 0; i < 25; i++) {
            indexReg.writeEntry(TK, i, keccak256(abi.encode(i)), bytes32(0), true, true, 0, 0, bytes32(0));
        }
        vm.stopPrank();

        // Anyone reads, including after the writing logic is revoked.
        stakeReg.revokeLogic(oldLogic);
        indexReg.revokeLogic(oldLogic);
        vm.prank(bob);
        IndexRegistry.Entry[] memory page = indexReg.entries(TK, 10, 10);
        assertEq(page.length, 10, "paginated slice");
        assertEq(page[0].localCaseId, 10);
        assertEq(indexReg.entries(TK, 20, 10).length, 5, "final short page");
    }

    function test_index_deletion_is_o1_and_relocates_positions() public {
        uint256[] memory ids = new uint256[](5);
        vm.startPrank(oldLogic);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = indexReg.writeEntry(TK, i, keccak256(abi.encode(i)), bytes32(0), true, true, 0, 0, bytes32(0));
        }
        indexReg.deleteEntry(TK, ids[0]); // front entry: swap-pop with the last
        vm.stopPrank();

        assertEq(indexReg.entryCount(TK), 4);
        assertFalse(indexReg.isIndexed(TK, ids[0]), "deleted");
        assertTrue(indexReg.isIndexed(TK, ids[4]), "moved entry still addressable");
        // The relocated entry can still be deleted by id (position map is correct).
        vm.prank(oldLogic);
        indexReg.deleteEntry(TK, ids[4]);
        assertEq(indexReg.entryCount(TK), 3);
        assertFalse(indexReg.isIndexed(TK, ids[4]));
    }

    // --- M2.6-P0-1b: the content reservation is as permanent as the entry ----

    /// The reservation must not die with the logic that took it. Held in
    /// `Moderation`, it restarted empty on every redeployment, so a replacement
    /// logic re-indexed content already live in this index.
    function test_content_reservation_survives_a_logic_upgrade() public {
        bytes32 key = keccak256("content-key");

        vm.prank(oldLogic);
        bool first = indexReg.tryReserveContent(key, 0); // case 0 — a fresh logic starts there too
        assertTrue(first, "first reservation succeeds");

        (bool exists, address logic, uint256 caseId) = indexReg.contentReservation(key);
        assertTrue(exists, "reserved");
        assertEq(logic, oldLogic, "owned by the logic that took it");
        assertEq(caseId, 0, "and by its own case 0");

        _authorize(newLogic);
        indexReg.revokeLogic(oldLogic);

        assertTrue(indexReg.isContentReserved(key), "reservation survives the upgrade");
        // Call BEFORE asserting: an external call inside the assert's argument
        // list would consume the prank (StackDeployer header, trap 1).
        vm.prank(newLogic);
        bool second = indexReg.tryReserveContent(key, 0);
        assertFalse(second, "the replacement logic is refused content already live in the index");
    }

    /// H-02 ownership keying, widened across versions: a replacement logic must
    /// not be able to free live content by naming a case id it also holds. Both
    /// logics number their first case 0, so this is the collision to close.
    function test_replacement_logic_cannot_release_a_legacy_reservation() public {
        bytes32 key = keccak256("content-key");
        vm.prank(oldLogic);
        indexReg.tryReserveContent(key, 0);

        _authorize(newLogic);

        // Same case id, different logic: a no-op, not a release.
        vm.prank(newLogic);
        indexReg.releaseContent(key, 0);
        assertTrue(indexReg.isContentReserved(key), "another logic cannot free it");

        // Right logic, wrong case: also a no-op (the stale-removal case, H-02).
        vm.prank(oldLogic);
        indexReg.releaseContent(key, 7);
        assertTrue(indexReg.isContentReserved(key), "a different case cannot free it");

        // Only the owning (logic, case) pair releases.
        vm.prank(oldLogic);
        indexReg.releaseContent(key, 0);
        assertFalse(indexReg.isContentReserved(key), "the owner releases it");

        // And then it is available again.
        vm.prank(newLogic);
        indexReg.tryReserveContent(key, 0);
        (, address logicAfter,) = indexReg.contentReservation(key);
        assertEq(logicAfter, newLogic, "freed content is reservable by the new logic");
    }

    /// Reservations are logic-facing state, not public: an arbitrary caller must
    /// not be able to squat content keys or free live ones.
    function test_content_reservation_is_logic_gated() public {
        bytes32 key = keccak256("content-key");
        vm.prank(alice);
        vm.expectRevert(IndexRegistry.NotLogic.selector);
        indexReg.tryReserveContent(key, 0);

        vm.prank(oldLogic);
        indexReg.tryReserveContent(key, 0);

        vm.prank(alice);
        vm.expectRevert(IndexRegistry.NotLogic.selector);
        indexReg.releaseContent(key, 0);
        assertTrue(indexReg.isContentReserved(key), "still held");
    }

    /// H-05: the seat seed is armed against `eligibilityAddVersion`, so EVERY
    /// path that adds draw-eligible weight must bump it. If one does not, an
    /// attacker can wait for a snapshot block's hash to become public and only
    /// then reshape the tree in its favour — the draw would proceed on entropy
    /// the attacker already knew. activate() and thaw() were both silent here,
    /// which retired the defence the moment staking moved off the monolith.
    function test_eligibility_version_bumps_on_every_weight_add() public {
        _stake(alice, 100 * XBZZ);
        uint256 v0 = stakeReg.eligibilityAddVersion();

        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);
        uint256 v1 = stakeReg.eligibilityAddVersion();
        assertGt(v1, v0, "activate: pending stake becomes drawable");

        vm.prank(alice);
        stakeReg.setDutyUnits(10);
        uint256 v2 = stakeReg.eligibilityAddVersion();
        assertGt(v2, v1, "setDutyUnits: pledging capacity adds draw weight");

        vm.startPrank(oldLogic);
        stakeReg.lock(alice, RISK_PER_SEAT);
        stakeReg.freeze(alice, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        vm.stopPrank();
        uint256 v3 = stakeReg.eligibilityAddVersion();
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "frozen -> out of the pool");

        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        stakeReg.thaw(alice);
        assertGt(stakeReg.eligibilityAddVersion(), v3, "thaw: a frozen moderator re-enters the pool");
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
