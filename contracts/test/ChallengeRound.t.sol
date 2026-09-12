// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice The second round, end to end.
///
/// Every gap here was found by mutation testing, and each one is a path no test
/// walked. `Lifecycle.t.sol` opens a challenge and stops; nothing carried one
/// through to a second draw, so a mutant that made the second draw impossible
/// survived, as did one that decremented the tally when a Reject outcome was
/// challenged.
contract ChallengeRoundTest is Test {
    Moderation mod;
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;

    uint256 constant COMMIT_WINDOW = 15 minutes;
    uint256 constant REVEAL_WINDOW = 30 minutes;
    uint256 constant CHALLENGE_WINDOW = 1 hours;
    uint256 constant MAX_WAIT = 1 hours;
    uint256 constant FREEZE = 8 days;
    uint256 constant SEED_LAG = 2;
    uint256 constant FEE = 1000;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    address submitter = address(0x5011);
    address[12] mods;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(
            address(token), address(stakes), address(index),
            COMMIT_WINDOW, REVEAL_WINDOW, CHALLENGE_WINDOW, MAX_WAIT, FREEZE, SEED_LAG, FEE
        );
        for (uint256 i; i < mods.length; ++i) {
            mods[i] = address(uint160(0x1000 + i));
            stakes.add(mods[i]);
        }
        token.mint(submitter, 1_000_000);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);
        vm.roll(blk);
        vm.warp(ts);
    }

    function _advance(uint256 n) internal { blk += n; vm.roll(blk); }
    function _wait(uint256 n) internal { ts += n; vm.warp(ts); }

    function _submit() internal returns (uint256 id) {
        bytes32[] memory t = new bytes32[](1);
        t[0] = keccak256("biology");
        vm.prank(submitter);
        id = mod.submit(keccak256("content"), keccak256("meta"), t, FEE);
    }

    function _commit(uint256 id, address m, uint8 v, uint8 round) internal {
        bytes32 h = mod.commitHash(id, round, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    /// @dev Runs one full pair-of-committees round: A commits, B commits, both
    ///      reveal, tickets drawn. `voters` is the inclusive range of moderator
    ///      indices, all voting `v`.
    function _round(uint256 id, uint8 round, uint256 from, uint256 to, uint8 v) internal {
        _advance(SEED_LAG + 1);
        for (uint256 i = from; i < to; ++i) _commit(id, mods[i], v, round);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i = from; i < to; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, v, bytes32("s"));
        }
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
    }

    // -----------------------------------------------------------------

    /// @dev **The whole second round.** A challenge resets the per-committee
    ///      counters and the outcome seed; if the reset left the seed unusable,
    ///      the case could never be drawn again and would sit in REVEAL until
    ///      its deadline. Nothing tested past the challenge itself.
    function test_challengeRunsThroughToASecondDraw() public {
        uint256 id = _submit();
        _round(id, 0, 0, 4, APPROVE);
        assertEq(mod.caseInfo(id).preliminary, APPROVE);

        vm.prank(mods[11]);
        mod.challenge(id); // a Reject vote, against the Approve outcome

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.challenges, 1);
        assertEq(c.outcomeSeedBlock, 0, "the seed is cleared for the new round");
        assertEq(c.phase, uint8(Moderation.Phase.COMMIT_A));

        // round 1, with fresh voters — this is the part nothing reached
        _round(id, 1, 4, 9, REJECT);

        c = mod.caseInfo(id);
        assertEq(c.pooledApprove, 4, "round 0's approvals carried forward");
        assertEq(c.pooledReject, 6, "the challenge vote plus round 1's five");
        assertEq(c.phase, uint8(Moderation.Phase.CHALLENGE), "a second window opened");

        // The outcome is DRAWN, not decided by the majority: 4 of 10 approve is
        // f(0.4) = 35.2%, so asserting REJECT here would be asserting a coin
        // flip. What is deterministic is the pool it was drawn from, and that a
        // second draw happened at all — which is the property under test.
        assertTrue(
            c.preliminary == APPROVE || c.preliminary == REJECT, "an outcome was drawn"
        );
        uint8 drawn = c.preliminary;

        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
        assertEq(index.writes(), drawn == APPROVE ? 1 : 0, "listed iff approved");
    }

    /// @dev Challenging a REJECT outcome. The challenge casts an APPROVE vote,
    ///      which is the other branch of the tally update — and no test had ever
    ///      taken it, so a mutant decrementing it instead of incrementing
    ///      survived.
    function test_challengingARejectAddsAnApproveVote() public {
        uint256 id = _submit();
        _round(id, 0, 0, 4, REJECT);
        assertEq(mod.caseInfo(id).preliminary, REJECT);

        uint32 before = mod.caseInfo(id).pooledApprove;
        vm.prank(mods[11]);
        mod.challenge(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.pooledApprove, before + 1, "the challenge voted Approve");
        assertEq(c.pooledReject, 4, "and the rejections stand");
        assertTrue(c.everChallenged);
    }

    /// @dev An Approve voter incoherent with a Reject outcome must be frozen.
    ///      Every previous freeze test had the dissenter voting Reject against an
    ///      Approve outcome, so the mirrored case was untested.
    function test_approveVoterIsFrozenWhenTheOutcomeIsReject() public {
        uint256 id = _submit();

        _advance(SEED_LAG + 1);
        for (uint256 i; i < 4; ++i) _commit(id, mods[i], REJECT, 0);
        _commit(id, mods[4], APPROVE, 0); // the lone dissenter, voting Approve
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i; i < 4; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, REJECT, bytes32("s"));
        }
        vm.prank(mods[4]);
        mod.reveal(id, APPROVE, bytes32("s"));

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);

        assertEq(mod.caseInfo(id).preliminary, REJECT, "4-1 reject");
        mod.claim(id, mods[4]);
        assertEq(stakes.totalFrozen(mods[4]), FREEZE, "the Approve dissenter is frozen");
        assertEq(token.balanceOf(mods[4]), 0);
    }

    /// @dev The eligibility seed must be a FUTURE block at submission. If it were
    ///      a past one, the submitter could compute the committee before paying,
    ///      and resubmit until it looked favourable — which is the whole attack
    ///      the staged selection exists to make harder.
    function test_eligibilitySeedIsAlwaysInTheFuture() public {
        uint256 id = _submit();
        assertGt(mod.caseInfo(id).seedBlockA, block.number, "seed A is ahead of submission");

        // and committee B's, when it is armed
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        uint256 atClose = block.number;
        mod.closeCommitA(id);
        assertGt(mod.caseInfo(id).seedBlockB, atClose, "seed B is ahead of A's close");
    }

    /// @dev Nobody may commit once the deadline has arrived — at it, not after
    ///      it. The comparison is `>=`, and a mutant relaxing it to `>` bought an
    ///      extra block that no test noticed.
    function test_cannotCommitAtTheDeadlineItself() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE, 0);

        uint256 deadline = mod.caseInfo(id).phaseDeadline;
        vm.warp(deadline - 1);
        _commit(id, mods[3], APPROVE, 0); // one second before: fine

        vm.warp(deadline);
        bytes32 h = mod.commitHash(id, 0, mods[4], APPROVE, bytes32("s"));
        vm.prank(mods[4]);
        vm.expectRevert(Moderation.TooLate.selector);
        mod.commit(id, h);
    }

    function test_topicCountIsBounded() public {
        bytes32[] memory none = new bytes32[](0);
        vm.prank(submitter);
        vm.expectRevert(Moderation.BadTopics.selector);
        mod.submit(keccak256("a"), keccak256("b"), none, FEE);

        bytes32[] memory many = new bytes32[](6);
        for (uint256 i; i < 6; ++i) many[i] = keccak256(abi.encode(i));
        vm.prank(submitter);
        vm.expectRevert(Moderation.BadTopics.selector);
        mod.submit(keccak256("a"), keccak256("b"), many, FEE);
    }
}
