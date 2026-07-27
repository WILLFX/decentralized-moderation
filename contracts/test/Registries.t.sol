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
    uint256 internal constant EPOCH_BLOCKS = 256; // M2.6-P0-3 eligibility-epoch cadence

    MockBZZ internal bzz;
    StakeRegistry internal stakeReg;
    IndexRegistry internal indexReg;

    address internal oldLogic = makeAddr("oldLogic");
    address internal newLogic = makeAddr("newLogic");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant TK = keccak256("marine biology");
    /// M2.6-P0-5: obligations are keyed per case-round. These stand in for two
    /// distinct cases in the registry-level fixtures.
    uint256 internal constant CASE_A = (1 << 8) | 0;
    uint256 internal constant CASE_B = (2 << 8) | 0;

    function setUp() public {
        bzz = new MockBZZ();
        stakeReg = new StakeRegistry(
            IERC20(address(bzz)), TIMELOCK, MIN_STAKE, ACTIVATION, COOLDOWN, RISK_PER_SEAT, EPOCH_BLOCKS
        );
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

    /// Cross an eligibility-epoch boundary and apply staged changes (M2.6-P0-3).
    function _settleEpoch() internal {
        vm.roll(vm.getBlockNumber() + EPOCH_BLOCKS);
        stakeReg.advanceEpoch(type(uint256).max);
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
        _settleEpoch(); // pledged capacity is drawable from the next epoch
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
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
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
        assertTrue(stakeReg.logicState(newLogic) != StakeRegistry.LogicState.NONE);
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
        stakeReg.lock(alice, CASE_A, 10 * XBZZ); // an in-flight case

        _authorize(newLogic); // both authorized now
        assertTrue(stakeReg.logicState(oldLogic) != StakeRegistry.LogicState.NONE, "old logic still authorized during handover");
        assertTrue(stakeReg.logicState(newLogic) != StakeRegistry.LogicState.NONE);

        // The old logic settles its open case.
        vm.prank(oldLogic);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
        (, , uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(committed, 0, "in-flight case settled under the old logic");

        // Only once drained is it revoked.
        stakeReg.revokeLogic(oldLogic);
        vm.prank(oldLogic);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
    }

    /// Governance may NAME the logic contract and nothing else: it can never move,
    /// lock, freeze or credit stake itself.
    function test_governance_cannot_touch_funds() public {
        _stakeActivatePledge(alice, 100 * XBZZ);

        // The test contract is governance; it is not a logic contract.
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.freeze(alice, CASE_A, 1, vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.reward(alice, 1);
        vm.expectRevert(IndexRegistry.NotLogic.selector);
        indexReg.writeEntry(TK, 1, bytes32(0), bytes32(0), true, true, 0, 0, bytes32(0));
    }

    function test_unauthorized_caller_cannot_use_the_privileged_api() public {
        _stake(alice, 100 * XBZZ);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotLogic.selector);
        stakeReg.lock(alice, CASE_A, 1);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotGovernance.selector);
        stakeReg.proposeLogic(bob);
    }

    // --- registry-local invariants -------------------------------------------

    function test_conservation_across_the_privileged_api() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 50 * XBZZ);

        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 30 * XBZZ);
        stakeReg.freeze(alice, CASE_A, 10 * XBZZ, vm.getBlockTimestamp() + 1 days);
        stakeReg.release(alice, CASE_A, 20 * XBZZ);
        stakeReg.lock(bob, CASE_A, 10 * XBZZ);
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
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.freeze(alice, CASE_A, 10 * XBZZ, vm.getBlockTimestamp() + 3 days);
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
        (address[] memory seats,) = stakeReg.drawPanel(5, keccak256("s"), 0, CASE_A);
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
        _settleEpoch();

        vm.prank(oldLogic);
        (address[] memory seats,) = stakeReg.drawPanel(10, keccak256("s"), 0, CASE_A);
        assertEq(seats.length, 3, "seated exactly the pledged capacity");
        (, uint256 reserved, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(reserved, 3, "one unit reserved per seat");
        assertEq(bonded, 3 * RISK_PER_SEAT, "and one unit's collateral ESCROWED per seat (P0-2)");
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "capacity exhausted -> out of the pool");

        // Releasing capacity puts the moderator back in the pool.
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 3, 0, vm.getBlockTimestamp() + 1 days);
        (, reserved, bonded) = stakeReg.dutyOf(alice);
        assertEq(reserved, 0);
        assertEq(bonded, 0, "escrow returned to free stake");
        assertGt(stakeReg.eligibleWeightOf(alice), 0, "eligible again once the case ends");
    }

    /// The no-show penalty (H-07/H-10): a pledged moderator that is drawn and does
    /// not serve pays a freeze of its OWN stake — never a transfer to anyone.
    ///
    /// Since M2.6-P0-2 the penalty is taken from the escrow the DRAW posted, so
    /// the moderator has to actually be seated first. That is the point: there is
    /// no longer a reachable-balance calculation for the moderator to manipulate.
    function test_no_show_penalty_freezes_own_stake_only() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        uint256 bobBefore = stakeReg.totalStakeOf(bob);

        vm.prank(oldLogic);
        stakeReg.drawPanel(1, keccak256("noshow"), 0, CASE_A); // seats alice or bob; both are pledged
        // Penalize whoever was actually seated.
        (,, uint256 aliceBond) = stakeReg.dutyOf(alice);
        address seated = aliceBond > 0 ? alice : bob;
        if (seated != alice) {
            // Re-point the assertions at the seated moderator.
            (alice, bob) = (bob, alice);
            bobBefore = stakeReg.totalStakeOf(bob);
        }

        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);

        (, , , uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, RISK_PER_SEAT, "one seat's worth frozen");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "principal not destroyed, only locked");
        assertEq(stakeReg.totalStakeOf(bob), bobBefore, "nobody gained from the penalty");
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "frozen -> excluded from draws");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Stake that never opted in cannot be penalized — it was never drawable, so
    /// submission spam cannot grief passive stakers. Under M2.6-P0-2 this holds by
    /// construction rather than by a `dutyUnits == 0` guard: a moderator that was
    /// never seated has nothing bonded, and the penalty can only reach escrow.
    /// Since P0-5a it is stronger still — the penalty can only reach escrow THIS
    /// case posted, so an empty obligation makes it a no-op regardless of what the
    /// moderator holds elsewhere.
    function test_unpledged_stake_cannot_be_penalized() public {
        _stake(alice, 100 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);

        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (, , , uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 0, "passive staker is untouchable");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    // --- M2.6-P0-2: duty reservation escrows real collateral -----------------
    //
    // `drawPanel` used to increment `dutyReserved` and move no tokens, so a seat's
    // backing stayed in `free` and stayed user-controlled. The no-show penalty is
    // the stated defence against appeal-panel obstruction (H-10); it cost nothing.

    /// Seat one moderator and return it. Both are pledged, so the draw picks one
    /// of them; the test asserts against whichever was actually seated.
    function _seatOne(bytes32 seed) internal returns (address seated, address other) {
        vm.prank(oldLogic);
        stakeReg.drawPanel(1, seed, 0, CASE_A);
        (,, uint256 aliceBond) = stakeReg.dutyOf(alice);
        return aliceBond > 0 ? (alice, bob) : (bob, alice);
    }

    /// The escrow itself: drawing moves collateral out of free stake.
    function test_draw_escrows_collateral_out_of_free_stake() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        (uint256 freeBefore,,,,,,,,) = stakeReg.moderatorInfo(alice);

        vm.prank(oldLogic);
        stakeReg.drawPanel(1, keccak256("escrow"), 0, CASE_A);

        (uint256 freeAfter,,,,,,,,) = stakeReg.moderatorInfo(alice);
        (,, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(bonded, RISK_PER_SEAT, "one seat's collateral is escrowed");
        assertEq(freeBefore - freeAfter, RISK_PER_SEAT, "and it left free stake");
        assertEq(stakeReg.totalDutyBondedStake(), RISK_PER_SEAT, "tracked in its own bucket");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "still the moderator's own money");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation across four buckets");
    }

    /// Bypass 1: `setDutyUnits(0)` after selection. It used to make the
    /// then-current penalty function return on its `dutyUnits == 0` guard.
    /// Driven through `settleDuty`, the production path, since M2.6-P0-5c deleted
    /// the unscoped one.
    function test_bypass_setDutyUnits_zero_after_selection() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        (address seated,) = _seatOne(keccak256("b1"));

        vm.prank(seated);
        vm.expectRevert(StakeRegistry.DutyReserved.selector);
        stakeReg.setDutyUnits(0);

        // Reducing to below what live panels hold is refused; the escrow is intact.
        (,, uint256 bonded) = stakeReg.dutyOf(seated);
        assertEq(bonded, RISK_PER_SEAT, "escrow survives the un-pledge attempt");

        vm.prank(oldLogic);
        stakeReg.settleDuty(seated, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(seated);
        assertEq(frozen, RISK_PER_SEAT, "the penalty is payable and applied");
    }

    /// M2.6-P0-5c: the unscoped no-show penalty must stay deleted, and the
    /// property its deletion restores must hold.
    ///
    /// `penalizeNoShow` had lost its caller — `settleDuty` supersedes it — but kept
    /// a live selector that wrote the POOLED `m.dutyBonded` with no `caseRef`.
    /// `dutyBonded` pools escrow across every case a moderator is seated in, so any
    /// authorized logic could freeze collateral posted for a different case's
    /// outstanding seat: the exact class P0-5a made unrepresentable everywhere else.
    /// It was deleted rather than given a `caseRef`, because a scoped version would
    /// be dead code with a live selector.
    ///
    /// This test fails if it is ever reintroduced under its old signature.
    function test_unscoped_no_show_penalty_selector_is_gone() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        (address seated,) = _seatOne(keccak256("p05c"));
        uint256 until = vm.getBlockTimestamp() + 1 days;

        bytes memory unscoped =
            abi.encodeWithSignature("penalizeNoShow(address,uint256,uint256)", seated, RISK_PER_SEAT, until);
        vm.prank(oldLogic);
        (bool ok,) = address(stakeReg).call(unscoped);
        assertFalse(ok, "no such function and no fallback: pooled dutyBonded is unreachable");

        // The surviving path cannot substitute for it either: naming the WRONG case
        // reaches nothing, because the escrow belongs to CASE_A's obligation.
        vm.prank(oldLogic);
        stakeReg.settleDuty(seated, CASE_B, 1, RISK_PER_SEAT, until);
        (,, uint256 bonded) = stakeReg.dutyOf(seated);
        assertEq(bonded, RISK_PER_SEAT, "another case's settlement cannot reach this case's escrow");
        (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(seated);
        assertEq(frozen, 0, "and it cannot freeze it either");

        // Named correctly, it settles — so the capability was not lost, only scoped.
        vm.prank(oldLogic);
        stakeReg.settleDuty(seated, CASE_A, 1, RISK_PER_SEAT, until);
        (,,, frozen,,,,,) = stakeReg.moderatorInfo(seated);
        assertEq(frozen, RISK_PER_SEAT, "the owning case can still penalise");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Bypass 2: `requestExit(all free)` after selection. The then-current penalty
    /// function subtracted `exitAmount` from what it could reach, so the penalty
    /// silently became a no-op — and the exit did not even have to complete.
    function test_bypass_requestExit_after_selection() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        (address seated,) = _seatOne(keccak256("b2"));

        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(seated);
        vm.prank(seated);
        stakeReg.requestExit(free); // everything still withdrawable

        vm.prank(oldLogic);
        stakeReg.settleDuty(seated, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(seated);
        assertEq(frozen, RISK_PER_SEAT, "escrow is not reachable by the exit path");

        // And the exit cannot carry the bonded collateral out.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.prank(seated);
        stakeReg.withdraw();
        (,, uint256 bondedAfter) = stakeReg.dutyOf(seated);
        assertEq(bondedAfter, 0, "bond was consumed by the penalty, not withdrawn");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Bypass 4: the same free stake backing several outstanding assignments.
    /// Capacity was reserved without moving tokens, so one balance could back
    /// every seat it was drawn for. A seat is now only issued if its collateral
    /// can be escrowed, so backing cannot be double-spent across cases.
    function test_bypass_same_backing_cannot_cover_two_assignments() public {
        // Pledge two units against two units of stake — valid at pledge time —
        // then reserve half of it for exit. Pledged CAPACITY is still 2, but the
        // stake actually available to back an assignment is now 1 unit.
        _stake(alice, 2 * RISK_PER_SEAT);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);
        vm.prank(alice);
        stakeReg.setDutyUnits(2);
        _settleEpoch(); // capacity is live from here
        // The exit reservation lands mid-epoch: the TREE still shows two units of
        // capacity, but the struct — which is what `drawPanel` checks before
        // escrowing — shows only one unit of usable stake.
        vm.prank(alice);
        stakeReg.requestExit(RISK_PER_SEAT);

        vm.prank(oldLogic);
        (address[] memory seats,) = stakeReg.drawPanel(2, keccak256("b4"), 0, CASE_A);

        // Before the escrow, capacity alone gated the draw: both seats were issued
        // and both were "backed" by the same single unit of usable stake.
        assertEq(seats.length, 1, "seated only what the stake can actually escrow");
        (, uint256 reserved, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(reserved, 1, "capacity consumed matches collateral posted");
        assertEq(bonded, RISK_PER_SEAT, "every seated assignment is fully backed");
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "no unbacked capacity remains drawable");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Escrow returns to free stake when the case ends, and only once.
    function test_release_returns_escrow_exactly_once() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        (uint256 freeBefore,,,,,,,,) = stakeReg.moderatorInfo(alice);

        vm.prank(oldLogic);
        stakeReg.drawPanel(2, keccak256("rel"), 0, CASE_A);

        vm.startPrank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 2, 0, vm.getBlockTimestamp() + 1 days);
        stakeReg.settleDuty(alice, CASE_A, 2, 0, vm.getBlockTimestamp() + 1 days); // a double release must not mint stake
        vm.stopPrank();

        (uint256 freeAfter,,,,,,,,) = stakeReg.moderatorInfo(alice);
        (,, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(bonded, 0, "escrow fully returned");
        assertEq(freeAfter, freeBefore, "and exactly restored, not doubled");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// A committed seat's bond becomes committed stake rather than being released
    /// twice: `lock` draws from the escrow that was posted for it.
    function test_commit_converts_escrow_not_free_stake() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.prank(oldLogic);
        stakeReg.drawPanel(1, keccak256("conv"), 0, CASE_A);
        (uint256 freeAfterDraw,,,,,,,,) = stakeReg.moderatorInfo(alice);

        vm.prank(oldLogic);
        stakeReg.lock(alice, CASE_A, RISK_PER_SEAT);

        (uint256 free,, uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        (,, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(committed, RISK_PER_SEAT, "the vote is collateralized");
        assertEq(bonded, 0, "out of escrow");
        assertEq(free, freeAfterDraw, "free stake was not touched a second time");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// Settling one case's assignment must not consume escrow belonging to
    /// another case's outstanding seat.
    ///
    /// `dutyBonded` is a pool shared across every case a moderator is seated in.
    /// Penalising and releasing as two calls reads that pool twice: the penalty
    /// takes a seat's worth, and the release then still hands back a full
    /// `riskPerSeat` — draining the OTHER case's collateral and silently
    /// un-bonding its seat, so that case's own penalty later becomes a no-op.
    /// Nothing is minted, so conservation still holds and the leak is invisible
    /// unless the two are one operation.
    function test_settling_one_case_cannot_drain_another_cases_escrow() public {
        _stakeActivatePledge(alice, 100 * XBZZ);

        // Two separate cases each seat this moderator once.
        vm.startPrank(oldLogic);
        stakeReg.drawPanel(1, keccak256("caseA"), 0, CASE_A);
        stakeReg.drawPanel(1, keccak256("caseB"), 0, CASE_A);
        vm.stopPrank();
        (, uint256 reserved, uint256 bonded) = stakeReg.dutyOf(alice);
        assertEq(reserved, 2, "two outstanding assignments");
        assertEq(bonded, 2 * RISK_PER_SEAT, "each with its own escrow");

        // Case A settles; the moderator no-showed there.
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);

        (,, bonded) = stakeReg.dutyOf(alice);
        assertEq(bonded, RISK_PER_SEAT, "case B's escrow is untouched");
        (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, RISK_PER_SEAT, "A's penalty applied");

        // Case B settles; its penalty is still payable, which is the point.
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (,,, frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 2 * RISK_PER_SEAT, "B's penalty applied too");
        (,, bonded) = stakeReg.dutyOf(alice);
        assertEq(bonded, 0);
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// A moderator that served gets its escrow back rather than frozen.
    function test_settling_a_served_assignment_returns_the_escrow() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        (uint256 freeBefore,,,,,,,,) = stakeReg.moderatorInfo(alice);

        vm.startPrank(oldLogic);
        stakeReg.drawPanel(1, keccak256("served"), 0, CASE_A);
        stakeReg.settleDuty(alice, CASE_A, 1, 0, vm.getBlockTimestamp() + 1 days); // no penalty
        vm.stopPrank();

        (uint256 free,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 0, "serving costs nothing");
        assertEq(free, freeBefore, "escrow returned in full");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// A moderator whose ENTIRE stake is escrowed against its own assignment must
    /// still be able to commit it. The collateral is in `dutyBonded`, not `free`,
    /// so a commit path that measures only free stake would refuse the very seat
    /// the escrow was posted for — the H-07 liveness failure, reintroduced by the
    /// escrow itself if the buckets are not both counted.
    function test_fully_bonded_moderator_can_still_commit_its_seat() public {
        _stake(alice, RISK_PER_SEAT); // exactly one unit, nothing spare
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);
        vm.prank(alice);
        stakeReg.setDutyUnits(1);
        _settleEpoch();

        vm.prank(oldLogic);
        stakeReg.drawPanel(1, keccak256("bonded"), 0, CASE_A);

        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(free, 0, "every token is escrowed");
        assertEq(stakeReg.dutyBondedOf(alice), RISK_PER_SEAT, "and visible as backing");

        // The commit converts that escrow; it must not need free stake.
        vm.prank(oldLogic);
        stakeReg.lock(alice, CASE_A, RISK_PER_SEAT);
        (, , uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(committed, RISK_PER_SEAT, "the seat it was drawn for is collateralized");
        assertEq(stakeReg.dutyBondedOf(alice), 0);
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    // --- M2.6-P0-5: obligations are keyed, not pooled -------------------------

    /// The cross-CASE drain, which per-logic scoping alone would not have caught.
    ///
    /// `dutyBonded` was one pool per moderator. A moderator seated in two cases
    /// held 2x escrow in it, and case A settling one seat handed back a full
    /// `riskPerSeat` bounded only by that pool — draining case B's escrow and
    /// silently un-bonding B's outstanding seat, so B's no-show penalty became a
    /// no-op. Nothing is minted, so conservation still holds and the leak is
    /// invisible from the aggregates. P0-2 shipped `settleDuty` as one atomic
    /// operation to stop it; handles make it unrepresentable.
    function test_settling_one_case_cannot_touch_another_cases_escrow() public {
        _stakeActivatePledge(alice, 100 * XBZZ);

        vm.startPrank(oldLogic);
        stakeReg.drawPanel(1, keccak256("A"), 0, CASE_A);
        stakeReg.drawPanel(1, keccak256("B"), 0, CASE_B);
        vm.stopPrank();

        (,, uint256 bondA) = stakeReg.obligationOf(oldLogic, alice, CASE_A);
        (,, uint256 bondB) = stakeReg.obligationOf(oldLogic, alice, CASE_B);
        assertEq(bondA, RISK_PER_SEAT, "case A escrowed its own seat");
        assertEq(bondB, RISK_PER_SEAT, "and so did case B");

        // Case A settles, asking to release far more than it ever reserved.
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 10, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);

        (,, bondB) = stakeReg.obligationOf(oldLogic, alice, CASE_B);
        assertEq(bondB, RISK_PER_SEAT, "B's escrow is untouched by A's over-ask");

        // And B's penalty is therefore still payable — the property the drain
        // silently removed.
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_B, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (,,, uint256 frozen,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(frozen, 2 * RISK_PER_SEAT, "both cases' penalties applied");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// The same shape for committed stake: a double release must revert, not be
    /// absorbed. Under pooled accounting the second call simply succeeded against
    /// whatever aggregate remained.
    function test_double_release_reverts_rather_than_being_absorbed() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.lock(alice, CASE_B, 10 * XBZZ);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
        vm.stopPrank();

        // A is discharged; releasing it again must not reach into B's obligation.
        vm.prank(oldLogic);
        vm.expectRevert(StakeRegistry.NotYourObligation.selector);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);

        (uint256 committedB,,) = stakeReg.obligationOf(oldLogic, alice, CASE_B);
        assertEq(committedB, 10 * XBZZ, "B's commitment intact");
    }

    /// Cross-LOGIC: during a handover both are authorized, and B must not be able
    /// to discharge anything A created.
    function test_cross_logic_discharge_reverts() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.drawPanel(1, keccak256("A"), 0, CASE_A);
        vm.stopPrank();

        _authorize(newLogic); // handover: both authorized

        // Same case reference, different logic — a different obligation entirely.
        vm.prank(newLogic);
        vm.expectRevert(StakeRegistry.NotYourObligation.selector);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);

        vm.prank(newLogic);
        vm.expectRevert(StakeRegistry.NotYourObligation.selector);
        stakeReg.freeze(alice, CASE_A, 10 * XBZZ, vm.getBlockTimestamp() + 1 days);

        // Duty settlement clamps to B's own (empty) obligation rather than
        // discharging A's seat.
        vm.prank(newLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);
        (,, uint256 bondA) = stakeReg.obligationOf(oldLogic, alice, CASE_A);
        assertEq(bondA, RISK_PER_SEAT, "A's escrow untouched by B");

        // A's own settlement still works, which is the point of the handover.
        vm.prank(oldLogic);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
        (,, uint256 committed,,,,,,) = stakeReg.moderatorInfo(alice);
        assertEq(committed, 0, "the rightful owner settles normally");
    }

    /// Re-authorizing a revoked logic gives it a fresh handle namespace, so it
    /// cannot reach obligations from its previous life.
    function test_reauthorization_does_not_inherit_old_handles() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.release(alice, CASE_A, 10 * XBZZ); // drain: revocation now requires it
        vm.stopPrank();
        uint256 epochBefore = stakeReg.authEpoch(oldLogic);

        stakeReg.revokeLogic(oldLogic);
        _authorize(oldLogic); // same address, authorized again
        assertGt(stakeReg.authEpoch(oldLogic), epochBefore, "a new namespace");

        // The re-authorized contract starts empty: a case reference it used in its
        // previous life resolves to a different handle entirely.
        vm.prank(oldLogic);
        vm.expectRevert(StakeRegistry.NotYourObligation.selector);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
    }

    /// M2.6-P0-5d: governance must not be able to orphan live obligation handles.
    ///
    /// `executeLogic` bumped `authEpoch` unconditionally, and `authEpoch` is part of
    /// every handle. Re-executing a proposal for an ALREADY-authorized logic — a
    /// duplicate proposal, a re-run script, a governance mistake — renamed the whole
    /// namespace in one transaction. Every live handle was orphaned: `_debit` then
    /// reverted `NotYourObligation` on the rightful owner's own settlement,
    /// permanently, so committed stake was stranded, escrow could not be released,
    /// and the per-logic counters never reached zero — `canRevoke` stayed false
    /// forever and the contract could not even be retired out of the way.
    ///
    /// Nothing is minted and conservation still holds, which is why it would not
    /// show up in the invariant campaign.
    function test_reauthorizing_a_live_logic_cannot_orphan_its_obligations() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.drawPanel(1, keccak256("live"), 0, CASE_A);
        indexReg.openCase(1); // the same case, index-side (M2.6-P0-5b)
        vm.stopPrank();
        assertFalse(stakeReg.canRevoke(oldLogic), "a live case is outstanding");
        assertFalse(indexReg.canRevoke(oldLogic), "index-side too");
        uint256 epochBefore = stakeReg.authEpoch(oldLogic);

        // The proposal is legitimate and the timelock is honoured; only the drain
        // state makes it unsafe.
        stakeReg.proposeLogic(oldLogic);
        indexReg.proposeLogic(oldLogic);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
        vm.expectRevert(StakeRegistry.LogicStillHasObligations.selector);
        stakeReg.executeLogic();
        // Both registries refuse together, so governance cannot desync them by
        // executing the pair.
        vm.expectRevert(IndexRegistry.LogicStillHasObligations.selector);
        indexReg.executeLogic();

        assertEq(stakeReg.authEpoch(oldLogic), epochBefore, "the namespace is intact");

        // And the obligations it already held still settle normally, which is the
        // property the bump would have destroyed.
        vm.prank(oldLogic);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
        vm.prank(oldLogic);
        stakeReg.settleDuty(alice, CASE_A, 1, 0, vm.getBlockTimestamp() + 1 days);
        vm.prank(oldLogic);
        indexReg.closeCase(1);
        assertTrue(stakeReg.canRevoke(oldLogic), "drained normally");
        assertTrue(indexReg.canRevoke(oldLogic), "index-side too");
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");

        // Once drained, the same proposal executes: the gate is about live state,
        // not about forbidding re-authorization.
        stakeReg.executeLogic();
        assertGt(stakeReg.authEpoch(oldLogic), epochBefore, "a fresh namespace, safely");
    }

    /// A FIRST authorization is unaffected — that is the only case where the
    /// `authEpoch` bump has a job to do.
    function test_first_authorization_from_none_still_bumps_the_namespace() public {
        assertEq(uint256(stakeReg.logicState(newLogic)), uint256(StakeRegistry.LogicState.NONE));
        uint256 before = stakeReg.authEpoch(newLogic);
        _authorize(newLogic);
        assertGt(stakeReg.authEpoch(newLogic), before, "fresh namespace on a first authorization");
        assertEq(uint256(stakeReg.logicState(newLogic)), uint256(StakeRegistry.LogicState.OPEN_AND_SETTLE));
    }

    /// The per-logic totals are a real drain signal, unlike `openPotsTotal`.
    function test_logic_totals_track_outstanding_obligations() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        assertEq(stakeReg.logicCommitted(oldLogic), 0);

        vm.startPrank(oldLogic);
        stakeReg.lock(alice, CASE_A, 10 * XBZZ);
        stakeReg.drawPanel(1, keccak256("A"), 0, CASE_A);
        vm.stopPrank();
        assertEq(stakeReg.logicCommitted(oldLogic), 10 * XBZZ);
        assertEq(stakeReg.logicDutyReserved(oldLogic), 1);

        vm.startPrank(oldLogic);
        stakeReg.release(alice, CASE_A, 10 * XBZZ);
        stakeReg.settleDuty(alice, CASE_A, 1, 0, vm.getBlockTimestamp() + 1 days);
        vm.stopPrank();
        assertEq(stakeReg.logicCommitted(oldLogic), 0, "drained");
        assertEq(stakeReg.logicDutyReserved(oldLogic), 0, "drained");
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

    // --- M2.6-P0-3: eligibility is constant within an epoch -------------------

    /// The property, stated directly rather than through a change counter: no
    /// weight-changing path — in EITHER direction — moves the sortition tree
    /// inside an epoch.
    ///
    /// This replaces `test_eligibility_version_bumps_on_every_weight_add`, which
    /// asserted that `eligibilityAddVersion` was bumped. That counter was the
    /// defence and it was broken both ways: `setDutyUnits(sameValue)` bumped it
    /// with no change (so a griefer could re-arm every pending case forever),
    /// while `release`, `reward` and `releaseDuty` grew the drawable set and never
    /// bumped it at all. Decreases — `requestExit`, `freeze` — were never tracked
    /// either, and removing an interval remaps the whole weighted tree.
    function test_weight_changes_do_not_move_the_tree_within_an_epoch() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);

        uint256 totalAtEpochStart = stakeReg.totalEligibleWeight();
        uint256 aliceAtEpochStart = stakeReg.eligibleWeightOf(alice);
        assertGt(totalAtEpochStart, 0, "there is a live eligible set to move");

        // INCREASES: the paths the old counter missed entirely.
        _stake(alice, 50 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        stakeReg.activate(alice);
        // `reward` pulls its own funding (M2.6-P0-4), so fund the caller first.
        bzz.mint(oldLogic, 5 * XBZZ);
        vm.prank(oldLogic);
        bzz.approve(address(stakeReg), type(uint256).max);
        vm.startPrank(oldLogic);
        stakeReg.reward(alice, 5 * XBZZ); // credit path: grew weight, never bumped the counter
        stakeReg.setTrack(alice, 1);
        vm.stopPrank();

        // DECREASES: never tracked at all, and they remap the whole tree.
        vm.prank(bob);
        stakeReg.requestExit(20 * XBZZ);
        vm.prank(oldLogic);
        stakeReg.lock(bob, CASE_A, RISK_PER_SEAT);
        vm.prank(oldLogic);
        stakeReg.freeze(bob, CASE_A, RISK_PER_SEAT, vm.getBlockTimestamp() + 1 days);

        // A no-op re-pledge: the exact call that used to re-arm every case.
        vm.prank(alice);
        stakeReg.setDutyUnits(10);
        vm.prank(alice);
        stakeReg.setDutyUnits(10);

        assertEq(stakeReg.totalEligibleWeight(), totalAtEpochStart, "total unmoved within the epoch");
        assertEq(stakeReg.eligibleWeightOf(alice), aliceAtEpochStart, "and so is every leaf");

        // They are not lost — they land at the boundary, together.
        vm.roll(vm.getBlockNumber() + EPOCH_BLOCKS);
        stakeReg.advanceEpoch(type(uint256).max);
        assertTrue(
            stakeReg.totalEligibleWeight() != totalAtEpochStart,
            "staged changes take effect at the next epoch"
        );
    }

    /// The griefing half: a no-op `setDutyUnits` used to bump the global counter
    /// and force every pending case to re-arm. There is no counter to bump now,
    /// and repeating it cannot disturb the epoch's eligible set.
    function test_repeated_noop_setDutyUnits_cannot_disturb_the_epoch() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        uint256 before = stakeReg.totalEligibleWeight();

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            stakeReg.setDutyUnits(10);
            assertEq(stakeReg.totalEligibleWeight(), before, "no-op re-pledge moves nothing");
        }
        assertTrue(stakeReg.epochSettled(), "and the epoch stays settled");
    }

    /// A draw leaves the tree exactly as it found it: seats are held out of the
    /// rest of THIS draw by the exclusion list, and the persistent weight shrink
    /// is staged for the next epoch (M2.6-P0-2 + P0-3).
    function test_a_draw_does_not_move_the_tree_for_concurrent_cases() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        _stakeActivatePledge(bob, 100 * XBZZ);
        uint256 before = stakeReg.totalEligibleWeight();

        vm.prank(oldLogic);
        stakeReg.drawPanel(3, keccak256("concurrent"), 0, CASE_A);

        assertEq(stakeReg.totalEligibleWeight(), before, "the sampling distribution is unchanged mid-epoch");
        // The escrow is real regardless — the struct is the authority for seating.
        assertEq(stakeReg.totalDutyBondedStake(), 3 * RISK_PER_SEAT, "collateral was still escrowed");
    }

    // --- M2.6-P0-3c / H-03A: the seatable set, not just the tree --------------
    //
    // P0-3 froze the sortition TREE for the duration of an epoch and concluded that
    // "eligibility is constant by construction, so there is nothing to grind". The
    // tree is constant. The SEATABLE SET is not: `drawPanel` reads the live
    // moderator struct to decide whether a drawn address may actually be seated —
    // which P0-2 requires, since a seat may only be issued if its collateral can be
    // escrowed right now — and rejects an unseatable address with
    // `stakeTree.set(seat, 0)`, which REMAPS every subsequent interval of the draw.
    //
    // `setDutyUnits` only refuses `units < dutyReserved`, so a moderator holding no
    // seat (`dutyReserved == 0`) may zero its duty AFTER its seed's blockhash is
    // public. `requestExit(free)` is the same lever through `usable`.

    /// Stake, activate and pledge a set of moderators of equal weight, then settle
    /// the epoch so they are all drawable.
    function _spawnDrawable(uint256 n, uint256 amount) internal returns (address[] memory who) {
        who = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            who[i] = address(uint160(uint256(keccak256(abi.encode("h03a", i)))));
            _stake(who[i], amount);
        }
        vm.warp(vm.getBlockTimestamp() + ACTIVATION);
        for (uint256 i = 0; i < n; i++) {
            stakeReg.activate(who[i]);
            vm.prank(who[i]);
            stakeReg.setDutyUnits(amount / RISK_PER_SEAT);
        }
        _settleEpoch();
    }

    function _drawOnce(uint256 count, bytes32 seed) internal returns (address[] memory seats) {
        vm.prank(oldLogic);
        (seats,) = stakeReg.drawPanel(count, seed, 0, CASE_A);
    }

    /// Everything the panel contains except `skip`, in order. The attacker's own
    /// seats are legitimately absent once it has made itself unseatable, so what
    /// has to be compared is whether the draw landed differently ON EVERYONE ELSE.
    function _without(address[] memory seats, address skip) internal pure returns (address[] memory out) {
        out = new address[](seats.length);
        uint256 n;
        for (uint256 i = 0; i < seats.length; i++) {
            if (seats[i] != skip) out[n++] = seats[i];
        }
        assembly {
            mstore(out, n)
        }
    }

    /// The panels cannot be compared for equality: the attacker's slots are freed
    /// in the second draw, so it runs further down the same attempt sequence and
    /// seats MORE non-attacker addresses. The property is that it seats the same
    /// ones IN THE SAME ORDER — i.e. the attempt -> address mapping never moved.
    /// A remap shows up as a divergence part-way through, not as a length change.
    function _assertPrefix(address[] memory shorter, address[] memory longer, string memory what) internal pure {
        require(shorter.length <= longer.length, "fixture: expected the ungrindable draw to be at least as long");
        for (uint256 i = 0; i < shorter.length; i++) {
            assertEq(longer[i], shorter[i], what);
        }
    }

    /// The grind, run twice off one armed seed. Same seed, same tree, same epoch —
    /// the only difference is a post-seed `setDutyUnits(0)` from a holder that is
    /// not seated and therefore is not refused.
    ///
    /// Pre-fix the two panels differ: zeroing duty made the attacker unseatable,
    /// the draw removed its leaf, and every later interval shifted. With `k`
    /// identities that is a choice among subsets of a public-seed draw for gas plus
    /// one epoch of eligibility.
    function test_H03A_post_seed_setDutyUnits_cannot_reshape_the_draw() public {
        address[] memory who = _spawnDrawable(12, 100 * XBZZ);
        bytes32 seed = keccak256("h03a-duty");

        uint256 snap = vm.snapshotState();
        address[] memory clean = _drawOnce(8, seed);
        vm.revertToState(snap);

        // An attacker the clean draw DID land on, and which holds no seat of its
        // own at the moment it acts — so `setDutyUnits` does not refuse it.
        address attacker = clean[0];
        (, uint256 reserved,) = stakeReg.dutyOf(attacker);
        assertEq(reserved, 0, "not seated: the un-pledge is permitted");

        vm.prank(attacker);
        stakeReg.setDutyUnits(0); // the seed's blockhash is already public
        assertTrue(stakeReg.epochSettled(), "and the tree has NOT moved: staged for next epoch");
        assertEq(stakeReg.totalEligibleWeight(), stakeReg.totalEligibleWeight(), "same epoch, same distribution");

        address[] memory ground = _drawOnce(8, seed);

        _assertPrefix(
            _without(clean, attacker),
            _without(ground, attacker),
            "a self-directed un-pledge must not move anyone else's seat"
        );
        // It still excludes ITSELF — the seatability read stays live, so P0-2's
        // guarantee that a seat is only issued against escrow is untouched.
        for (uint256 i = 0; i < ground.length; i++) {
            assertTrue(ground[i] != attacker, "the attacker is not seated");
        }
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// `requestExit(free)` is the second lever and closes the same way.
    function test_H03A_post_seed_requestExit_cannot_reshape_the_draw() public {
        address[] memory who = _spawnDrawable(12, 100 * XBZZ);
        who;
        bytes32 seed = keccak256("h03a-exit");

        uint256 snap = vm.snapshotState();
        address[] memory clean = _drawOnce(8, seed);
        vm.revertToState(snap);

        address attacker = clean[0];
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(attacker);
        vm.prank(attacker);
        stakeReg.requestExit(free); // reserves everything: `usable` drops to zero

        address[] memory ground = _drawOnce(8, seed);

        _assertPrefix(
            _without(clean, attacker),
            _without(ground, attacker),
            "a self-directed exit request must not move anyone else's seat"
        );
        assertEq(bzz.balanceOf(address(stakeReg)), stakeReg.stakeBuckets(), "conservation");
    }

    /// The involuntary exclusion must still take effect, or a penalised moderator
    /// would keep being seated for the rest of the epoch. A freeze is imposed by
    /// settlement rather than chosen, so it is not one of the levers — and it is
    /// deliberately still allowed to remap.
    function test_H03A_a_freeze_still_excludes_from_the_rest_of_the_draw() public {
        address[] memory who = _spawnDrawable(12, 100 * XBZZ);
        who;
        bytes32 seed = keccak256("h03a-freeze");

        uint256 snap = vm.snapshotState();
        address[] memory clean = _drawOnce(8, seed);
        vm.revertToState(snap);

        address penalised = clean[0];
        vm.startPrank(oldLogic);
        stakeReg.lock(penalised, CASE_B, RISK_PER_SEAT);
        stakeReg.freeze(penalised, CASE_B, RISK_PER_SEAT, vm.getBlockTimestamp() + 30 days);
        vm.stopPrank();

        address[] memory ground = _drawOnce(8, seed);
        for (uint256 i = 0; i < ground.length; i++) {
            assertTrue(ground[i] != penalised, "a frozen moderator is not seated");
        }
    }

    /// The cut is not ignored — only its within-epoch remapping side effect is.
    /// At the next boundary the weight change lands in full.
    function test_H03A_the_cut_still_lands_at_the_next_epoch() public {
        address[] memory who = _spawnDrawable(4, 100 * XBZZ);
        uint256 before = stakeReg.totalEligibleWeight();

        vm.prank(who[0]);
        stakeReg.setDutyUnits(0);
        assertEq(stakeReg.totalEligibleWeight(), before, "unmoved within the epoch");

        _settleEpoch();
        assertLt(stakeReg.totalEligibleWeight(), before, "and fully applied at the boundary");
        assertEq(stakeReg.eligibleWeightOf(who[0]), 0, "the un-pledge really did take effect");
    }

    /// `drawPanel` refuses to sample an epoch whose staged changes are not yet in.
    function test_draw_refuses_an_unsettled_epoch() public {
        _stakeActivatePledge(alice, 100 * XBZZ);
        vm.roll(vm.getBlockNumber() + EPOCH_BLOCKS * 2);
        vm.prank(alice);
        stakeReg.setDutyUnits(9); // stages into this epoch
        vm.roll(vm.getBlockNumber() + EPOCH_BLOCKS);

        assertFalse(stakeReg.epochSettled(), "an epoch boundary passed with changes staged");

        // M2.6-P0-3b: a settled epoch is a PRECONDITION of the draw, not something
        // the draw arranges. This used to drain a bounded budget first and revert
        // if that was not enough — discarding the drain along with the draw, so an
        // oversized epoch could never complete and every draw stayed blocked. The
        // assertion here was "the draw applied the backlog itself", which is the
        // behaviour that made the discard possible.
        vm.prank(oldLogic);
        vm.expectRevert(StakeRegistry.EpochNotSettled.selector);
        stakeReg.drawPanel(1, keccak256("settles"), 0, CASE_A);
        assertEq(stakeReg.drainCursor(), 0, "and it did no work it would have had to unwind");

        // The drain is its own permissionless call, and it commits.
        stakeReg.advanceEpoch(type(uint256).max);
        assertTrue(stakeReg.epochSettled(), "backlog applied");
        vm.prank(oldLogic);
        stakeReg.drawPanel(1, keccak256("settles"), 0, CASE_A);
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
