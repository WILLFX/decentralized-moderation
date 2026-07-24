// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @notice Stands up the three-contract stack the way a real deployment does
///         (M2.5 port): registries first, then the logic contract, then a
///         timelocked `proposeLogic`/`executeLogic` on BOTH registries.
///
///         Every suite deploys through here so the authorization step can never
///         be silently skipped — an unauthorized logic contract fails closed
///         (`NotLogic`) rather than degrading quietly.
abstract contract StackDeployer is Test {
    uint256 internal constant REG_TIMELOCK = 7 days;
    uint256 internal constant REG_MIN_STAKE = 10 * 1e16;
    uint256 internal constant REG_ACTIVATION = 7 days;
    uint256 internal constant REG_COOLDOWN = 7 days;
    /// Must match `Params.riskPerSeat`: the registry sizes draw eligibility by it
    /// and the logic contract locks by it. See DEVIATIONS.md (M2.5 port).
    uint256 internal constant REG_RISK_PER_SEAT = 10 * 1e16;

    function _deployStack(MockBZZ bzz)
        internal
        returns (ModerationHarness m, StakeRegistry sr, IndexRegistry ir)
    {
        (sr, ir) = _deployRegistries(bzz);
        m = new ModerationHarness(IERC20(address(bzz)), sr, ir);
        _authorizeLogic(sr, ir, address(m));
    }

    function _deployRegistries(MockBZZ bzz) internal returns (StakeRegistry sr, IndexRegistry ir) {
        sr = new StakeRegistry(
            IERC20(address(bzz)), REG_TIMELOCK, REG_MIN_STAKE, REG_ACTIVATION, REG_COOLDOWN, REG_RISK_PER_SEAT
        );
        ir = new IndexRegistry(REG_TIMELOCK);
    }

    /// Authorize `logic` on both registries after the timelock. The previously
    /// authorized logic is deliberately NOT revoked (handover window).
    function _authorizeLogic(StakeRegistry sr, IndexRegistry ir, address logic) internal {
        sr.proposeLogic(logic);
        ir.proposeLogic(logic);
        vm.warp(block.timestamp + REG_TIMELOCK);
        sr.executeLogic();
        ir.executeLogic();
    }

    /// Two-contract conservation (M2.5 port, §9.1). Stake custody moved to the
    /// registry, so the identity is now a pair: the logic contract holds only pot
    /// money, and the registry holds exactly the staked buckets.
    function _assertStackConservation(ModerationHarness m, StakeRegistry sr, MockBZZ bzz) internal view {
        assertEq(
            bzz.balanceOf(address(m)),
            m.openPotsTotal() + m.totalPendingBond() + m.totalPendingPayout() + m.totalSettling(),
            "conservation: logic balance == live pots + pending bond + pending payout + in-flight settlement"
        );
        assertEq(
            bzz.balanceOf(address(sr)),
            sr.stakeBuckets(),
            "conservation: registry balance == free + committed + frozen"
        );
    }
}
