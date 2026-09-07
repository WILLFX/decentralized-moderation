// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";
import {RulesetGovernor} from "../../src/v3/RulesetGovernor.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {SystemHandler} from "./handlers/SystemHandler.sol";

/// @title v3 — stateful invariants across all three real contracts
/// @notice The other suites assert properties at moments someone chose. This one
///         asserts them after EVERY reachable sequence the runner can build, with
///         no mocks anywhere: real `StakeRegistry`, real `Moderation`, real
///         `IndexRegistry`, wired the way a deployment would wire them.
///
/// @dev What this is for, stated plainly: a unit test finds the bug you suspected.
///      A stateful invariant finds the ordering nobody imagined — which is the
///      class this codebase has repeatedly been bitten by (M2.6-F2's second door,
///      the I26 key release across a re-review, the I3 allowance across rounds).
///      Each of those was an ORDER of operations, not a single call.
contract V3InvariantTest is StdInvariant, Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    IndexRegistry internal idx;
    Moderation internal mod;
    RulesetGovernor internal governor;
    SystemHandler internal handler;

    address internal gov;

    uint256 internal constant UNIT = 1e16;
    uint256 internal constant TIMELOCK = 2 days;

    function setUp() public {
        gov = makeAddr("gov");
        token = new MockBZZ();

        vm.prank(gov);
        reg = new StakeRegistry(
            IERC20(address(token)), 10 * UNIT, 5 * UNIT, 3 days, 7 days, TIMELOCK, 0.5e18
        );
        vm.prank(gov);
        idx = new IndexRegistry(TIMELOCK);
        // M2.11 — Moderation's governor is the RulesetGovernor, exactly as deployed.
        vm.prank(gov);
        governor = new RulesetGovernor(gov, TIMELOCK);
        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), address(governor));
        vm.prank(gov);
        governor.bindModeration(mod);

        // The real wiring, through the real timelocks — this is also the only place
        // the deployment order is exercised end to end.
        uint8 bits = reg.MAY_CREATE() | reg.MAY_DISCHARGE();
        vm.prank(gov);
        reg.proposeCaps(address(mod), bits);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        reg.executeCaps();

        vm.prank(gov);
        idx.proposeWriter(address(mod), true);
        (,, uint256 eta,) = idx.pendingWriterProposal();
        vm.warp(eta);
        vm.prank(gov);
        idx.executeWriter();

        Moderation.Params memory p;
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
        p.threshold = type(uint256).max; // everyone eligible: this suite is not about §3.3
        // Through the governor and its timelock, like every later change.
        vm.prank(gov);
        governor.proposeParams(p);
        (, uint256 pEta,) = governor.pendingParamsProposal();
        vm.warp(pEta);
        vm.prank(gov);
        governor.executeParams(p);

        address[] memory actors = new address[](6);
        for (uint256 i; i < 6; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
        }

        handler = new SystemHandler(token, reg, idx, mod, governor, gov, actors);
        vm.roll(1000);
        handler.init();

        // Only the `h*` actions are fuzz targets. `init`, the views and the ghost
        // readers are not — a runner calling them would be testing the harness.
        bytes4[] memory sels = new bytes4[](17);
        sels[0] = SystemHandler.hStake.selector;
        sels[1] = SystemHandler.hPostBond.selector;
        sels[2] = SystemHandler.hSubmit.selector;
        sels[3] = SystemHandler.hCommit.selector;
        sels[4] = SystemHandler.hReveal.selector;
        sels[5] = SystemHandler.hChallenge.selector;
        sels[6] = SystemHandler.hPoke.selector;
        sels[7] = SystemHandler.hClaim.selector;
        sels[8] = SystemHandler.hClaimChallenge.selector;
        sels[9] = SystemHandler.hRequestExit.selector;
        sels[10] = SystemHandler.hWithdraw.selector;
        sels[11] = SystemHandler.hSweep.selector;
        sels[12] = SystemHandler.hRefund.selector;
        sels[13] = SystemHandler.hRoll.selector;
        sels[14] = SystemHandler.hSubmitRemoval.selector;
        sels[15] = SystemHandler.hChangeParams.selector;
        sels[16] = SystemHandler.hRotateGovernor.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        targetContract(address(handler));
    }

    // =========================================================================
    // I21 — every unit the registry holds is in a named bucket
    // =========================================================================

    /// @dev Exact, not `>=`. The registry's ledger and its balance must agree after
    ///      any sequence: stake, bond, debits into the reserve, rewards paid in by
    ///      `Moderation`, maintenance swept in, withdrawals out. A single path that
    ///      moves value without moving a bucket breaks this and nothing else does.
    function invariant_registryLedgerEqualsItsBalance() public view {
        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets(), "registry ledger drifted from its balance");
    }

    function invariant_registryIsSolvent() public view {
        assertTrue(reg.solvent(), "registry insolvent");
    }

    /// @dev `totalStake` and `totalBond` are running sums maintained by hand at
    ///      seven call sites. This is the only thing that checks they still equal
    ///      the sum they claim to be.
    function invariant_registryTotalsEqualTheSumOfBalances() public view {
        uint256 n = handler.actorCount();
        uint256 stakeSum;
        uint256 bondSum;
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            (uint256 stk, uint256 bond,,,,,,) = reg.moderatorInfo(a);
            stakeSum += stk;
            bondSum += bond;
        }
        assertEq(reg.totalStake(), stakeSum, "totalStake drifted");
        assertEq(reg.totalBond(), bondSum, "totalBond drifted");
    }

    // =========================================================================
    // I23 — liabilities == the sum of that moderator's open claim records
    // =========================================================================

    /// @dev The identity the registry cannot check alone, because it keeps a COUNT
    ///      and not an enumeration. The handler holds the list; `liabilitiesMatch`
    ///      refuses a list that is incomplete or repeats, so a drifting ghost fails
    ///      loudly rather than quietly agreeing.
    function invariant_I23_liabilitiesEqualTheSumOfClaims() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            (uint256[] memory ids, uint8[] memory kinds) = handler.openClaimsOf(a);
            (bool ok, uint256 sum) = reg.liabilitiesMatch(a, ids, kinds);
            assertTrue(ok, "I23: liabilities != sum of claim records");
            assertEq(sum, reg.liabilitiesOf(a), "I23: sum disagrees with the accumulator");
        }
    }

    /// @dev The registry's own per-logic counter, against the same ghost. `Moderation`
    ///      is the only writer, so its open claims are exactly the claims the handler
    ///      believes are open.
    function invariant_openClaimsCounterMatchesTheLedger() public view {
        uint256 n = handler.actorCount();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            (uint256[] memory ids,) = handler.openClaimsOf(handler.actors(i));
            total += ids.length;
        }
        assertEq(reg.openClaims(address(mod)), total, "openClaims drifted from the open set");
    }

    // =========================================================================
    // I13 — withdrawal implies no outstanding liability
    // =========================================================================

    /// @dev A moderator who has left holds nothing and owes nothing. If a withdrawal
    ///      could ever complete with a claim standing, this is where it shows —
    ///      including via an ordering where the claim was created after the exit
    ///      request.
    function invariant_I13_anExitedModeratorOwesNothing() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            if (reg.stateOf(a) != StakeRegistry.State.NONE) continue;
            assertEq(reg.liabilitiesOf(a), 0, "I13: a departed moderator still owes");
            assertEq(reg.bondOf(a), 0, "a departed moderator still holds bond");
        }
    }

    // =========================================================================
    // I16 — the §2.2 state predicates are mutually exclusive
    // =========================================================================

    /// @dev Evaluated from the raw fields rather than through `stateOf`, which is an
    ///      if-else chain and so exclusive by construction. Checked here after every
    ///      sequence rather than at the handful of transitions a unit test visits.
    function invariant_I16_exactlyOneStateHolds() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            (uint256 stk,,,,, uint256 maturesAt, uint256 exitAt,) = reg.moderatorInfo(handler.actors(i));
            bool none = stk == 0;
            bool pending = stk > 0 && exitAt == 0 && block.timestamp < maturesAt;
            bool active = stk > 0 && exitAt == 0 && block.timestamp >= maturesAt;
            bool exiting = stk > 0 && exitAt != 0;
            uint256 held = (none ? 1 : 0) + (pending ? 1 : 0) + (active ? 1 : 0) + (exiting ? 1 : 0);
            assertEq(held, 1, "I16: not exactly one state");
        }
    }

    // =========================================================================
    // I15 / §8.1 — the index is written at the terminal, never later
    // =========================================================================

    /// @dev Finality is independent of payout: a reader must be able to see a result
    ///      without waiting for any moderator to settle. So a case with a terminal
    ///      has an index entry for every topic, and it has it NOW — not once
    ///      settlement completes, which §5.5 says may never happen.
    function invariant_I15_everyTerminatedCaseIsInTheIndex() public view {
        uint256 n = handler.caseCount();
        bytes32[] memory topics = handler.topicsOf();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            Moderation.Case memory c = mod.caseInfo(id);
            if (c.terminal == uint8(Moderation.Terminal.NONE)) continue;
            for (uint256 t; t < topics.length; ++t) {
                assertTrue(
                    idx.statusOf(c.claimKey, topics[t]) != uint8(IndexRegistry.Status.NONE),
                    "I15: a terminated case is invisible to a reader"
                );
            }
        }
    }

    /// @dev §8.2's listing membership is exactly `APPROVED`, maintained across every
    ///      write and every delist. A drift here is a safe-search client showing
    ///      content the protocol rejected.
    function invariant_s8_2_onlyApprovedContentIsListed() public view {
        uint256 n = handler.caseCount();
        bytes32[] memory topics = handler.topicsOf();
        for (uint256 i; i < n; ++i) {
            Moderation.Case memory c = mod.caseInfo(handler.caseIds(i));
            for (uint256 t; t < topics.length; ++t) {
                uint8 st = idx.statusOf(c.claimKey, topics[t]);
                bool listed = idx.isListed(c.claimKey, topics[t]);
                assertEq(listed, st == uint8(IndexRegistry.Status.APPROVED), "listing disagrees with status");
            }
        }
    }

    // =========================================================================
    // Value conservation across the whole system
    // =========================================================================

    /// @dev Nothing is created and nothing is destroyed. Every unit ever minted into
    ///      the system is either still held by one of the three contracts, or sits
    ///      in an actor's wallet. This is the invariant that would catch a payment
    ///      path paying twice, or a refund paid from the wrong pocket.
    function invariant_valueIsConserved() public view {
        uint256 held = token.balanceOf(address(reg)) + token.balanceOf(address(mod)) + token.balanceOf(address(idx));
        uint256 inWallets;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            inWallets += token.balanceOf(handler.actors(i));
        }
        assertEq(held + inWallets, handler.ghostPaidIn(), "value was created or destroyed");
    }

    /// @dev `Moderation` is logic, not custody. What it holds is escrow for live
    ///      cases plus maintenance not yet swept — never a moderator's stake or bond,
    ///      which is the boundary §2.4 draws and I14 depends on.
    function invariant_moderationHoldsNoModeratorFunds() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            (uint256 stk, uint256 bond,,,,,,) = reg.moderatorInfo(a);
            // A moderator's balances live in the registry's buckets, and the
            // registry's balance covers them, so Moderation cannot be holding them.
            assertLe(stk + bond, reg.balanceBuckets(), "a moderator's funds are outside the registry");
        }
    }

    // =========================================================================
    // The run actually exercised something
    // =========================================================================

    /// @dev An invariant suite that never reaches an interesting state passes
    ///      VACUOUSLY, and a green vacuous suite is worse than none.
    ///
    ///      `afterInvariant` runs once per RUN, so asserting "this run settled a
    ///      claim" would be a coin flip on the runner's choices, not a property.
    ///      It checks only what the seeded cohort guarantees; the reachability of
    ///      the deep states is proved deterministically below instead.
    function afterInvariant() public view {
        assertGt(handler.callsStake(), 0, "the cohort was never seeded");
    }

    /// @dev Time moves directly here. `hRoll` caps at 80 blocks so the fuzz runner
    ///      cannot leap a 240-block commit window in a single step; crossing a
    ///      12-hour challenge window that way would take 108 external calls, which
    ///      is a fine constraint on the RUNNER and a pointless one on a scripted
    ///      reachability proof.
    function _advance(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 5);
    }

    /// @notice Proof that the handler CAN reach the states the invariants care
    ///         about — driven deterministically, so it cannot flake.
    /// @dev Without this the suite could be green because the runner never got past
    ///      `submit`, and nobody would know. This is the coverage claim, made once
    ///      and checked, rather than assumed from 16,384 calls of unknown shape.
    function test_handlerReachesCommitRevealDrawAndSettlement() public {
        handler.hSubmit(1);
        assertEq(handler.caseCount(), 1, "a case exists");
        uint256 id = handler.caseIds(0);

        _advance(3); // past the eligibility seed block
        for (uint256 i; i < 6; ++i) {
            handler.hCommit(i, 0, i);
        }
        assertGt(handler.callsCommit(), 0, "commits are reachable");

        _advance(240);
        handler.hPoke(0);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL), "COMMIT -> REVEAL");
        for (uint256 i; i < 6; ++i) {
            handler.hReveal(i, 0);
        }
        assertGt(handler.callsReveal(), 0, "reveals are reachable");

        _advance(240);
        handler.hPoke(0);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.TALLY), "REVEAL -> TALLY");

        _advance(8640);
        handler.hPoke(0);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.DRAW), "TALLY -> DRAW");

        _advance(600); // past outcomeSeedBlock, inside the horizon
        handler.hPoke(0);
        assertTrue(mod.caseInfo(id).terminal != uint8(Moderation.Terminal.NONE), "a terminal is reachable");
        assertGt(handler.callsPoke(), 0);

        // The index carries it before anybody settles (§8.1).
        bytes32[] memory tp = handler.topicsOf();
        assertTrue(
            idx.statusOf(mod.caseInfo(id).claimKey, tp[0]) != uint8(IndexRegistry.Status.NONE),
            "the reader sees a result without waiting for settlement"
        );

        for (uint256 i; i < 6; ++i) {
            handler.hClaim(i, 0);
        }
        assertGt(handler.callsClaim(), 0, "settlement is reachable");

        // And every ledger invariant holds at the end of a real lifecycle.
        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets());
        assertTrue(reg.solvent());
    }

    /// @notice I27 — a pinned parameter block is IMMUTABLE.
    ///
    /// @dev The invariant I27 actually rests on, and the one a stateful runner can
    ///      falsify where a unit test cannot. "Every debit is computed from the block
    ///      pinned at submission" is worth nothing if that block can be rewritten
    ///      afterwards — a governance change that mutated version 1 in place would
    ///      satisfy every per-case assertion in the other suites while silently
    ///      re-pricing every live case.
    ///
    ///      The handler changes `lambda` through the real governor mid-run, so this
    ///      is checked against sequences where a change actually landed between a
    ///      case's submission and its settlement.
    function invariant_i27_aPinnedParameterBlockIsImmutable() public view {
        uint32 top = handler.highestVersion();
        for (uint32 v = 1; v <= top; ++v) {
            uint128 recorded = handler.versionLambda(v);
            if (recorded == 0) continue; // not a version this handler created
            assertEq(mod.paramsAt(v).lambda, recorded, "a pinned parameter block moved under a live case");
        }
    }

    /// @notice Every case pins a version that exists and is not the future.
    function invariant_i27_everyCasePinsARealVersion() public view {
        uint256 n = handler.caseCount();
        uint32 live = mod.paramsVersion();
        for (uint256 i; i < n; ++i) {
            uint32 pinned = mod.caseInfo(handler.caseIds(i)).paramsVersion;
            assertGt(pinned, 0, "a case with no pinned version");
            assertLe(pinned, live, "a case pinned a version that does not exist yet");
        }
    }

    /// @dev Drives a case in DRAW to a chosen verdict through the handler, by
    ///      picking an entropy `decideAt` says produces it. The contract still does
    ///      the deciding; this only chooses which block hash it reads.
    function _pokeToVerdict(uint256 caseId, uint256 slot, uint8 want) internal {
        uint256 sb = mod.caseInfo(caseId).outcomeSeedBlock;
        for (uint256 i; i < 4096; ++i) {
            bytes32 h = keccak256(abi.encode("inv-entropy", caseId, i));
            (uint8 v,) = mod.decideAt(caseId, h);
            if (v != want) continue;
            vm.setBlockhash(sb, h);
            handler.hPoke(slot);
            return;
        }
        assertTrue(false, "no entropy produced the wanted verdict");
    }

    /// @dev M2.11. A governance action the fuzzer never performs is a governance
    ///      action nobody is testing the invariants against, so the reachability of
    ///      `hChangeParams` is pinned here rather than assumed from a call count.
    function test_handlerReachesAParameterChange() public {
        uint32 before = mod.paramsVersion();
        handler.hChangeParams(12345);

        assertEq(handler.callsParamChange(), 1, "a parameter change is reachable from the handler");
        assertEq(mod.paramsVersion(), before + 1, "and it landed in Moderation");
        assertGt(handler.versionLambda(before + 1), 0, "with the ghost recording what it landed as");

        // It went through the governor's timelock, not around it.
        assertEq(mod.governor(), address(governor));
    }

    /// @dev M2.12. The governor handover is the widest-blast-radius sequence in the
    ///      system — the contract holding parameter authority is replaced while
    ///      cases are live — so the invariants must be able to reach it.
    function test_handlerReachesAGovernorHandover() public {
        address before = mod.governor();
        handler.hRotateGovernor(1);

        assertEq(handler.callsGovernorChange(), 1, "the handover is reachable");
        assertTrue(mod.governor() != before, "Moderation moved");
        assertEq(address(handler.governor()), mod.governor(), "and the handler follows it");
        assertEq(address(handler.governor().moderation()), address(mod), "the successor is bound");
        assertTrue(governor.retired(), "the old one is retired");

        // And the system still works through the new governor.
        uint32 v = mod.paramsVersion();
        handler.hChangeParams(999);
        assertEq(mod.paramsVersion(), v + 1, "parameters still move, through the successor");

        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets());
        assertTrue(reg.solvent());
    }

    /// @dev M2.10. The stateful suite is only as good as what the handler can
    ///      reach, and a removal case is reachable ONLY from an approved listing —
    ///      several conditional steps deeper than anything else the handler does.
    ///      This pins that the path is enterable, so the invariants above are
    ///      actually being evaluated against removal cases rather than silently
    ///      skipping them.
    function test_handlerReachesTheRemovalCase() public {
        handler.hSubmit(1);
        uint256 listCase = handler.caseIds(0);
        bytes32[] memory tp = handler.topicsOf();

        _advance(3);
        for (uint256 i; i < 6; ++i) {
            handler.hCommit(i, 0, 1); // all Approve
        }
        _advance(240);
        handler.hPoke(0);
        for (uint256 i; i < 6; ++i) {
            handler.hReveal(i, 0);
        }
        _advance(240);
        handler.hPoke(0); // -> TALLY
        _advance(8640);
        handler.hPoke(0); // -> DRAW
        _advance(600);
        _pokeToVerdict(listCase, 0, uint8(Moderation.Outcome.APPROVE));

        bytes32 lk = mod.caseInfo(listCase).claimKey;
        assertTrue(idx.isListed(lk, tp[0]), "the listing exists, which is the precondition");

        // Now the removal is reachable, and it is a REAL case in the same machine.
        handler.hSubmitRemoval(2, 0);
        assertEq(handler.callsRemoval(), 1, "the removal path is enterable from the handler");
        assertEq(handler.caseCount(), 2, "and it is a case like any other");

        uint256 rm = handler.caseIds(1);
        assertEq(idx.entryOf(lk, tp[0]).openQuestions, 1, "S8.3 - the question is open against the listing");

        _advance(3);
        for (uint256 i; i < 6; ++i) {
            handler.hCommit(i, 1, 1); // all Approve == REMOVE IT
        }
        _advance(240);
        handler.hPoke(1);
        for (uint256 i; i < 6; ++i) {
            handler.hReveal(i, 1);
        }
        _advance(240);
        handler.hPoke(1);
        _advance(8640);
        handler.hPoke(1);
        _advance(600);
        _pokeToVerdict(rm, 1, uint8(Moderation.Outcome.APPROVE));

        assertEq(uint8(idx.entryOf(lk, tp[0]).status), uint8(IndexRegistry.Status.REMOVED), "the fifth write fired");
        assertFalse(idx.isListed(lk, tp[0]), "and the listing is gone");
        assertEq(uint8(mod.reservationOf(lk)), uint8(Moderation.Reservation.FREE), "resubmittable");

        // The ledger invariants still hold across a path that only M2.10 opened.
        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets());
        assertTrue(reg.solvent());
    }

}
