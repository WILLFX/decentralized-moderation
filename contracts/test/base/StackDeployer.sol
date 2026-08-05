// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {StakeRegistryHarness} from "../harnesses/StakeRegistryHarness.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {RulesetGovernor} from "../../src/RulesetGovernor.sol";
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
    /// Was `Moderation.timelockDelay`, hardcoded to 7 days before the M2.6 split.
    uint256 internal constant GOV_TIMELOCK = 7 days;
    /// M2.6-P0-3 eligibility-epoch cadence. 256 blocks is the natural ceiling: a
    /// seed older than that has no `blockhash` left anyway (D4), so a longer epoch
    /// could not keep a window valid. Must exceed `seedLag + REALIZE_SLACK` (2 + 64)
    /// or no window would ever fit.
    uint256 internal constant REG_EPOCH_BLOCKS = 256;
    /// M2.6-K-5: the registry's immutable floor on a single track-decay write.
    /// 0.9 WAD admits the shipped 0.95 and any ordinary recalibration below it,
    /// and bounds one write to a 10% shave. See `StakeRegistry.minTrackDecay` for
    /// why no admissible floor bounds the COMPOUNDED case.
    uint256 internal constant REG_MIN_TRACK_DECAY = (1e18 * 9) / 10;

    /// The governor deployed alongside the most recent `_deployStack` call, for
    /// suites that drive governance. M2.6 moved ruleset authoring out of
    /// `Moderation` (EIP-170), so proposals go here.
    RulesetGovernor internal governor;

    function _deployStack(MockBZZ bzz)
        internal
        returns (ModerationHarness m, StakeRegistryHarness sr, IndexRegistry ir)
    {
        (sr, ir) = _deployRegistries(bzz);
        (m, governor) = _deployLogic(bzz, sr, ir);
        _authorizeLogic(sr, ir, address(m));
    }

    /// Deploy the game contract and its governor. The references are circular at
    /// construction — `Moderation.governor` is immutable and the governor must
    /// know what it governs — so the binding is a second step, exactly as a real
    /// deployment does it.
    function _deployLogic(MockBZZ bzz, StakeRegistryHarness sr, IndexRegistry ir)
        internal
        returns (ModerationHarness m, RulesetGovernor g)
    {
        g = new RulesetGovernor(address(this), GOV_TIMELOCK);
        m = new ModerationHarness(IERC20(address(bzz)), sr, ir, address(g));
        g.bindModeration(m);
    }

    function _deployRegistries(MockBZZ bzz) internal returns (StakeRegistryHarness sr, IndexRegistry ir) {
        sr = new StakeRegistryHarness(
            IERC20(address(bzz)),
            REG_TIMELOCK,
            REG_MIN_STAKE,
            REG_ACTIVATION,
            REG_COOLDOWN,
            REG_RISK_PER_SEAT,
            REG_EPOCH_BLOCKS,
            REG_MIN_TRACK_DECAY
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

    /// Cross an eligibility-epoch boundary and apply everything staged before it
    /// (M2.6-P0-3). Weight changes only become drawable at a boundary, so any
    /// fixture that stakes/pledges and then expects to be drawn must do this.
    function _settleEpoch(StakeRegistry sr) internal {
        vm.roll(vm.getBlockNumber() + REG_EPOCH_BLOCKS);
        sr.advanceEpoch(type(uint256).max);
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
