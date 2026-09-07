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
        reg.executeCaps();

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
}
