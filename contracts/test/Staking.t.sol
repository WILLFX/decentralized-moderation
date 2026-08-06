// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {StackDeployer} from "./base/StackDeployer.sol";

contract StakingTest is StackDeployer {
    StakeRegistry internal stakeReg;
    IndexRegistry internal indexReg;
    ModerationHarness internal mod;
    MockBZZ internal bzz;

    uint256 internal constant XBZZ = 1e16; // 16 decimals
    uint256 internal constant MIN_STAKE = 10 * XBZZ;
    uint256 internal constant ACTIVATION_DELAY = 7 days;
    uint256 internal constant EXIT_COOLDOWN = 7 days;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        bzz = new MockBZZ();
        (mod, stakeReg, indexReg) = _deployStack(bzz);
    }

    function _fund(address who, uint256 amount) internal {
        bzz.mint(who, amount);
        vm.prank(who);
        bzz.approve(address(stakeReg), type(uint256).max);
    }

    function _stakeActivate(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        stakeReg.stake(amount);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(who);
        // H-07: activated stake is only draw-eligible once duty capacity is
        // pledged. Pledge the full amount so these tests exercise weight changes.
        // Compute BEFORE the prank: an external call in the arg list eats it.
        uint256 units = amount / mod.getParams().riskPerSeat;
        vm.prank(who);
        stakeReg.setDutyUnits(units);
    }

    // --- staking / activation ------------------------------------------------

    function test_first_stake_below_min_reverts() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.BelowMinStake.selector);
        stakeReg.stake(MIN_STAKE - 1);
    }

    // H-07: the min-stake floor binds on CURRENT total, not a one-time flag. After
    // a full exit, re-staking below the floor must revert — closing the
    // stake -> full-exit -> stake-1-wei sub-minimum-identity split.
    function test_restake_below_min_after_full_exit_reverts() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        stakeReg.stake(MIN_STAKE);

        // Full exit and withdraw.
        vm.prank(alice);
        stakeReg.requestExit(MIN_STAKE);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(stakeReg.totalStakeOf(alice), 0, "fully exited");

        // Re-staking below the floor is now rejected (was allowed via the stale
        // `exists` flag).
        _fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.BelowMinStake.selector);
        stakeReg.stake(1);
    }

    function test_stake_is_pending_until_activated() public {
        _fund(alice, 100 * XBZZ);
        vm.prank(alice);
        stakeReg.stake(100 * XBZZ);

        // In the free bucket, but not draw-eligible yet. Two reasons now: the
        // activation delay (H-07 pledge aside), and M2.6-P0-3 — weight becomes
        // drawable only at the next eligibility-epoch boundary.
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ);
        _settleEpoch(stakeReg);
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "pending: not in tree");
        assertEq(stakeReg.totalEligibleWeight(), 0);

        // Cannot activate before the delay.
        vm.expectRevert(StakeRegistry.NotYetActivatable.selector);
        stakeReg.activate(alice);

        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(alice); // permissionless

        // H-07: activation alone no longer makes stake drawable. Capacity must be
        // pledged first — passive stake is never drafted into duty.
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "activated but not pledged: still not drawable");
        uint256 units = 100 * XBZZ / mod.getParams().riskPerSeat;
        vm.prank(alice);
        stakeReg.setDutyUnits(units);
        _settleEpoch(stakeReg); // P0-3: drawable from the next epoch
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ, "pledged: full weight in tree");
        assertEq(stakeReg.totalEligibleWeight(), 100 * XBZZ);
    }

    function test_topup_rearms_pending_keeps_activated_eligible() public {
        _stakeActivate(alice, 100 * XBZZ);
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ);

        // Top up: the new stake is pending; the already-activated 100 stays eligible.
        _fund(alice, 40 * XBZZ);
        vm.prank(alice);
        stakeReg.stake(40 * XBZZ);
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ, "top-up does not evict activated stake");
        assertEq(stakeReg.totalStakeOf(alice), 140 * XBZZ);

        // Just-in-time stake cannot be activated before its own delay.
        vm.expectRevert(StakeRegistry.NotYetActivatable.selector);
        stakeReg.activate(alice);

        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(alice);
        // Weight stays capped by the pledge until capacity is raised to match
        // (H-07): duty is opt-in at every size, not just at first stake.
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ, "still capped by the original pledge");
        uint256 units = 140 * XBZZ / mod.getParams().riskPerSeat;
        vm.prank(alice);
        stakeReg.setDutyUnits(units);
        assertEq(stakeReg.eligibleWeightOf(alice), 140 * XBZZ);
    }

    // H-07: duty is opt-in. Stake that never pledged capacity is never drawable,
    // so a spammer cannot conscript passive stakers into duty (and therefore
    // cannot expose them to no-show penalties).
    function test_unpledged_stake_is_never_drawable() public {
        _fund(alice, 100 * XBZZ);
        vm.prank(alice);
        stakeReg.stake(100 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(alice);

        assertEq(stakeReg.eligibleWeightOf(alice), 0, "activated but unpledged -> not in the draw pool");
        assertEq(stakeReg.totalEligibleWeight(), 0, "nothing drawable network-wide");
    }

    // H-07: selection weight is capped by pledged capacity, so a moderator can
    // never be drawn for more seats than its own stake can collateralize.
    function test_selection_weight_capped_by_pledged_capacity() public {
        _fund(alice, 100 * XBZZ);
        vm.prank(alice);
        stakeReg.stake(100 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        stakeReg.activate(alice);

        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        vm.prank(alice);
        stakeReg.setDutyUnits(3); // pledge 3 seats out of 10 affordable
        assertEq(stakeReg.eligibleWeightOf(alice), 3 * riskPerSeat, "weight == pledged capacity, not full stake");

        // Cannot pledge more than the stake can back.
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.InsufficientEligibleFree.selector);
        stakeReg.setDutyUnits(11);
    }

    // --- exit / withdraw -----------------------------------------------------

    function test_requestExit_excludes_from_draws_then_withdraw() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        stakeReg.requestExit(30 * XBZZ);

        // Excluded from draws immediately, but still in the free bucket.
        assertEq(stakeReg.eligibleWeightOf(alice), 70 * XBZZ, "exiting stake leaves the tree");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "still owned during cooldown");

        vm.expectRevert(StakeRegistry.CooldownNotElapsed.selector);
        vm.prank(alice);
        stakeReg.withdraw();

        vm.warp(vm.getBlockTimestamp() + EXIT_COOLDOWN);
        uint256 balBefore = bzz.balanceOf(alice);
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(bzz.balanceOf(alice) - balBefore, 30 * XBZZ);
        assertEq(stakeReg.totalStakeOf(alice), 70 * XBZZ);
        assertEq(stakeReg.eligibleWeightOf(alice), 70 * XBZZ);
    }

    function test_double_exit_reverts() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        stakeReg.requestExit(10 * XBZZ);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.ExitPending.selector);
        stakeReg.requestExit(10 * XBZZ);
    }

    function test_exit_over_free_reverts() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.InsufficientFree.selector);
        stakeReg.requestExit(101 * XBZZ);
    }

    // --- MIN_STAKE floor (§3) ------------------------------------------------

    function test_partial_exit_below_floor_reverts() public {
        _stakeActivate(alice, 15 * XBZZ); // total 15
        // Exiting 10 leaves 5 < MIN_STAKE(10): not a full exit, so blocked.
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.MinStakeFloor.selector);
        stakeReg.requestExit(10 * XBZZ);
    }

    function test_full_exit_below_floor_allowed() public {
        _stakeActivate(alice, 15 * XBZZ);
        // Exiting all 15 is a full exit (remaining 0): allowed even though < floor.
        vm.prank(alice);
        stakeReg.requestExit(15 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + EXIT_COOLDOWN);
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(stakeReg.totalStakeOf(alice), 0);
    }

    function test_partial_exit_leaving_exactly_floor_allowed() public {
        _stakeActivate(alice, 25 * XBZZ);
        vm.prank(alice);
        stakeReg.requestExit(15 * XBZZ); // leaves 10 == MIN_STAKE
        vm.warp(vm.getBlockTimestamp() + EXIT_COOLDOWN);
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(stakeReg.totalStakeOf(alice), 10 * XBZZ);
    }

    // --- §9.5 withdrawals never pausable -------------------------------------

    /// The contract exposes no admin, owner, or pause surface over exit/withdraw.
    /// After the cooldown, withdraw succeeds unconditionally from the moderator's
    /// own account — there is no code path that can gate it. (Re-asserted with
    /// governance live in M2-7.)
    function test_withdraw_has_no_admin_gate() public {
        _stakeActivate(alice, 50 * XBZZ);
        vm.prank(alice);
        stakeReg.requestExit(50 * XBZZ);
        vm.warp(vm.getBlockTimestamp() + EXIT_COOLDOWN);

        // No account — deployer, a would-be admin, anyone — can block it.
        vm.prank(alice);
        stakeReg.withdraw();
        assertEq(stakeReg.totalStakeOf(alice), 0);
    }

    // --- freeze exclusion + thaw (injected frozen state) ---------------------

    function test_frozen_excluded_from_draws_until_thaw() public {
        _stakeActivate(alice, 100 * XBZZ);
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ);

        // Commit 40 (free->committed), then a settlement freezes that slice.
        mod.__commit(alice, 0, 40 * XBZZ);
        assertEq(stakeReg.eligibleWeightOf(alice), 60 * XBZZ, "committed stake leaves the tree");

        uint256 until = vm.getBlockTimestamp() + 7 days;
        mod.__freeze(alice, 0, 40 * XBZZ, until); // committed 40 -> frozen

        // D6: the WHOLE moderator is excluded while frozen, not just the slice.
        assertEq(stakeReg.eligibleWeightOf(alice), 0, "fully excluded while frozen");
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ, "no stake lost to freeze");

        // Cannot thaw early.
        vm.expectRevert(StakeRegistry.NotFrozen.selector);
        stakeReg.thaw(alice);

        vm.warp(until);
        stakeReg.thaw(alice); // permissionless
        // Frozen returns to free; moderator re-enters the tree at full weight.
        assertEq(stakeReg.eligibleWeightOf(alice), 100 * XBZZ);
        assertEq(stakeReg.totalStakeOf(alice), 100 * XBZZ);
    }

    // --- partition + conservation fuzz (§9.1, §9.3) --------------------------

    /// A random sequence of stake/activate/exit/withdraw/freeze/commit/thaw over
    /// two moderators; after every step the §9.3 partition and the §9.1
    /// conservation identity must hold exactly.
    function testFuzz_partition_and_conservation(uint8[16] calldata ops, uint96[16] calldata amounts) public {
        address[2] memory actors = [alice, bob];
        // Pre-fund generously.
        for (uint256 i = 0; i < 2; i++) {
            bzz.mint(actors[i], 1_000_000 * XBZZ);
            vm.prank(actors[i]);
            bzz.approve(address(stakeReg), type(uint256).max);
        }

        for (uint256 i = 0; i < 16; i++) {
            address a = actors[i % 2];
            uint256 amt = (uint256(amounts[i]) % (500 * XBZZ)) + 1;
            uint8 op = ops[i] % 6;

            if (op == 0) {
                // stake (respect first-stake floor)
                if (stakeReg.totalStakeOf(a) == 0 && amt < MIN_STAKE) amt = MIN_STAKE;
                vm.prank(a);
                stakeReg.stake(amt);
            } else if (op == 1) {
                (,uint256 pending,,,,uint256 activatesAt,,,) = stakeReg.moderatorInfo(a);
                if (pending > 0 && vm.getBlockTimestamp() >= activatesAt) stakeReg.activate(a);
            } else if (op == 2) {
                (uint256 free,,,,,,uint256 exitAmount,,) = stakeReg.moderatorInfo(a);
                uint256 tot = stakeReg.totalStakeOf(a);
                if (exitAmount == 0 && amt <= free && (tot - amt == 0 || tot - amt >= MIN_STAKE)) {
                    vm.prank(a);
                    stakeReg.requestExit(amt);
                }
            } else if (op == 3) {
                (,,,,,,uint256 exitAmount, uint256 exitClaimableAt,) = stakeReg.moderatorInfo(a);
                uint256 tot = stakeReg.totalStakeOf(a);
                if (
                    exitAmount > 0 && vm.getBlockTimestamp() >= exitClaimableAt
                        && (tot - exitAmount == 0 || tot - exitAmount >= MIN_STAKE)
                ) {
                    vm.prank(a);
                    stakeReg.withdraw();
                }
            } else if (op == 4) {
                // commit eligible free (free -> committed); if already committed,
                // freeze that slice (committed -> frozen). Mirrors the real
                // commitVote -> settlement-freeze path.
                (uint256 free, uint256 pending, uint256 committed,,,,uint256 exitAmount,,) = stakeReg.moderatorInfo(a);
                if (committed > 0) {
                    mod.__freeze(a, 0, committed, vm.getBlockTimestamp() + 3 days);
                } else {
                    uint256 eligible = free > pending + exitAmount ? free - pending - exitAmount : 0;
                    if (amt <= eligible && amt > 0) mod.__commit(a, 0, amt);
                }
            } else {
                // advance time (lets activation delays / cooldowns / freezes elapse)
                vm.warp(vm.getBlockTimestamp() + 2 days);
            }

            _assertInvariants(actors);
        }
    }

    function _assertInvariants(address[2] memory actors) internal view {
        uint256 sumFree;
        uint256 sumCommitted;
        uint256 sumFrozen;
        for (uint256 i = 0; i < 2; i++) {
            (
                uint256 free,
                uint256 pending,
                uint256 committed,
                uint256 frozen,
                ,
                ,
                uint256 exitAmount,
                ,
            ) = stakeReg.moderatorInfo(actors[i]);
            // §9.3 partition: each bucket non-negative (uint) and pending/exit are subsets of free.
            assertLe(pending, free, "pending <= free");
            assertLe(exitAmount, free, "exitAmount <= free");
            sumFree += free;
            sumCommitted += committed;
            sumFrozen += frozen;
        }
        // Aggregate accounting matches per-moderator sums.
        assertEq(stakeReg.totalFreeStake(), sumFree, "totalFree == sum free");
        assertEq(stakeReg.totalCommittedStake(), sumCommitted, "totalCommitted == sum committed");
        assertEq(stakeReg.totalFrozenStake(), sumFrozen, "totalFrozen == sum frozen");
        // §9.1 conservation: stake custody is the REGISTRY's balance now.
        assertEq(
            bzz.balanceOf(address(stakeReg)),
            sumFree + sumCommitted + sumFrozen,
            "conservation: registry balance == staked buckets"
        );
    }
}
