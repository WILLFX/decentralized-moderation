// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {StakeRegistryHarness} from "../harnesses/StakeRegistryHarness.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// # Rule for all test code in this repo: never read `block.timestamp` or
/// # `block.number` directly. Use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`.
///
/// The suite builds with `via_ir = true` (EIP-170 — see GAS_BUDGETS.md). solc
/// correctly treats TIMESTAMP and NUMBER as invariant within a transaction, so
/// the IR optimizer hoists them and caches the value across calls. `vm.warp` and
/// `vm.roll` are cheatcodes it cannot see, so a test that reads the clock, warps,
/// and reads again silently gets the STALE value — and then mis-sequences without
/// failing loudly. It cost ~20 tests when the pipeline was switched.
///
/// The cheatcode getters are external staticcalls, so they cannot be folded.
///
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
    /// The registry's DUTY UNIT. `Moderation.Params.riskPerSeat` (what a case
    /// locks per seat) may be lower, but never higher — `_validateParams` and the
    /// Moderation constructor both reject that. See DEVIATIONS.md D-13.
    uint256 internal constant REG_RISK_PER_SEAT = 10 * 1e16;

    function _deployStack(MockBZZ bzz)
        internal
        returns (ModerationHarness m, StakeRegistryHarness sr, IndexRegistry ir)
    {
        (sr, ir) = _deployRegistries(bzz);
        m = new ModerationHarness(IERC20(address(bzz)), sr, ir);
        _authorizeLogic(sr, ir, address(m));
    }

    function _deployRegistries(MockBZZ bzz) internal returns (StakeRegistryHarness sr, IndexRegistry ir) {
        sr = new StakeRegistryHarness(
            IERC20(address(bzz)), REG_TIMELOCK, REG_MIN_STAKE, REG_ACTIVATION, REG_COOLDOWN, REG_RISK_PER_SEAT
        );
        ir = new IndexRegistry(REG_TIMELOCK);
    }

    /// Authorize `logic` on both registries after the timelock. The previously
    /// authorized logic is deliberately NOT revoked (handover window).
    function _authorizeLogic(StakeRegistry sr, IndexRegistry ir, address logic) internal {
        sr.proposeLogic(logic);
        ir.proposeLogic(logic);
        vm.warp(vm.getBlockTimestamp() + REG_TIMELOCK);
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
