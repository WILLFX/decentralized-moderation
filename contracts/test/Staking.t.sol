// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

contract StakingTest is Test {
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
        mod = new ModerationHarness(IERC20(address(bzz)));
    }

    function _fund(address who, uint256 amount) internal {
        bzz.mint(who, amount);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
    }

    function _stakeActivate(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        mod.stake(amount);
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        mod.activate(who);
    }

    // --- staking / activation ------------------------------------------------

    function test_first_stake_below_min_reverts() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        vm.expectRevert(Moderation.BelowMinStake.selector);
        mod.stake(MIN_STAKE - 1);
    }

    // H-07: the min-stake floor binds on CURRENT total, not a one-time flag. After
    // a full exit, re-staking below the floor must revert — closing the
    // stake -> full-exit -> stake-1-wei sub-minimum-identity split.
    function test_restake_below_min_after_full_exit_reverts() public {
        _fund(alice, MIN_STAKE);
        vm.prank(alice);
        mod.stake(MIN_STAKE);

        // Full exit and withdraw.
        vm.prank(alice);
        mod.requestExit(MIN_STAKE);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        mod.withdraw();
        assertEq(mod.totalStakeOf(alice), 0, "fully exited");

        // Re-staking below the floor is now rejected (was allowed via the stale
        // `exists` flag).
        _fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Moderation.BelowMinStake.selector);
        mod.stake(1);
    }

    function test_stake_is_pending_until_activated() public {
        _fund(alice, 100 * XBZZ);
        vm.prank(alice);
        mod.stake(100 * XBZZ);

        // In the free bucket, but not draw-eligible yet.
        assertEq(mod.totalStakeOf(alice), 100 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 0, "pending: not in tree");
        assertEq(mod.totalEligibleWeight(), 0);

        // Cannot activate before the delay.
        vm.expectRevert(Moderation.NotYetActivatable.selector);
        mod.activate(alice);

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        mod.activate(alice); // permissionless
        assertEq(mod.eligibleWeightOf(alice), 100 * XBZZ, "activated: full weight in tree");
        assertEq(mod.totalEligibleWeight(), 100 * XBZZ);
    }

    function test_topup_rearms_pending_keeps_activated_eligible() public {
        _stakeActivate(alice, 100 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 100 * XBZZ);

        // Top up: the new stake is pending; the already-activated 100 stays eligible.
        _fund(alice, 40 * XBZZ);
        vm.prank(alice);
        mod.stake(40 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 100 * XBZZ, "top-up does not evict activated stake");
        assertEq(mod.totalStakeOf(alice), 140 * XBZZ);

        // Just-in-time stake cannot be activated before its own delay.
        vm.expectRevert(Moderation.NotYetActivatable.selector);
        mod.activate(alice);

        vm.warp(block.timestamp + ACTIVATION_DELAY);
        mod.activate(alice);
        assertEq(mod.eligibleWeightOf(alice), 140 * XBZZ);
    }

    // --- exit / withdraw -----------------------------------------------------

    function test_requestExit_excludes_from_draws_then_withdraw() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        mod.requestExit(30 * XBZZ);

        // Excluded from draws immediately, but still in the free bucket.
        assertEq(mod.eligibleWeightOf(alice), 70 * XBZZ, "exiting stake leaves the tree");
        assertEq(mod.totalStakeOf(alice), 100 * XBZZ, "still owned during cooldown");

        vm.expectRevert(Moderation.CooldownNotElapsed.selector);
        vm.prank(alice);
        mod.withdraw();

        vm.warp(block.timestamp + EXIT_COOLDOWN);
        uint256 balBefore = bzz.balanceOf(alice);
        vm.prank(alice);
        mod.withdraw();
        assertEq(bzz.balanceOf(alice) - balBefore, 30 * XBZZ);
        assertEq(mod.totalStakeOf(alice), 70 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 70 * XBZZ);
    }

    function test_double_exit_reverts() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        mod.requestExit(10 * XBZZ);
        vm.prank(alice);
        vm.expectRevert(Moderation.ExitPending.selector);
        mod.requestExit(10 * XBZZ);
    }

    function test_exit_over_free_reverts() public {
        _stakeActivate(alice, 100 * XBZZ);
        vm.prank(alice);
        vm.expectRevert(Moderation.InsufficientFree.selector);
        mod.requestExit(101 * XBZZ);
    }

    // --- MIN_STAKE floor (§3) ------------------------------------------------

    function test_partial_exit_below_floor_reverts() public {
        _stakeActivate(alice, 15 * XBZZ); // total 15
        // Exiting 10 leaves 5 < MIN_STAKE(10): not a full exit, so blocked.
        vm.prank(alice);
        vm.expectRevert(Moderation.MinStakeFloor.selector);
        mod.requestExit(10 * XBZZ);
    }

    function test_full_exit_below_floor_allowed() public {
        _stakeActivate(alice, 15 * XBZZ);
        // Exiting all 15 is a full exit (remaining 0): allowed even though < floor.
        vm.prank(alice);
        mod.requestExit(15 * XBZZ);
        vm.warp(block.timestamp + EXIT_COOLDOWN);
        vm.prank(alice);
        mod.withdraw();
        assertEq(mod.totalStakeOf(alice), 0);
    }

    function test_partial_exit_leaving_exactly_floor_allowed() public {
        _stakeActivate(alice, 25 * XBZZ);
        vm.prank(alice);
        mod.requestExit(15 * XBZZ); // leaves 10 == MIN_STAKE
        vm.warp(block.timestamp + EXIT_COOLDOWN);
        vm.prank(alice);
        mod.withdraw();
        assertEq(mod.totalStakeOf(alice), 10 * XBZZ);
    }

    // --- §9.5 withdrawals never pausable -------------------------------------

    /// The contract exposes no admin, owner, or pause surface over exit/withdraw.
    /// After the cooldown, withdraw succeeds unconditionally from the moderator's
    /// own account — there is no code path that can gate it. (Re-asserted with
    /// governance live in M2-7.)
    function test_withdraw_has_no_admin_gate() public {
        _stakeActivate(alice, 50 * XBZZ);
        vm.prank(alice);
        mod.requestExit(50 * XBZZ);
        vm.warp(block.timestamp + EXIT_COOLDOWN);

        // No account — deployer, a would-be admin, anyone — can block it.
        vm.prank(alice);
        mod.withdraw();
        assertEq(mod.totalStakeOf(alice), 0);
    }

    // --- freeze exclusion + thaw (injected frozen state) ---------------------

    function test_frozen_excluded_from_draws_until_thaw() public {
        _stakeActivate(alice, 100 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 100 * XBZZ);

        // Commit 40 (free->committed), then a settlement freezes that slice.
        mod.__commit(alice, 40 * XBZZ);
        assertEq(mod.eligibleWeightOf(alice), 60 * XBZZ, "committed stake leaves the tree");

        uint256 until = block.timestamp + 7 days;
        mod.__freeze(alice, 40 * XBZZ, until); // committed 40 -> frozen

        // D6: the WHOLE moderator is excluded while frozen, not just the slice.
        assertEq(mod.eligibleWeightOf(alice), 0, "fully excluded while frozen");
        assertEq(mod.totalStakeOf(alice), 100 * XBZZ, "no stake lost to freeze");

        // Cannot thaw early.
        vm.expectRevert(Moderation.NotFrozen.selector);
        mod.thaw(alice);

        vm.warp(until);
        mod.thaw(alice); // permissionless
        // Frozen returns to free; moderator re-enters the tree at full weight.
        assertEq(mod.eligibleWeightOf(alice), 100 * XBZZ);
        assertEq(mod.totalStakeOf(alice), 100 * XBZZ);
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
            bzz.approve(address(mod), type(uint256).max);
        }

        for (uint256 i = 0; i < 16; i++) {
            address a = actors[i % 2];
            uint256 amt = (uint256(amounts[i]) % (500 * XBZZ)) + 1;
            uint8 op = ops[i] % 6;

            if (op == 0) {
                // stake (respect first-stake floor)
                if (mod.totalStakeOf(a) == 0 && amt < MIN_STAKE) amt = MIN_STAKE;
                vm.prank(a);
                mod.stake(amt);
            } else if (op == 1) {
                (,uint256 pending,,,,uint256 activatesAt,,,) = mod.moderatorInfo(a);
                if (pending > 0 && block.timestamp >= activatesAt) mod.activate(a);
            } else if (op == 2) {
                (uint256 free,,,,,,uint256 exitAmount,,) = mod.moderatorInfo(a);
                uint256 tot = mod.totalStakeOf(a);
                if (exitAmount == 0 && amt <= free && (tot - amt == 0 || tot - amt >= MIN_STAKE)) {
                    vm.prank(a);
                    mod.requestExit(amt);
                }
            } else if (op == 3) {
                (,,,,,,uint256 exitAmount, uint256 exitReqAt,) = mod.moderatorInfo(a);
                uint256 tot = mod.totalStakeOf(a);
                if (
                    exitAmount > 0 && block.timestamp >= exitReqAt + EXIT_COOLDOWN
                        && (tot - exitAmount == 0 || tot - exitAmount >= MIN_STAKE)
                ) {
                    vm.prank(a);
                    mod.withdraw();
                }
            } else if (op == 4) {
                // commit eligible free (free -> committed); if already committed,
                // freeze that slice (committed -> frozen). Mirrors the real
                // commitVote -> settlement-freeze path.
                (uint256 free, uint256 pending, uint256 committed,,,,uint256 exitAmount,,) = mod.moderatorInfo(a);
                if (committed > 0) {
                    mod.__freeze(a, committed, block.timestamp + 3 days);
                } else {
                    uint256 eligible = free > pending + exitAmount ? free - pending - exitAmount : 0;
                    if (amt <= eligible && amt > 0) mod.__commit(a, amt);
                }
            } else {
                // advance time (lets activation delays / cooldowns / freezes elapse)
                vm.warp(block.timestamp + 2 days);
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
            ) = mod.moderatorInfo(actors[i]);
            // §9.3 partition: each bucket non-negative (uint) and pending/exit are subsets of free.
            assertLe(pending, free, "pending <= free");
            assertLe(exitAmount, free, "exitAmount <= free");
            sumFree += free;
            sumCommitted += committed;
            sumFrozen += frozen;
        }
        // Aggregate accounting matches per-moderator sums.
        assertEq(mod.totalFreeStake(), sumFree, "totalFree == sum free");
        assertEq(mod.totalCommittedStake(), sumCommitted, "totalCommitted == sum committed");
        assertEq(mod.totalFrozenStake(), sumFrozen, "totalFrozen == sum frozen");
        // §9.1 conservation (no case pots yet): token balance == free + committed + frozen.
        assertEq(
            bzz.balanceOf(address(mod)),
            sumFree + sumCommitted + sumFrozen,
            "conservation: token balance == staked buckets"
        );
    }
}
