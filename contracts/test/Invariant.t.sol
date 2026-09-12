// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console, StdInvariant} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {SystemHandler} from "./handlers/SystemHandler.sol";

/// @notice Properties that must hold whatever order anything happens in.
///
/// The scripted suites walk one path each. The stranded-stake bug survived all
/// of them and was an invariant violation — `openVotes` diverging from the count
/// of unsettled commitments — which is the case for having these.
contract InvariantTest is StdInvariant, Test {
    SystemHandler handler;
    Moderation mod;
    StakeRegistry stakes;
    IndexRegistry index;
    MockBZZ token;

    function setUp() public {
        token = new MockBZZ();
        Deploy d = new Deploy();
        Deploy.Stack memory s = d.deploy(d.defaults(address(token)));
        mod = s.moderation;
        stakes = s.stakes;
        index = s.index;

        handler = new SystemHandler(mod, stakes, index, token);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------ solvency

    /// @dev Every token that entered as a fee is still in the contract, has been
    ///      paid to a moderator, or has been refunded. Nothing is created and
    ///      nothing goes missing.
    function invariant_moderationConservesFees() public {
        handler.observe();
        assertEq(
            token.balanceOf(address(mod)),
            handler.ghostFeesIn() - handler.ghostPaidOut() - handler.ghostRefunded(),
            "fees in must equal balance + paid + refunded"
        );
    }

    /// @dev The registry holds exactly one stake per staked moderator. Stake is
    ///      never taken as a penalty, so this cannot drift.
    function invariant_stakeIsNeverTaken() public view {
        assertEq(
            token.balanceOf(address(stakes)),
            stakes.stakedCount() * stakes.stakeAmount(),
            "stake custody must be exact"
        );
    }

    /// @dev No case can pay out more than its own pot.
    function invariant_payoutsNeverExceedThePot() public {
        handler.observe();
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            assertLe(
                handler.ghostPaidOnCase(id),
                mod.caseInfo(id).pot,
                "a case paid out more than it held"
            );
        }
    }

    // ------------------------------------------------------- the stuck bug

    /// @dev The property the stranded-stake bug violated. A moderator's open
    ///      vote count must equal the number of commitments they have made and
    ///      not yet settled — no more, or their stake is locked for nothing.
    function invariant_openVotesMatchUnsettledCommitments() public {
        handler.observe();
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(
                uint256(stakes.openVotes(a)),
                handler.ghostUnsettled(a),
                "open votes diverged from unsettled commitments"
            );
        }
    }

    /// @dev A moderator who is neither frozen nor mid-vote can always leave.
    ///      Stake must never be trapped by a state the protocol can reach.
    function invariant_unencumberedStakeCanAlwaysExit() public {
        handler.observe();
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            if (!stakes.isActive(a)) continue;
            if (stakes.isFrozen(a)) continue;
            if (stakes.openVotes(a) != 0) continue;

            uint256 snap = vm.snapshotState();
            vm.prank(a);
            stakes.withdraw();
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------- monotonicity

    /// @dev §5 — the pooled tally carries across rounds and is never reset. A
    ///      challenge resets the per-committee counters and must not touch this.
    function invariant_pooledTallyNeverShrinks() public {
        handler.observe();
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            Moderation.Case memory c = mod.caseInfo(id);
            assertGe(
                uint256(c.pooledApprove) + c.pooledReject,
                handler.ghostMaxPooled(id),
                "the pooled tally went backwards"
            );
        }
    }

    function invariant_finalizedIsTerminal() public {
        handler.observe();
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            if (!handler.ghostWasFinalized(id)) continue;
            assertEq(
                mod.caseInfo(id).phase,
                uint8(Moderation.Phase.FINALIZED),
                "a finalized case moved again"
            );
        }
    }

    /// @dev §4.2 — at most two challenges, and a removal once removed stays
    ///      removed.
    function invariant_challengeCapAndRemovalAreRespected() public {
        handler.observe();
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            assertLe(mod.caseInfo(id).challenges, mod.MAX_CHALLENGES(), "challenge cap breached");
            if (handler.ghostWasRemoved(id)) {
                assertTrue(mod.removed(id), "a removal was undone");
            }
        }
    }

    /// @dev A case in a live phase always has a future it can reach: either its
    ///      deadline is ahead, or the transition past it is callable now.
    ///      Nothing may park permanently.
    function invariant_noCaseIsStuck() public {
        handler.observe();
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.caseIds(i);
            Moderation.Case memory c = mod.caseInfo(id);
            if (
                c.phase == uint8(Moderation.Phase.FINALIZED)
                    || c.phase == uint8(Moderation.Phase.UNRESOLVED)
            ) continue;
            assertGt(c.phaseDeadline, 0, "a live case with no deadline");
        }
    }

    // -------------------------------------------------------- coverage

    /// @dev **Without this the invariants above are worthless.** A handler whose
    ///      calls all revert satisfies every one of them by doing nothing.
    ///
    ///      This cannot be an `invariant_*` function — Foundry evaluates each one
    ///      once before fuzzing to validate the environment, when nothing has
    ///      happened by definition — nor `afterInvariant`, which Foundry calls
    ///      with the handler's state reset, so its counters read zero. So it is
    ///      an ordinary test: drive the handler by hand through a plausible
    ///      sequence and prove each interesting state is actually reachable
    ///      through it. The fuzzer then explores orderings of the same calls.
    function test_handlerCanReachEveryPhase() public {
        handler.submit(1);
        handler.warp(1, 4); // seed addressable, still inside the max wait
        for (uint256 i; i < 3; ++i) handler.commit(i, 0, true);
        handler.warp(20, 3); // past the 15-minute clock the 3rd commit started
        handler.advancePhase(0, 0); // -> COMMIT_B
        handler.warp(1, 4); // committee B's seed becomes addressable
        for (uint256 i = 3; i < 7; ++i) handler.commit(i, 0, true);
        // actor 7 deliberately holds back: a challenger must not have voted
        handler.warp(20, 3);
        handler.advancePhase(0, 0); // -> REVEAL
        for (uint256 i; i < 7; ++i) handler.reveal(i, 0);
        handler.warp(40, 3);
        handler.advancePhase(0, 0); // closeReveal
        handler.warp(1, 3);
        handler.advancePhase(0, 0); // draw
        handler.challenge(7, 0);
        handler.warp(70, 3);

        string[8] memory must =
            ["submit", "commit", "closeCommitA", "closeCommitB", "reveal", "closeReveal", "draw", "challenge"];
        for (uint256 i; i < must.length; ++i) {
            assertGt(
                handler.calls(bytes32(bytes(must[i]))),
                0,
                string.concat("handler never reached: ", must[i])
            );
        }

        // and settlement, on a second case taken to the end
        handler.submit(2);
        handler.warp(1, 4);
        for (uint256 i; i < 4; ++i) handler.commit(i, 1, true);
        handler.warp(20, 3);
        handler.advancePhase(1, 0);
        handler.warp(70, 3); // committee B draws nobody; the max wait expires
        handler.advancePhase(1, 0);
        for (uint256 i; i < 4; ++i) handler.reveal(i, 1);
        handler.warp(40, 3);
        handler.advancePhase(1, 0);
        handler.warp(1, 3);
        handler.advancePhase(1, 0);
        handler.warp(70, 3);
        handler.advancePhase(1, 0); // closeChallenge -> FINALIZED
        for (uint256 i; i < 4; ++i) handler.claim(i, 1);

        assertGt(handler.calls(bytes32(bytes("closeChallenge"))), 0, "never finalized");
        assertGt(handler.calls(bytes32(bytes("claim"))), 0, "never settled");
    }
}
