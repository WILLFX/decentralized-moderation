// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";
import {RulesetGovernor} from "../../src/v3/RulesetGovernor.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @title RulesetGovernor (v3) — M2.11 suite
/// @notice Tests marked MUTATION were verified by removing the named property from
///         the source and confirming this test goes red.
contract RulesetGovernorTest is Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    IndexRegistry internal idx;
    Moderation internal mod;
    RulesetGovernor internal gov;

    address internal owner; // governance of the governor
    address internal submitter;
    address internal stranger;

    uint256 internal constant UNIT = 1e16;
    uint256 internal constant MIN_STAKE = 10 * UNIT;
    uint256 internal constant BOND_MIN = 5 * UNIT;
    uint256 internal constant MATURATION = 3 days;
    uint256 internal constant EXIT_COOLDOWN = 7 days;
    uint256 internal constant TIMELOCK = 2 days;
    uint256 internal constant MIN_TRACK_DECAY = 0.5e18;

    uint32 internal constant SEED_LAG = 2;
    uint128 internal constant LAMBDA = 2 * uint128(UNIT);
    uint256 internal constant FEE = 1000 * UNIT;
    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;

    bytes32[] internal topics;

    function setUp() public {
        owner = makeAddr("owner");
        submitter = makeAddr("submitter");
        stranger = makeAddr("stranger");

        token = new MockBZZ();

        vm.prank(owner);
        reg = new StakeRegistry(
            IERC20(address(token)), MIN_STAKE, BOND_MIN, MATURATION, EXIT_COOLDOWN, TIMELOCK, MIN_TRACK_DECAY
        );
        vm.prank(owner);
        idx = new IndexRegistry(TIMELOCK);

        // The governor exists BEFORE Moderation, because Moderation must name its
        // governor at construction and `bindModeration` requires the naming to be
        // mutual. This is the deploy order the script encodes.
        vm.prank(owner);
        gov = new RulesetGovernor(owner, TIMELOCK);

        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), address(gov));

        vm.prank(owner);
        gov.bindModeration(mod);

        uint8 bits = reg.MAY_CREATE() | reg.MAY_DISCHARGE();
        vm.prank(owner);
        reg.proposeCaps(address(mod), bits);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        reg.executeCaps(address(mod), bits);

        vm.prank(owner);
        idx.proposeWriter(address(mod), true);
        (,, uint256 wEta,) = idx.pendingWriterProposal();
        vm.warp(wEta);
        vm.prank(owner);
        idx.executeWriter();

        // The first ruleset goes through the governor like every later one.
        _proposeAndExecute(_params(LAMBDA));

        topics.push(keccak256("topic-a"));
        token.mint(submitter, 1_000_000 * UNIT);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);

        vm.roll(1000);
    }

    // --- fixture --------------------------------------------------------------

    function _params(uint128 lambda) internal pure returns (Moderation.Params memory p) {
        p.blockTime = 5;
        p.commitWindow = 1200;
        p.revealWindow = 1200;
        p.challengeWindow = 43_200;
        p.lateWidenAt = 720;
        p.seedLag = SEED_LAG;
        p.blockhashHorizon = 256;
        p.retryCooldown = 1 days;
        p.superQuorum = 16;
        p.lateWidenFactorBps = 15_000;
        p.drawBountyBps = 50;
        p.claimBountyBps = 100;
        p.reserveBps = 2000;
        p.maintenanceBps = 1000;
        p.lambda = lambda;
        p.revealBond = 2 * uint128(UNIT);
        p.penaltyDebit = 1 * uint128(UNIT);
        p.challengeBond = 3 * uint128(UNIT);
        p.trackDecay = 0.95e18;
        p.feeBase = uint128(100 * UNIT);
        p.feePerTopic = uint128(10 * UNIT);
        p.threshold = type(uint256).max;
    }

    function _proposeAndExecute(Moderation.Params memory p) internal returns (uint32 v) {
        vm.prank(owner);
        gov.proposeParams(p);
        (, uint256 eta,) = gov.pendingParamsProposal();
        vm.warp(eta);
        vm.prank(owner);
        v = gov.executeParams(p);
    }

    function _moderator(uint256 i, uint256 bond) internal returns (address a) {
        a = makeAddr(string(abi.encodePacked("mod", vm.toString(i))));
        if (reg.stateOf(a) != StakeRegistry.State.NONE) return a;
        token.mint(a, MIN_STAKE + bond);
        vm.startPrank(a);
        token.approve(address(reg), type(uint256).max);
        reg.stake(bond);
        vm.stopPrank();
        vm.warp(block.timestamp + MATURATION + 1);
    }

    function _submit(string memory content) internal returns (uint256 caseId) {
        vm.prank(submitter);
        caseId = mod.submit(keccak256(bytes(content)), keccak256("meta"), topics, FEE);
    }

    function _commit(uint256 caseId, address a) internal {
        Moderation.Case memory c = mod.caseInfo(caseId);
        bytes32 h = mod.commitHash(caseId, c.round, c.paramsVersion, a, APPROVE, keccak256("s"));
        vm.prank(a);
        mod.commit(caseId, h);
    }

    // =========================================================================
    // The asymmetry this contract exists to close
    // =========================================================================

    /// @dev §10: `StakeRegistry` timelocks everything a governor can do;
    ///      `Moderation.applyParams` took effect immediately. After M2.11 nobody
    ///      but this governor can reach `applyParams` at all.
    function test_moderationTakesParametersOnlyFromTheGovernor() public {
        Moderation.Params memory p = _params(LAMBDA);

        vm.prank(owner);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyParams(p);

        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyParams(p);

        assertEq(mod.governor(), address(gov), "the governor is the only route in");
    }

    /// ACCEPTANCE 2a — a proposed change is VISIBLE and INERT until `eta`.
    ///
    /// MUTATION: drop the `block.timestamp < pp.eta` check in `executeParams`.
    function test_aProposedChangeIsVisibleAndInertUntilEta() public {
        uint32 before = mod.paramsVersion();
        Moderation.Params memory p = _params(3 * LAMBDA);

        vm.prank(owner);
        gov.proposeParams(p);

        // Visible.
        (bytes32 h, uint256 eta, bool exists) = gov.pendingParamsProposal();
        assertTrue(exists, "the proposal is observable");
        assertEq(h, gov.paramsHash(p), "and it is observable as WHAT was proposed");
        assertEq(eta, block.timestamp + TIMELOCK);

        // Inert.
        assertEq(mod.paramsVersion(), before, "nothing has moved in Moderation");
        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.TimelockNotElapsed.selector);
        gov.executeParams(p);
        assertEq(mod.paramsVersion(), before, "still nothing");

        // And then it lands.
        vm.warp(eta);
        vm.prank(owner);
        uint32 v = gov.executeParams(p);
        assertEq(v, before + 1, "a new version");
        assertEq(mod.paramsAt(v).lambda, 3 * LAMBDA, "carrying the proposed values");
    }

    /// ACCEPTANCE 2b — I27 ACROSS a parameter change. This is the property that
    /// makes the asymmetry a governance risk rather than a correctness defect: a
    /// case pins its parameters at submission, so a change moves the next case and
    /// never a live one.
    ///
    /// MUTATION: read `paramBlocks[paramsVersion]` (the live block) in `_p`.
    function test_i27_aCaseSubmittedBeforeTheChangeSettlesUnderTheOldParameters() public {
        address mBefore = _moderator(1, BOND_MIN + 100 * UNIT);
        address mAfter = _moderator(2, BOND_MIN + 100 * UNIT);

        uint256 caseBefore = _submit("before");
        assertEq(mod.caseInfo(caseBefore).paramsVersion, 1);

        // Change LAMBDA — the liability a commit takes — and land it.
        uint32 v2 = _proposeAndExecute(_params(4 * LAMBDA));
        assertEq(v2, 2);

        uint256 caseAfter = _submit("after");
        assertEq(mod.caseInfo(caseAfter).paramsVersion, 2, "the NEXT case moves");
        assertEq(mod.caseInfo(caseBefore).paramsVersion, 1, "the live one does not");

        vm.roll(block.number + SEED_LAG + 1);

        // The observable consequence, not just the pinned number: what each case
        // actually charges a moderator to commit.
        _commit(caseBefore, mBefore);
        assertEq(reg.liabilitiesOf(mBefore), LAMBDA, "the old case charges the OLD lambda");

        _commit(caseAfter, mAfter);
        assertEq(reg.liabilitiesOf(mAfter), 4 * LAMBDA, "the new case charges the new one");
    }

    // =========================================================================
    // §3 — execute NAMES what it executes
    // =========================================================================

    /// ACCEPTANCE 3 — the swap defence.
    ///
    /// MUTATION: drop the `keccak256(abi.encode(p)) != pp.hash` check.
    function test_executeRefusesParametersThatAreNotTheOnesPending() public {
        Moderation.Params memory queued = _params(3 * LAMBDA);
        Moderation.Params memory other = _params(9 * LAMBDA);

        vm.prank(owner);
        gov.proposeParams(queued);
        (, uint256 eta,) = gov.pendingParamsProposal();
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ProposalMismatch.selector);
        gov.executeParams(other);

        // The one that IS pending still works, so the check discriminates rather
        // than just refusing.
        vm.prank(owner);
        gov.executeParams(queued);
        assertEq(mod.paramsAt(mod.paramsVersion()).lambda, 3 * LAMBDA);
    }

    /// @dev The multisig scenario in full: signer A queues X, signer B replaces it
    ///      with Y, and an approval given for X must not execute Y. Two independent
    ///      properties hold — the eta resets (so Y waits its own full delay in the
    ///      open), and an execute naming X reverts (so the approval cannot be
    ///      redirected even after the wait).
    function test_aReplacementResetsTheEtaAndCannotBeExecutedUnderTheOldApproval() public {
        Moderation.Params memory x = _params(3 * LAMBDA);
        Moderation.Params memory y = _params(9 * LAMBDA);

        vm.prank(owner);
        gov.proposeParams(x);
        (, uint256 etaX,) = gov.pendingParamsProposal();

        vm.warp(block.timestamp + TIMELOCK / 2); // halfway through X's wait
        vm.prank(owner);
        gov.proposeParams(y);
        (bytes32 hY, uint256 etaY,) = gov.pendingParamsProposal();

        assertEq(hY, gov.paramsHash(y), "Y is what is pending now");
        assertGt(etaY, etaX, "and it did NOT inherit X's elapsed time");
        assertEq(etaY, block.timestamp + TIMELOCK, "it waits its own full delay, in the open");

        // At X's original eta, Y is still inert...
        vm.warp(etaX);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.TimelockNotElapsed.selector);
        gov.executeParams(y);

        // ...and after Y's eta, an approval that named X still cannot execute Y.
        vm.warp(etaY);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ProposalMismatch.selector);
        gov.executeParams(x);
    }

    /// MUTATION: leave the pending record in place after a successful execute.
    function test_aProposalExecutesAtMostOnce() public {
        Moderation.Params memory p = _params(3 * LAMBDA);
        _proposeAndExecute(p);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        gov.executeParams(p);
    }

    function test_cancelClearsTheProposal() public {
        Moderation.Params memory p = _params(3 * LAMBDA);
        vm.prank(owner);
        gov.proposeParams(p);
        vm.prank(owner);
        gov.cancelParams();

        (,, bool exists) = gov.pendingParamsProposal();
        assertFalse(exists);

        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        gov.executeParams(p);
    }

    /// MUTATION: drop `onlyGovernance` from any of the four parameter entry points.
    function test_everyParameterPathIsGovernanceOnly() public {
        Moderation.Params memory p = _params(3 * LAMBDA);

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.proposeParams(p);

        vm.prank(owner);
        gov.proposeParams(p);

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.cancelParams();

        (, uint256 eta,) = gov.pendingParamsProposal();
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.executeParams(p);
    }

    // =========================================================================
    // Validation — as well as Moderation's, never instead of it
    // =========================================================================

    /// @dev §10's one hard bound, rejected at PROPOSE rather than after the wait.
    ///
    /// MUTATION: drop the `cb > seedLag + blockhashHorizon` check in the governor.
    ///           `Moderation` still catches it — but only at execute, after the
    ///           full timelock, which is the failure mode this duplication exists
    ///           to prevent.
    function test_s10_theSeedHorizonBoundIsRejectedAtProposeTime() public {
        Moderation.Params memory p = _params(LAMBDA);
        p.commitWindow = 100_000; // 20,000 blocks at 5s, far past seedLag + horizon

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.CommitWindowExceedsSeedHorizon.selector);
        gov.proposeParams(p);
    }

    /// @dev The bound is enforced BELOW the governor too, and that is the point of
    ///      §2 of the order: a replacement governor cannot bypass it. This asserts
    ///      the lower layer independently of the governor's copy.
    function test_s10_theBoundAlsoHoldsOneLayerDownWhereAGovernorCannotBypassIt() public {
        Moderation.Params memory p = _params(LAMBDA);
        p.commitWindow = 100_000;

        // Called as the governor would, straight into Moderation.
        vm.prank(address(gov));
        vm.expectRevert(Moderation.CommitWindowExceedsSeedHorizon.selector);
        mod.applyParams(p);
    }

    /// @dev **The boundary, and why the test above was not enough.**
    ///
    ///      `test_s10_theSeedHorizonBoundIsRejectedAtProposeTime` uses a commit
    ///      window of 20,000 blocks against a limit of 258. That is so far past the
    ///      bound that a WRONG bound rejects it too — mutation M26 replaces
    ///      `seedLag + blockhashHorizon` with `blockhashHorizon - seedLag` and the
    ///      test stays green, because 20,000 exceeds 254 just as surely as 258.
    ///      A test that passes while the invariant happens to hold is not a test of
    ///      the invariant.
    ///
    ///      258 blocks is `SEED_LAG (2) + BLOCKHASH_HORIZON (256)` exactly. It must
    ///      be ACCEPTED — the seed survives its own commit window by one block — and
    ///      259 must not. Only the correct expression separates those two.
    ///
    /// MUTATION: M26 — `blockhashHorizon - seedLag` in either layer.
    function test_s10_theSeedHorizonBoundIsExactAtItsLimit() public {
        Moderation.Params memory p = _params(LAMBDA);
        p.commitWindow = 1290; // 258 blocks at 5s == seedLag + blockhashHorizon

        vm.prank(owner);
        gov.proposeParams(p); // accepted at the limit
        (, uint256 eta,) = gov.pendingParamsProposal();
        vm.warp(eta);
        vm.prank(owner);
        uint32 v = gov.executeParams(p);
        assertEq(mod.paramsAt(v).commitWindow, 1290, "and the lower layer agrees at the limit");

        p.commitWindow = 1295; // 259 blocks — one past it
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.CommitWindowExceedsSeedHorizon.selector);
        gov.proposeParams(p);
    }

    /// @dev The window is converted with a CEILING, so a window that does not divide
    ///      evenly still gets the block it actually spills into. Flooring hands back
    ///      a commit window whose last partial block reads an expired seed.
    ///
    ///      1,291 seconds at 5s is 258.2 blocks: ceiling 259 (over the bound, must
    ///      be refused), floor 258 (at the bound, wrongly accepted). Only this
    ///      remainder distinguishes them.
    ///
    /// MUTATION: M27 — integer division without the `+ blockTime - 1`.
    function test_s10_theBlockCountCeilsRatherThanFloors() public {
        Moderation.Params memory p = _params(LAMBDA);
        p.commitWindow = 1291;

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.CommitWindowExceedsSeedHorizon.selector);
        gov.proposeParams(p);
    }

    function test_aMalformedRulesetIsRejectedAtProposeTime() public {
        Moderation.Params memory p = _params(LAMBDA);
        p.blockTime = 0;
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        gov.proposeParams(p);

        p = _params(LAMBDA);
        p.drawBountyBps = 9000; // the four shares would reach 10,000 bps
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        gov.proposeParams(p);

        p = _params(LAMBDA);
        p.trackDecay = 1e18;
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.BadParams.selector);
        gov.proposeParams(p);
    }

    // =========================================================================
    // §4.1 — guidelines
    // =========================================================================

    /// ACCEPTANCE 4a — monotonic, never reused, never decreasing.
    ///
    /// MUTATION: assign rather than increment `guidelinesVersion`.
    function test_s4_1_guidelinesVersionIsMonotonic() public {
        assertEq(gov.guidelinesVersion(), 0, "no version until one is published");

        bytes32 a = keccak256("text-a");
        bytes32 b = keccak256("text-b");

        assertEq(_publishGuidelines(a), 1);
        assertEq(_publishGuidelines(b), 2);

        // Re-publishing the SAME text still earns a new version: the version names
        // an epoch of the dataset, not a document.
        assertEq(_publishGuidelines(a), 3);

        assertEq(gov.guidelinesHashOf(1), a);
        assertEq(gov.guidelinesHashOf(2), b);
        assertEq(gov.guidelinesHashOf(3), a);
        assertTrue(gov.guidelinesHashOf(1) != gov.guidelinesHashOf(2), "distinct versions, distinct text");
    }

    /// MUTATION: drop the zero-hash guard.
    function test_s4_1_aZeroGuidelinesHashIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ZeroHash.selector);
        gov.proposeGuidelines(bytes32(0));
    }

    /// @dev The swap defence applies to guidelines too, for the same reason.
    function test_s4_1_guidelinesExecuteNamesWhatItExecutes() public {
        vm.prank(owner);
        gov.proposeGuidelines(keccak256("queued"));
        (, uint256 eta,) = gov.pendingGuidelinesProposal();
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ProposalMismatch.selector);
        gov.executeGuidelines(keccak256("substituted"));

        vm.prank(owner);
        gov.executeGuidelines(keccak256("queued"));
        assertEq(gov.guidelinesHashOf(1), keccak256("queued"));
    }

    function test_s4_1_guidelinesAreTimelockedAndCancellable() public {
        vm.prank(owner);
        gov.proposeGuidelines(keccak256("t"));
        (, uint256 eta,) = gov.pendingGuidelinesProposal();

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.TimelockNotElapsed.selector);
        gov.executeGuidelines(keccak256("t"));

        vm.prank(owner);
        gov.cancelGuidelines();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        gov.executeGuidelines(keccak256("t"));
        assertEq(gov.guidelinesVersion(), 0, "nothing was published");
    }

    /// MUTATION: leave the pending record in place after a successful execute.
    ///
    /// @dev Without the delete, `executeGuidelines` is replayable: the same queued
    ///      text can be published again and again, each time consuming a version.
    ///      That is worse than a redundant call — it INFLATES the version counter,
    ///      and the counter is what partitions the measurement's dataset.
    function test_s4_1_guidelinesExecuteAtMostOnce() public {
        bytes32 h = keccak256("text");
        assertEq(_publishGuidelines(h), 1);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        gov.executeGuidelines(h);

        assertEq(gov.guidelinesVersion(), 1, "one publication, one version");
    }

    /// MUTATION: drop `onlyGovernance` from any guidelines entry point.
    function test_s4_1_everyGuidelinesPathIsGovernanceOnly() public {
        bytes32 h = keccak256("text");

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.proposeGuidelines(h);

        vm.prank(owner);
        gov.proposeGuidelines(h);

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.cancelGuidelines();

        (, uint256 eta,) = gov.pendingGuidelinesProposal();
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.executeGuidelines(h);

        assertEq(gov.guidelinesVersion(), 0, "a stranger published nothing");
    }

    /// ACCEPTANCE 4b — a reader recovers which text a case was decided under, FROM
    /// LOGS ALONE.
    ///
    /// @dev This is the property `measurement/prior` depends on: cases decided under
    ///      different guideline text are different experiments and must not be
    ///      pooled. A version bump invisible in the logs splits the dataset silently,
    ///      and the split is only discovered when the sample turns out underpowered
    ///      — after the cases are decided, with no way to re-run them.
    ///
    ///      The test reads ONLY `GuidelinesExecuted` records. `vm.getRecordedLogs`
    ///      does not expose a log's block number (a real indexer gets it as log
    ///      metadata), which is why the event carries `blockNumber` in its own data
    ///      — and why the resolution below needs nothing but the event bodies.
    ///
    /// MUTATION: drop `version` or `hash` from the event; emit no event at all.
    function test_s4_1_aReaderRecoversTheGuidelinesACaseWasDecidedUnderFromLogsAlone() public {
        vm.recordLogs();

        // ABSOLUTE heights. A relative `vm.roll(block.number + n)` inside a helper
        // that also warps does not compound the way it reads, and this suite has
        // been bitten by the warp form of that already.
        vm.roll(2000);
        _publishGuidelines(keccak256("v1-text"));

        vm.roll(2050);
        uint256 caseId = _submit("content");

        vm.roll(2100);
        _publishGuidelines(keccak256("v2-text"));

        // The case's submission height, taken from MODERATION's own record rather
        // than from a `block.number` read in this function.
        //
        // Not a style preference. Under `via_ir` the optimizer treats `block.number`
        // as loop-invariant and common-subexpression-eliminates reads of it across
        // a `vm.roll`, because a cheatcode is an opaque staticcall it has no reason
        // to think mutates the environment. `uint256 b = block.number;` written
        // before the roll therefore observes the height AFTER it, silently. Same
        // family as a `vm.prank` consumed by an argument expression: the trap is
        // evaluation order around a cheatcode, not the cheatcode itself.
        //
        // `phaseDeadline - commitBlocks` is the height `submit` recorded, computed
        // inside another contract, so no amount of hoisting in this function can
        // reach it. It is also what a real reader would use.
        Moderation.Case memory c = mod.caseInfo(caseId);
        uint256 caseBlock = uint256(c.phaseDeadline) - c.commitBlocks;
        assertEq(caseBlock, 2050, "fixture: the case was submitted between the two versions");

        assertEq(gov.guidelinesBlockOf(1), 2000, "fixture: v1 took effect before the case");
        assertEq(gov.guidelinesBlockOf(2), 2100, "fixture: v2 took effect after it");

        // --- everything below uses only the recorded logs ---------------------
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("GuidelinesExecuted(uint32,bytes32,uint256)");

        uint32 bestVersion;
        bytes32 bestHash;
        uint256 bestBlock;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(gov) || logs[i].topics[0] != sig) continue;
            uint32 version = uint32(uint256(logs[i].topics[1]));
            bytes32 hash = logs[i].topics[2];
            uint256 blockNumber = abi.decode(logs[i].data, (uint256));
            if (blockNumber <= caseBlock && (bestVersion == 0 || blockNumber >= bestBlock)) {
                bestVersion = version;
                bestHash = hash;
                bestBlock = blockNumber;
            }
        }

        assertEq(bestVersion, 1, "the case was decided under version 1");
        assertEq(bestHash, keccak256("v1-text"), "and the reader knows WHICH TEXT that was");
        assertEq(mod.caseInfo(caseId).paramsVersion, 1, "the case is real");

        // The on-chain half agrees with the log-derived answer.
        assertEq(gov.guidelinesVersionAt(caseBlock), 1);
        assertEq(gov.guidelinesVersionAt(block.number), 2);
    }

    /// @dev The on-chain resolver, at its edges.
    function test_s4_1_guidelinesVersionAtIsZeroBeforeAnyPublication() public {
        assertEq(gov.guidelinesVersionAt(block.number), 0);
        _publishGuidelines(keccak256("t"));
        assertEq(gov.guidelinesVersionAt(block.number - 1), 0, "before it existed");
        assertEq(gov.guidelinesVersionAt(block.number), 1, "at the block it took effect");
    }

    function _publishGuidelines(bytes32 hash) internal returns (uint32 v) {
        vm.prank(owner);
        gov.proposeGuidelines(hash);
        (, uint256 eta,) = gov.pendingGuidelinesProposal();
        vm.warp(eta);
        vm.prank(owner);
        v = gov.executeGuidelines(hash);
    }

    // =========================================================================
    // Binding (M2.6-F3)
    // =========================================================================

    /// MUTATION: drop the `m.governor() != address(this)` check.
    function test_f3_bindRefusesAModerationThatDoesNotNameThisGovernor() public {
        RulesetGovernor other = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.BindingNotMutual.selector);
        other.bindModeration(mod); // `mod` names `gov`, not `other`
    }

    /// MUTATION: drop `onlyGovernance` from `bindModeration`.
    ///
    /// @dev The bind is the trust relationship. Permissionless, anyone could race a
    ///      deployment and bind a governor to a `Moderation` before its operator
    ///      does — and because the bind is one-way, the correct one could then never
    ///      be made.
    function test_f3_bindIsGovernanceOnly() public {
        RulesetGovernor fresh = new RulesetGovernor(owner, TIMELOCK);
        Moderation m = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), address(fresh));

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        fresh.bindModeration(m);

        vm.prank(owner);
        fresh.bindModeration(m);
        assertEq(address(fresh.moderation()), address(m));
    }

    /// MUTATION: drop the zero-address guard from `bindModeration`.
    ///
    /// @dev Near-equivalent and worth killing anyway. Without the guard the call
    ///      still reverts — `address(0).governor()` is a high-level call to an
    ///      address with no code — but with a decode failure rather than a named
    ///      error. Asserting the SELECTOR is what makes the guard load-bearing;
    ///      asserting "it reverts" would pass either way.
    function test_f3_bindRefusesTheZeroAddress() public {
        RulesetGovernor fresh = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ZeroAddress.selector);
        fresh.bindModeration(Moderation(address(0)));
    }

    /// MUTATION: allow rebinding.
    function test_f3_bindIsOneWay() public {
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.AlreadyBound.selector);
        gov.bindModeration(mod);
    }

    /// @dev The failure `bindModeration` moves earlier. Without the bind an
    ///      unbound governor accepts a proposal, runs the whole timelock, and fails
    ///      at execute — from the call that looks like the action landing.
    function test_f3_anUnboundGovernorRefusesToExecute() public {
        RulesetGovernor fresh = new RulesetGovernor(owner, TIMELOCK);
        Moderation.Params memory p = _params(LAMBDA);

        vm.prank(owner);
        fresh.proposeParams(p); // accepted: validation does not need a binding
        (, uint256 eta,) = fresh.pendingParamsProposal();
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NotBound.selector);
        fresh.executeParams(p);
    }

    /// @dev The lock-in this contract accepts, stated as a test so it is a decision
    ///      and not a surprise. `Moderation.setGovernor` is `onlyGovernor`, so once
    ///      the governor is this contract the only caller that could move the field
    ///      is this contract — and it exposes no path to it. The field is frozen by
    ///      omission, which is what restores F3's permanence argument after v3 made
    ///      `governor` mutable. See DEVIATIONS D3-20.
    function test_f3_moderationsGovernorCannotBeMovedByAnyoneOnceBound() public {
        vm.prank(owner);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.setGovernor(stranger);

        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.setGovernor(stranger);

        assertEq(mod.governor(), address(gov), "and it is still this governor");
    }

    // =========================================================================
    // Governance transfer
    // =========================================================================

    /// MUTATION: make `proposeGovernance` take effect immediately.
    function test_governanceTransferIsTwoStepAndZeroChecked() public {
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ZeroAddress.selector);
        gov.proposeGovernance(address(0));

        vm.prank(owner);
        gov.proposeGovernance(stranger);
        assertEq(gov.governance(), owner, "not yet - the nominee must prove control");

        vm.prank(makeAddr("someoneElse"));
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.acceptGovernance();

        vm.prank(stranger);
        gov.acceptGovernance();
        assertEq(gov.governance(), stranger);
        assertEq(gov.pendingGovernance(), address(0));

        // And the old owner is out.
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.proposeParams(_params(LAMBDA));
    }

    function test_governanceTransferCanBeCancelled() public {
        vm.prank(owner);
        gov.proposeGovernance(stranger);
        vm.prank(owner);
        gov.cancelGovernanceTransfer();

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.acceptGovernance();
    }

    function test_constructorRefusesZeroGovernance() public {
        vm.expectRevert(RulesetGovernor.ZeroAddress.selector);
        new RulesetGovernor(address(0), TIMELOCK);
    }
    // =========================================================================
    // M2.12 / D3-21 — the pin, and why it is FAIRNESS and not bookkeeping
    // =========================================================================

    /// @dev Drives a case to a terminal with `nApprove` Approve and `nReject`
    ///      Reject reveals, returning the cohort. Split so a guidelines change can
    ///      be landed in the MIDDLE of the commit phase.
    function _cohort(uint256 n, uint256 bond) internal returns (address[] memory who) {
        who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = _moderator(100 + i, bond);
        }
    }

    /// @dev Forces a verdict by searching for an entropy that produces it. The
    ///      contract still does the deciding; this only chooses which block hash it
    ///      reads, and the assertion after `draw` proves the steer landed.
    function _drawTo(uint256 caseId, uint8 want) internal {
        vm.roll(uint256(mod.caseInfo(caseId).outcomeSeedBlock) + 1);
        uint256 sb = mod.caseInfo(caseId).outcomeSeedBlock;
        for (uint256 i; i < 4096; ++i) {
            bytes32 h = keccak256(abi.encode("entropy", caseId, i));
            (uint8 v,) = mod.decideAt(caseId, h);
            if (v != want) continue;
            vm.setBlockhash(sb, h);
            mod.draw(caseId);
            assertEq(mod.caseInfo(caseId).verdict, want, "the steer landed");
            return;
        }
        assertTrue(false, "no entropy produced the wanted verdict");
    }

    function _commitVote(uint256 caseId, address a, uint8 v) internal {
        Moderation.Case memory c = mod.caseInfo(caseId);
        bytes32 h = mod.commitHash(caseId, c.round, c.paramsVersion, a, v, keccak256("s"));
        vm.prank(a);
        mod.commit(caseId, h);
    }

    /// ACCEPTANCE 2 — the pin as fairness.
    ///
    /// @dev The argument, in one sentence: `d` is charged for voting incoherently
    ///      with the settled side (§5.1), so without a pin a guidelines change
    ///      mid-case debits whichever side loses **for correctly applying the
    ///      instructions it was given**. This test builds exactly that situation —
    ///      one moderator commits before the change, one after — and asserts that
    ///      both are judged, and one debited, against the SAME pinned version.
    ///
    ///      Reading the field back would not have tested this. The debit has to
    ///      actually land, in a case whose pinned version differs from the live one.
    ///
    /// MUTATION: pin `currentGuidelinesVersion` at settlement rather than at
    ///           submission; or drop `c.guidelinesVersion = ...` from `_submit`.
    function test_s4_1_everyModeratorOnACaseIsJudgedAgainstTheVersionPinnedAtSubmission() public {
        _publishGuidelines(keccak256("text-v1"));
        assertEq(mod.currentGuidelinesVersion(), 1, "the push reached Moderation");

        address[] memory who = _cohort(4, BOND_MIN + 200 * UNIT);
        uint256 id = _submit("content");
        assertEq(mod.caseInfo(id).guidelinesVersion, 1, "pinned at submission");

        vm.roll(block.number + SEED_LAG + 1);

        // Two commit under version 1.
        _commitVote(id, who[0], APPROVE);
        _commitVote(id, who[1], APPROVE);

        // Governance changes the guidelines WHILE THE CASE IS LIVE.
        _publishGuidelines(keccak256("text-v2"));
        assertEq(mod.currentGuidelinesVersion(), 2, "the world moved on");
        assertEq(mod.caseInfo(id).guidelinesVersion, 1, "the case did not");

        // Two more commit afterwards. Without the pin these read a different text
        // from the first two, and the losing side is debited for following it.
        _commitVote(id, who[2], REJECT);
        _commitVote(id, who[3], REJECT);

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            mod.reveal(id, i < 2 ? APPROVE : REJECT, keccak256("s"));
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        _drawTo(id, APPROVE);

        // The debit lands, and it lands in a case pinned to version 1 while the
        // live version is 2. That is the whole property.
        assertEq(mod.caseInfo(id).guidelinesVersion, 1, "still pinned at the terminal");
        assertEq(mod.currentGuidelinesVersion(), 2, "and still not the live one");

        uint256 debitedBondBefore = reg.bondOf(who[2]);
        mod.claim(id, who[2]); // revealed Reject against an Approve verdict
        assertLt(reg.bondOf(who[2]), debitedBondBefore, "the incoherent voter IS debited");

        // §5.3 pays into the registry bond, not out in tokens.
        uint256 paidBefore = reg.bondOf(who[0]);
        mod.claim(id, who[0]);
        assertGt(reg.bondOf(who[0]), paidBefore, "and the coherent one is paid");

        // Both were settled inside one case carrying one version. The early and
        // late committers were never judged against different text.
        assertEq(mod.caseInfo(id).guidelinesVersion, 1);
    }

    /// @dev `reopen` does NOT re-pin, and that is the same reasoning. A re-review
    ///      reopens the claim IN PLACE (§8.5) and the pooled tally carries, so the
    ///      earlier cohort's votes are evidence in the same question. Re-pinning
    ///      would judge one tally against two texts — precisely the split the pin
    ///      exists to prevent, reintroduced through the back door.
    ///
    ///      `paramsVersion` is not re-pinned either; this matches it deliberately.
    ///
    /// MUTATION: set `c.guidelinesVersion = currentGuidelinesVersion` in `reopen`.
    function test_s4_1_aReopenDoesNotRePinTheGuidelines() public {
        _publishGuidelines(keccak256("text-v1"));

        address[] memory who = _cohort(4, BOND_MIN + 200 * UNIT);
        uint256 id = _submit("content");
        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < 4; ++i) {
            _commitVote(id, who[i], REJECT);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            mod.reveal(id, REJECT, keccak256("s"));
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        _drawTo(id, REJECT);
        for (uint256 i; i < 4; ++i) {
            mod.claim(id, who[i]);
        }

        _publishGuidelines(keccak256("text-v2"));
        assertEq(mod.currentGuidelinesVersion(), 2);

        vm.prank(submitter);
        mod.reopen(id, FEE);

        assertEq(mod.caseInfo(id).guidelinesVersion, 1, "the reopened claim keeps its original text");
        assertEq(mod.caseInfo(id).paramsVersion, 1, "exactly as paramsVersion does");
    }

    /// MUTATION: drop the monotonicity check in `Moderation.applyGuidelines`.
    function test_s4_1_theModerationSidePinIsMonotonicAndGovernorOnly() public {
        _publishGuidelines(keccak256("a"));
        _publishGuidelines(keccak256("b"));
        assertEq(mod.currentGuidelinesVersion(), 2);

        // Only the governor may push at all.
        vm.prank(stranger);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyGuidelines(3);

        vm.prank(owner);
        vm.expectRevert(Moderation.NotGovernor.selector);
        mod.applyGuidelines(3);

        // And even the governor cannot move it backwards or reuse a number.
        vm.prank(address(gov));
        vm.expectRevert(Moderation.GuidelinesNotMonotonic.selector);
        mod.applyGuidelines(2);

        vm.prank(address(gov));
        vm.expectRevert(Moderation.GuidelinesNotMonotonic.selector);
        mod.applyGuidelines(1);
    }

    /// MUTATION: drop `moderation.applyGuidelines(version)` from executeGuidelines.
    ///
    /// @dev The governor allocates and `Moderation` pins. If the push is dropped the
    ///      governor's record advances while every case keeps pinning the stale
    ///      number — the two diverge silently, and a reader consulting the log gets
    ///      an answer no case agrees with.
    function test_s4_1_theGovernorRecordAndTheModerationPinStayInStep() public {
        for (uint32 v = 1; v <= 3; ++v) {
            _publishGuidelines(keccak256(abi.encode("text", v)));
            assertEq(gov.guidelinesVersion(), v, "the governor allocated it");
            assertEq(mod.currentGuidelinesVersion(), v, "and Moderation took it");
        }

        uint256 id = _submit("content");
        assertEq(mod.caseInfo(id).guidelinesVersion, 3);
        // The hash a reader recovers for that version is the governor's record.
        assertEq(gov.guidelinesHashOf(3), keccak256(abi.encode("text", uint32(3))));
    }

    /// @dev An unbound governor cannot publish guidelines, because there is nothing
    ///      to push the version into. Better to refuse than to advance a record
    ///      that no `Moderation` will ever agree with.
    function test_s4_1_anUnboundGovernorCannotPublishGuidelines() public {
        RulesetGovernor fresh = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        fresh.proposeGuidelines(keccak256("t"));
        (, uint256 eta,) = fresh.pendingGuidelinesProposal();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NotBound.selector);
        fresh.executeGuidelines(keccak256("t"));
    }

    // =========================================================================
    // M2.12 / D3-20 — the governor's exit
    // =========================================================================

    /// @dev Builds a successor that has DECLARED this Moderation but cannot yet be
    ///      bound to it — the chicken-and-egg the intent field exists to break.
    function _successor() internal returns (RulesetGovernor next) {
        next = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        next.intendModeration(mod);
    }

    function _handOverTo(RulesetGovernor next) internal {
        vm.prank(owner);
        gov.proposeGovernorChange(address(next));
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(owner);
        gov.executeGovernorChange(address(next));
    }

    /// ACCEPTANCE 3a — the exit works, and leaves the pair bound.
    ///
    /// @dev D3-20 recorded this as frozen by omission: `setGovernor` is
    ///      `onlyGovernor` and no caller existed. Frozen by omission reads as
    ///      deliberate and was not.
    function test_d3_20_theGovernorCanHandOverAndTheSuccessorIsBound() public {
        RulesetGovernor next = _successor();
        assertEq(address(next.moderation()), address(0), "not bound - it cannot be, yet");

        _handOverTo(next);

        assertEq(mod.governor(), address(next), "Moderation moved");
        assertEq(address(next.moderation()), address(mod), "and the successor is bound, atomically");
        assertTrue(gov.retired(), "the outgoing one is retired");

        // The pending record is cleared. A replay is already refused by `retired`,
        // so this is not about safety — it is that a governance reader would
        // otherwise be shown a pending handover that can never execute.
        (,, bool stillPending) = gov.pendingGovernorChangeProposal();
        assertFalse(stillPending, "the executed handover leaves no pending record");

        // The successor governs for real.
        Moderation.Params memory p = _params(7 * LAMBDA);
        vm.prank(owner);
        next.proposeParams(p);
        (, uint256 eta,) = next.pendingParamsProposal();
        vm.warp(eta);
        vm.prank(owner);
        uint32 v = next.executeParams(p);
        assertEq(mod.paramsAt(v).lambda, 7 * LAMBDA);
    }

    /// @dev And the retired one is out, by name rather than by a revert from
    ///      somewhere else. Without `retired` this fails as `NotGovernor` out of
    ///      `Moderation`, after the full timelock.
    function test_d3_20_aRetiredGovernorIsRefusedByName() public {
        RulesetGovernor next = _successor();
        _handOverTo(next);

        Moderation.Params memory p = _params(5 * LAMBDA);
        vm.prank(owner);
        gov.proposeParams(p);
        (, uint256 eta,) = gov.pendingParamsProposal();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.Retired.selector);
        gov.executeParams(p);

        vm.prank(owner);
        gov.proposeGuidelines(keccak256("t"));
        (, uint256 geta,) = gov.pendingGuidelinesProposal();
        vm.warp(geta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.Retired.selector);
        gov.executeGuidelines(keccak256("t"));
    }

    /// ACCEPTANCE 3b — reciprocity, checked at EXECUTE against live state.
    ///
    /// MUTATION: drop the `intendedModeration() != moderation` check, or move it
    ///           to `proposeGovernorChange`.
    function test_d3_20_aSuccessorThatDoesNotTargetThisModerationIsRefused() public {
        // Declares nothing at all.
        RulesetGovernor blank = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        gov.proposeGovernorChange(address(blank));
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.SuccessorNotBoundToThisModeration.selector);
        gov.executeGovernorChange(address(blank));

        assertEq(mod.governor(), address(gov), "the field never moved");
        assertFalse(gov.retired());
    }

    /// @dev A successor that targets a DIFFERENT Moderation. This is the one that
    ///      bricks the pair if it lands: the field moves, the successor refuses to
    ///      adopt, and nothing can move it back.
    function test_d3_20_aSuccessorTargetingAnotherModerationIsRefused() public {
        RulesetGovernor other = new RulesetGovernor(owner, TIMELOCK);
        Moderation otherMod =
            new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), address(other));
        vm.prank(owner);
        other.intendModeration(otherMod);

        vm.prank(owner);
        gov.proposeGovernorChange(address(other));
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.SuccessorNotBoundToThisModeration.selector);
        gov.executeGovernorChange(address(other));

        assertEq(mod.governor(), address(gov), "still ours, and still usable");
    }

    /// @dev The state the order asks about — correct at propose, wrong at execute —
    ///      is UNREACHABLE by construction, and it is worth saying why rather than
    ///      writing a test that cannot fail. `intendModeration` is one-shot and has
    ///      no unset, so a successor's target cannot move after it is declared.
    ///
    ///      What IS reachable is the opposite order: intent declared only after the
    ///      propose. Checking at execute accepts it; checking at propose would have
    ///      rejected a handover that is perfectly safe by the time it lands. That is
    ///      a second, independent reason the check belongs at execute.
    function test_d3_20_intentDeclaredAfterTheProposeIsStillAccepted() public {
        RulesetGovernor next = new RulesetGovernor(owner, TIMELOCK);

        vm.prank(owner);
        gov.proposeGovernorChange(address(next)); // nothing declared yet

        vm.prank(owner);
        next.intendModeration(mod); // declared during the delay

        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(owner);
        gov.executeGovernorChange(address(next));
        assertEq(mod.governor(), address(next));

        // And it cannot be redeclared afterwards, which is what makes the
        // execute-time read stable.
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.AlreadyBound.selector);
        next.intendModeration(mod);
    }

    /// MUTATION: drop the argument match in executeGovernorChange.
    function test_d3_20_executeNamesTheSuccessorItExecutes() public {
        RulesetGovernor a = _successor();
        RulesetGovernor b = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        b.intendModeration(mod);

        vm.prank(owner);
        gov.proposeGovernorChange(address(a));
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);

        // `b` is a perfectly valid successor — it just is not the one approved.
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ProposalMismatch.selector);
        gov.executeGovernorChange(address(b));

        vm.prank(owner);
        gov.executeGovernorChange(address(a));
        assertEq(mod.governor(), address(a));
    }

    /// @dev A replacement resets the eta, same as the other two paths.
    function test_d3_20_theHandoverIsTimelockedAndCancellable() public {
        RulesetGovernor next = _successor();

        vm.prank(owner);
        gov.proposeGovernorChange(address(next));
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.TimelockNotElapsed.selector);
        gov.executeGovernorChange(address(next));

        vm.prank(owner);
        gov.cancelGovernorChange();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.NoPendingProposal.selector);
        gov.executeGovernorChange(address(next));
        assertEq(mod.governor(), address(gov), "nothing happened");
    }

    /// @dev Handing the governorship to an EOA would brick parameter governance:
    ///      `Moderation` would accept `applyParams` from it, but nothing would ever
    ///      publish a guidelines version or honour a timelock, and there would be no
    ///      way back. The `intendedModeration()` read refuses anything without that
    ///      surface, which makes the mistake unrepresentable rather than merely
    ///      discouraged.
    function test_d3_20_theGovernorshipCannotBeHandedToAnEOA() public {
        vm.prank(owner);
        gov.proposeGovernorChange(stranger);
        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert();
        gov.executeGovernorChange(stranger);
        assertEq(mod.governor(), address(gov));
    }

    /// MUTATION: drop `onlyGovernance` from any exit path; allow `next == this`.
    function test_d3_20_theExitIsGovernanceOnlyAndRefusesSelf() public {
        RulesetGovernor next = _successor();

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.proposeGovernorChange(address(next));

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.SuccessorIsSelf.selector);
        gov.proposeGovernorChange(address(gov));

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.ZeroAddress.selector);
        gov.proposeGovernorChange(address(0));

        vm.prank(owner);
        gov.proposeGovernorChange(address(next));
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.cancelGovernorChange();

        (, uint256 eta,) = gov.pendingGovernorChangeProposal();
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        gov.executeGovernorChange(address(next));
    }

    /// MUTATION: make `adoptModeration` bind something other than the intent, or
    ///           drop its reciprocity check.
    function test_d3_20_adoptIsPermissionlessButCannotChooseItsTarget() public {
        RulesetGovernor next = _successor();

        // Before the handover the reciprocity is false, so anyone calling it fails.
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.BindingNotMutual.selector);
        next.adoptModeration();

        _handOverTo(next);
        assertEq(address(next.moderation()), address(mod));

        // And it is one-way afterwards.
        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.AlreadyBound.selector);
        next.adoptModeration();
    }

    /// MUTATION: allow `intendModeration` after a bind, or twice.
    function test_d3_20_intentIsOneShot() public {
        RulesetGovernor next = new RulesetGovernor(owner, TIMELOCK);
        vm.prank(owner);
        next.intendModeration(mod);

        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.AlreadyIntended.selector);
        next.intendModeration(mod);

        // A bound governor has no intent to declare.
        vm.prank(owner);
        vm.expectRevert(RulesetGovernor.AlreadyBound.selector);
        gov.intendModeration(mod);

        vm.prank(stranger);
        vm.expectRevert(RulesetGovernor.NotGovernance.selector);
        next.intendModeration(mod);
    }

}
