// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

contract StakesTest is Test {
    StakeRegistry reg;
    MockBZZ token;

    address constant CASES = address(0xCA5E5);
    uint256 constant STAKE = 10e16;
    uint256 constant FREEZE = 8 days;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        reg = new StakeRegistry(address(token), STAKE);
        reg.setModeration(CASES);

        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            token.mint(a, STAKE * 10);
            vm.prank(a);
            token.approve(address(reg), type(uint256).max);
        }
        vm.warp(ts);
    }

    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function _stake(address a) internal {
        vm.prank(a);
        reg.stake();
    }

    // -----------------------------------------------------------------

    function test_stakeIsFixedSizeAndCounted() public {
        assertEq(reg.stakedCount(), 0);
        _stake(alice);
        assertTrue(reg.isActive(alice));
        assertEq(reg.stakedCount(), 1, "eligibility bits read this");
        assertEq(token.balanceOf(address(reg)), STAKE);

        vm.prank(alice);
        vm.expectRevert(StakeRegistry.AlreadyStaked.selector);
        reg.stake();
    }

    /// @dev §2 — the stake is never taken. A freeze makes it idle, not gone.
    function test_freezeTakesTimeNotMoney() public {
        _stake(alice);
        uint256 held = token.balanceOf(address(reg));

        vm.prank(CASES);
        reg.settle(alice, true, FREEZE);

        assertTrue(reg.isFrozen(alice));
        assertEq(token.balanceOf(address(reg)), held, "not one unit moved");
        assertEq(reg.totalFrozen(alice), FREEZE);
    }

    /// @dev The property the previous design got wrong: three losses must cost
    ///      the same total whatever order and spacing they settle in. Here the
    ///      same three durations are applied back to back in one case and spread
    ///      across time in the other.
    function test_freezesAreAdditiveRegardlessOfOrder() public {
        _stake(alice);
        _stake(bob);

        // alice: all three at once
        vm.startPrank(CASES);
        reg.settle(alice, true, 3 days);
        reg.settle(alice, true, 5 days);
        reg.settle(alice, true, 8 days);
        vm.stopPrank();

        // bob: the same three, in a different order, spread out — and with the
        // earlier ones fully served before the next lands
        vm.prank(CASES);
        reg.settle(bob, true, 8 days);
        _wait(9 days);
        vm.prank(CASES);
        reg.settle(bob, true, 3 days);
        _wait(4 days);
        vm.prank(CASES);
        reg.settle(bob, true, 5 days);

        assertEq(reg.totalFrozen(alice), 16 days);
        assertEq(reg.totalFrozen(bob), 16 days, "same total, any order");
    }

    /// @dev The exact second a freeze ends. A freeze of `d` starting at `T` runs
    ///      out AT `T + d`, not one second later — so `isFrozen` is
    ///      `frozenUntil > now`, and mutation testing found that no test pinned
    ///      the boundary. Three surviving mutants, all the same off-by-one.
    function test_freezeExpiresAtTheBoundaryNotAfterIt() public {
        _stake(alice);
        uint256 start = ts;
        vm.prank(CASES);
        reg.settle(alice, true, FREEZE);
        assertEq(reg.frozenUntil(alice), start + FREEZE);

        vm.warp(start + FREEZE - 1);
        assertTrue(reg.isFrozen(alice), "still frozen one second before");
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.IsFrozen.selector);
        reg.withdraw();

        vm.warp(start + FREEZE);
        assertFalse(reg.isFrozen(alice), "free exactly at the boundary");
        vm.prank(alice);
        reg.withdraw();
    }

    /// @dev And the same boundary on the ACCUMULATION side: a freeze landing
    ///      exactly as the previous one ends must start from now, not extend a
    ///      lapsed deadline.
    function test_freezeLandingExactlyAtExpiryStartsFresh() public {
        _stake(alice);
        uint256 start = ts;
        vm.prank(CASES);
        reg.settle(alice, true, 3 days);

        vm.warp(start + 3 days);
        vm.prank(CASES);
        reg.settle(alice, true, 5 days);
        assertEq(reg.frozenUntil(alice), start + 3 days + 5 days);
        assertEq(reg.totalFrozen(alice), 8 days);
    }

    function test_frozenModeratorCannotWithdraw() public {
        _stake(alice);
        vm.prank(CASES);
        reg.settle(alice, true, FREEZE);

        vm.prank(alice);
        vm.expectRevert(StakeRegistry.IsFrozen.selector);
        reg.withdraw();

        _wait(FREEZE + 1);
        vm.prank(alice);
        reg.withdraw();
        assertFalse(reg.isActive(alice));
        assertEq(reg.stakedCount(), 0);
        assertEq(token.balanceOf(alice), STAKE * 10, "stake returned in full");
    }

    /// @dev The guard the spec needs and does not state. Without it, commit then
    ///      withdraw before settlement escapes the only penalty the design has.
    function test_cannotWithdrawWithAnOpenVote() public {
        _stake(alice);
        vm.prank(CASES);
        reg.noteCommit(alice);

        vm.prank(alice);
        vm.expectRevert(StakeRegistry.HasOpenVotes.selector);
        reg.withdraw();

        vm.prank(CASES);
        reg.settle(alice, false, FREEZE);

        vm.prank(alice);
        reg.withdraw();
        assertFalse(reg.isActive(alice));
    }

    function test_coherentSettlementCostsNothing() public {
        _stake(alice);
        vm.prank(CASES);
        reg.noteCommit(alice);
        vm.prank(CASES);
        reg.settle(alice, false, FREEZE);

        assertFalse(reg.isFrozen(alice));
        assertEq(reg.totalFrozen(alice), 0);
        assertEq(reg.openVotes(alice), 0);
    }

    function test_unlimitedConcurrency() public {
        _stake(alice);
        vm.startPrank(CASES);
        for (uint256 i; i < 500; ++i) reg.noteCommit(alice);
        vm.stopPrank();
        // §2: nothing reserves, encumbers or refuses. 500 open votes on one stake.
        assertEq(reg.openVotes(alice), 500);
    }

    function test_onlyModerationMayFreeze() public {
        _stake(alice);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotModeration.selector);
        reg.settle(alice, true, FREEZE);

        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotModeration.selector);
        reg.noteCommit(alice);
    }

    function test_moderationLinkIsSetOnce() public {
        vm.expectRevert(StakeRegistry.AlreadySet.selector);
        reg.setModeration(address(0xDEAD));

        StakeRegistry fresh = new StakeRegistry(address(token), STAKE);
        vm.prank(bob);
        vm.expectRevert(StakeRegistry.NotDeployer.selector);
        fresh.setModeration(address(0xDEAD));
    }
}
