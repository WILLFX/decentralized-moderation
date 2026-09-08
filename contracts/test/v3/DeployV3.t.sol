// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {DeployV3} from "../../script/DeployV3.s.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";
import {RulesetGovernor} from "../../src/v3/RulesetGovernor.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @title DeployV3 — the bring-up sequence, executed as a unit
/// @notice The wiring order lived only as `setUp()` in four test files, each of
///         which happened to get it right. This runs it once, as the script a
///         deployment would use, and then asserts every link — including by
///         breaking each one and checking `verify` names it.
contract DeployV3Test is Test {
    DeployV3 internal script;
    MockBZZ internal token;
    address internal governance;

    uint256 internal constant UNIT = 1e16;
    uint256 internal constant TIMELOCK = 2 days;

    function setUp() public {
        script = new DeployV3();
        token = new MockBZZ();
        governance = makeAddr("governance");
        vm.warp(1_000_000);
        vm.roll(1000);
    }

    function _config() internal view returns (DeployV3.Config memory c) {
        c.token = IERC20(address(token));
        c.governance = governance;
        c.minStake = 10 * UNIT;
        c.bondMin = 5 * UNIT;
        c.maturation = 3 days;
        c.exitCooldown = 7 days;
        c.timelockDelay = TIMELOCK;
        c.minTrackDecay = 0.5e18;
    }

    function _params() internal pure returns (Moderation.Params memory p) {
        p.blockTime = 5;
        p.commitWindow = 1200;
        p.revealWindow = 1200;
        p.challengeWindow = 43_200;
        p.lateWidenAt = 720;
        p.seedLag = 2;
        p.blockhashHorizon = 256;
        p.retryCooldown = 1 days;
        p.superQuorum = 16;
        p.lateWidenFactorBps = 15_000;
        p.drawBountyBps = 50;
        p.claimBountyBps = 100;
        p.reserveBps = 2000;
        p.maintenanceBps = 1000;
        p.lambda = 2 * uint128(UNIT);
        p.revealBond = 2 * uint128(UNIT);
        p.penaltyDebit = uint128(UNIT);
        p.challengeBond = 3 * uint128(UNIT);
        p.trackDecay = 0.95e18;
        p.feeBase = uint128(100 * UNIT);
        p.feePerTopic = uint128(10 * UNIT);
        p.threshold = type(uint256).max;
    }

    /// @dev The whole sequence, and the three separate waits it actually needs.
    function _bringUp() internal returns (DeployV3.Stack memory s) {
        s = script.deployAndPropose(_config());

        // Both capability grants wait their own timelock.
        vm.warp(block.timestamp + TIMELOCK);
        script.executeGrants(s);

        // The governor's timelock is a DIFFERENT one, and the first ruleset waits
        // it too. A deployment that assumed one wait covered both would fail here
        // with everything else already live.
        script.applyFirstRuleset(s, _params());
        (, uint256 eta,) = s.governor.pendingParamsProposal();
        vm.warp(eta);
        script.executeFirstRuleset(s, _params());

        // And only then does the deployer hand over.
        script.handOverGovernance(s, governance);
    }

    // =========================================================================

    function test_theBringUpSequenceRunsAsAUnitAndVerifies() public {
        DeployV3.Stack memory s = _bringUp();
        script.verify(s); // reverts naming the first broken link
        assertTrue(script.isWired(s));

        assertEq(address(s.mod.stakeReg()), address(s.reg));
        assertEq(address(s.mod.index()), address(s.idx));
        assertEq(s.mod.governor(), address(s.governor));
        assertEq(address(s.governor.moderation()), address(s.mod));
        assertEq(s.mod.paramsVersion(), 1, "a ruleset exists");
    }

    /// @dev The point of the script: a stack that is deployed but not granted is
    ///      not detectably broken until somebody's transaction reverts. Here it is
    ///      detectable at deploy time, by name.
    function test_verifyNamesAMissingCapability() public {
        DeployV3.Stack memory s = script.deployAndPropose(_config());
        // Grants proposed but never executed.
        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "StakeRegistry.MAY_CREATE"));
        script.verify(s);
        assertFalse(script.isWired(s));
    }

    function test_verifyNamesAMissingWriterCapability() public {
        DeployV3.Stack memory s = script.deployAndPropose(_config());
        vm.warp(block.timestamp + TIMELOCK);
        // Read the cap bits BEFORE the prank: a call in the argument expression
        // consumes it, and the execute then lands as the test contract.
        uint8 capBits = s.reg.MAY_CREATE() | s.reg.MAY_DISCHARGE();
        vm.prank(address(script)); // the deployer still holds registry governance
        s.reg.executeCaps(address(s.mod), capBits); // registry granted, index NOT

        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "IndexRegistry.writer"));
        script.verify(s);
    }

    /// @dev A fully wired stack with no ruleset. Every call into it reverts
    ///      `BadParams` at `submit`, which reads as a broken contract rather than
    ///      an incomplete deployment.
    function test_verifyNamesAMissingRuleset() public {
        DeployV3.Stack memory s = script.deployAndPropose(_config());
        vm.warp(block.timestamp + TIMELOCK);
        script.executeGrants(s);

        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "Moderation.paramsVersion"));
        script.verify(s);
    }

    /// @dev Both directions of the bind, because M2.6-F3's finding was exactly that
    ///      one held while the other did not.
    function test_verifyNamesAnUnboundGovernor() public {
        DeployV3.Stack memory s = _bringUp();
        // A governor that governs a different Moderation.
        RulesetGovernor other = new RulesetGovernor(governance, TIMELOCK);
        s.governor = other;

        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "Moderation.governor"));
        script.verify(s);
    }

    /// @dev M2.12 — a retired governor passes every OTHER check in `verify`: it
    ///      still reports the right `moderation`, and `Moderation` still names it
    ///      until the handover lands. This is the check that catches a stack whose
    ///      governor has moved on.
    function test_verifyNamesARetiredGovernor() public {
        DeployV3.Stack memory s = _bringUp();

        RulesetGovernor next = new RulesetGovernor(governance, TIMELOCK);
        vm.startPrank(governance);
        s.governor.acceptGovernance();
        next.intendModeration(s.mod);
        s.governor.proposeGovernorChange(address(next));
        (, uint256 eta,) = s.governor.pendingGovernorChangeProposal();
        vm.warp(eta);
        s.governor.executeGovernorChange(address(next));
        vm.stopPrank();

        // The stale Stack still names the old governor.
        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "Moderation.governor"));
        script.verify(s);

        // Point it at the successor and the stack verifies again — including that
        // the successor is not itself retired.
        s.governor = next;
        script.verify(s);
        assertTrue(script.isWired(s));
    }

    /// @dev M2.12 / D3-21 — the guidelines push, exercised as part of a deployment.
    function test_theFirstGuidelinesVersionPropagatesToModeration() public {
        DeployV3.Stack memory s = _bringUp();
        assertEq(s.mod.currentGuidelinesVersion(), 0, "none published is legal");
        script.verify(s);

        vm.startPrank(governance);
        s.governor.acceptGovernance();
        s.governor.proposeGuidelines(keccak256("v1"));
        (, uint256 eta,) = s.governor.pendingGuidelinesProposal();
        vm.warp(eta);
        s.governor.executeGuidelines(keccak256("v1"));
        vm.stopPrank();

        assertEq(s.governor.guidelinesVersion(), 1);
        assertEq(s.mod.currentGuidelinesVersion(), 1, "the push landed");
        script.verify(s);

        // And a case pins it.
        address submitter = makeAddr("s2");
        token.mint(submitter, 10_000 * UNIT);
        vm.prank(submitter);
        token.approve(address(s.mod), type(uint256).max);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("topic");
        vm.prank(submitter);
        uint256 id = s.mod.submit(keccak256("c"), keccak256("m"), topics, 1000 * UNIT);
        assertEq(s.mod.caseInfo(id).guidelinesVersion, 1);
    }

    function test_deployRefusesAZeroTokenOrGovernance() public {
        DeployV3.Config memory c = _config();
        c.token = IERC20(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "token"));
        script.deployAndPropose(c);

        c = _config();
        c.governance = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployV3.NotWired.selector, "governance"));
        script.deployAndPropose(c);
    }

    /// @dev The stack the script builds is not merely wired — it runs. A case
    ///      submitted against it reaches COMMIT, which is the first thing that
    ///      touches all four contracts at once.
    function test_theDeployedStackAcceptsARealCase() public {
        DeployV3.Stack memory s = _bringUp();

        address submitter = makeAddr("submitter");
        token.mint(submitter, 10_000 * UNIT);
        vm.prank(submitter);
        token.approve(address(s.mod), type(uint256).max);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("topic");

        vm.prank(submitter);
        uint256 caseId = s.mod.submit(keccak256("content"), keccak256("meta"), topics, 1000 * UNIT);

        assertEq(s.mod.caseInfo(caseId).phase, uint8(Moderation.Phase.COMMIT));
        assertEq(s.mod.caseInfo(caseId).paramsVersion, 1);
    }

    /// @dev Governance ends up where the config said, not with the deployer.
    function test_governanceLandsWithTheConfiguredOwner() public {
        DeployV3.Stack memory s = _bringUp();

        // All three use propose/accept, so the owner must claim them — which is
        // what proves the address is controlled before it holds authority.
        assertEq(s.reg.pendingGovernance(), governance);
        assertEq(s.idx.pendingGovernance(), governance);
        assertEq(s.governor.pendingGovernance(), governance);

        assertEq(s.governor.governance(), address(script), "not handed over until claimed");

        vm.startPrank(governance);
        s.reg.acceptGovernance();
        s.idx.acceptGovernance();
        s.governor.acceptGovernance();
        vm.stopPrank();

        assertEq(s.reg.governance(), governance);
        assertEq(s.idx.governance(), governance);
        assertEq(s.governor.governance(), governance);

        // And the deployer is out of the governor entirely.
        vm.prank(address(script));
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        s.governor.proposeParams(_params());
    }
}
