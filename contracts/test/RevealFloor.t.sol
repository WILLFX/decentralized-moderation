// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice §11's per-committee minimum, counted on REVEALS — the mechanism and
///         its two asymmetric failure paths.
///
/// The floor is enforced at `closeReveal`, the first moment both committees'
/// revealed counts are final. What a failure means depends on whether anything
/// was decided yet, and the two cases are deliberately NOT symmetric:
///
/// - **first round**: no outcome exists, so the case is UNRESOLVED and the fee is
///   refunded. The publisher paid for a judgment that never happened.
/// - **challenge round**: a preliminary outcome already stands. Voiding the case
///   would let any challenger destroy a decided case by challenging and then
///   bringing nobody, so the standing outcome finalizes instead — and the
///   challenger is frozen for a vote that changed nothing.
contract RevealFloorTest is Test {
    Moderation mod;
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;

    address submitter = address(0x5011);
    address[16] mods;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;
    uint256 constant COMMIT_WINDOW = 15 minutes;
    uint256 constant REVEAL_WINDOW = 30 minutes;
    uint256 constant CHALLENGE_WINDOW = 1 hours;
    uint256 constant MAX_WAIT = 1 hours;
    uint256 constant FREEZE = 8 days;
    uint256 constant SEED_LAG = 2;
    uint256 constant FEE = 1000;

    /// @dev The deployed value (`Deploy.defaults`), not the weakest one, because
    ///      this suite is about the floor rather than about the lifecycle.
    uint256 constant FLOOR = 3;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            COMMIT_WINDOW, REVEAL_WINDOW, CHALLENGE_WINDOW, MAX_WAIT, FREEZE, SEED_LAG, FEE, FLOOR,
            1, keccak256("g")));
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

    function _advance(uint256 n) internal {
        blk += n;
        vm.roll(blk);
    }

    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function _submit() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        id = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    function _commit(uint256 id, address m, uint8 v, uint8 round) internal {
        bytes32 h = mod.commitHash(id, round, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    function _reveal(uint256 id, address m, uint8 v) internal {
        vm.prank(m);
        mod.reveal(id, v, bytes32("s"));
    }

    /// @dev Walks a round: `aCount` moderators from `aFrom` in committee A and
    ///      `bCount` from `bFrom` in B, all voting `v`, all revealing, then closes
    ///      the reveal phase.
    ///
    ///      The offsets are not decoration. A moderator votes **once per case**,
    ///      not once per round, so a challenge round has to be staffed by
    ///      moderators who did not vote in the first one.
    function _round(
        uint256 id,
        uint8 round,
        uint256 aFrom,
        uint256 aCount,
        uint256 bFrom,
        uint256 bCount,
        uint8 v
    ) internal {
        _advance(SEED_LAG + 1);
        for (uint256 i; i < aCount; ++i) _commit(id, mods[aFrom + i], v, round);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        _advance(SEED_LAG + 1);
        for (uint256 i; i < bCount; ++i) _commit(id, mods[bFrom + i], v, round);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i; i < aCount; ++i) _reveal(id, mods[aFrom + i], v);
        for (uint256 i; i < bCount; ++i) _reveal(id, mods[bFrom + i], v);

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
    }

    /// @dev Round 0 staffed from the low block of moderators, leaving the high
    ///      block free for a challenge round.
    function _firstRound(uint256 id, uint256 aCount, uint256 bCount, uint8 v) internal {
        _round(id, 0, 0, aCount, 6, bCount, v);
    }

    // ----------------------------------------------------- the floor itself

    function test_constructorRejectsAFloorOfZero() public {
        vm.expectRevert(Moderation.BadFloor.selector);
        new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            COMMIT_WINDOW, REVEAL_WINDOW, CHALLENGE_WINDOW, MAX_WAIT, FREEZE, SEED_LAG, FEE, 0,
            1, keccak256("g")));
    }

    function test_bothCommitteesAtTheFloorResolvesNormally() public {
        uint256 id = _submit();
        _firstRound(id, FLOOR, FLOOR, APPROVE);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL), "still REVEAL until draw");
        assertGt(mod.caseInfo(id).outcomeSeedBlock, 0, "the outcome seed was armed");

        _advance(SEED_LAG + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, APPROVE);
    }

    /// @dev One short in committee B, everything else identical. The floor is
    ///      per-committee, so a healthy A cannot cover for B — which is the whole
    ///      reason the specification insisted the threshold not be combined.
    function test_oneShortInCommitteeBDoesNotResolve() public {
        uint256 id = _submit();
        _firstRound(id, FLOOR + 3, FLOOR - 1, APPROVE);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.refundOwed(id), FEE, "the fee goes back");
        assertEq(index.writes(), 0, "nothing listed");
        assertEq(mod.caseInfo(id).outcomeSeedBlock, 0, "no seed was armed");
    }

    function test_oneShortInCommitteeADoesNotResolve() public {
        uint256 id = _submit();
        _firstRound(id, FLOOR - 1, FLOOR + 3, APPROVE);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.refundOwed(id), FEE);
    }

    /// @dev A commit is not a reveal. Both committees commit well past the floor
    ///      and then withhold down to one short of it — the arrangement a floor
    ///      counted on COMMITS would have waved through.
    function test_commitsAboveTheFloorDoNotSubstituteForReveals() public {
        uint256 id = _submit();

        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR + 2; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR + 2; ++i) _commit(id, mods[6 + i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.commitsA, FLOOR + 2, "committee A committed above the floor");
        assertEq(c.commitsB, FLOOR + 2, "and so did committee B");

        // every committee reveals one short of the floor
        for (uint256 i; i < FLOOR - 1; ++i) _reveal(id, mods[i], APPROVE);
        for (uint256 i; i < FLOOR - 1; ++i) _reveal(id, mods[6 + i], APPROVE);

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED), "commits do not count");
    }

    // --------------------------------------------- non-reveal is not free

    /// @dev The vector the floor opens, and the reason a non-revealer is frozen
    ///      even on a case with no verdict. Without this, a moderator whose reveal
    ///      was needed to reach the floor could withhold, refund the publisher,
    ///      list nothing, and repeat indefinitely at zero cost.
    function test_nonRevealerIsFrozenOnAnUnresolvedCase() public {
        uint256 id = _submit();

        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR; ++i) _commit(id, mods[6 + i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        // committee A reveals in full; ONE member of B withholds, taking B below
        // the floor and killing a case that was otherwise going to resolve
        for (uint256 i; i < FLOOR; ++i) _reveal(id, mods[i], APPROVE);
        for (uint256 i; i < FLOOR - 1; ++i) _reveal(id, mods[6 + i], APPROVE);
        address withholder = mods[6 + FLOOR - 1];

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));

        mod.claim(id, withholder);
        assertEq(stakes.totalFrozen(withholder), FREEZE, "withholding is not free");

        // and the moderators who did reveal are not punished for someone else
        mod.claim(id, mods[0]);
        assertEq(stakes.totalFrozen(mods[0]), 0, "a revealer on a dead case is clean");
        assertEq(token.balanceOf(mods[0]), 0, "and paid nothing: there is no outcome");
    }

    /// @dev On a resolved case, withholding costs the same as being wrong. If it
    ///      cost less, anyone expecting to be incoherent would withhold and
    ///      revealing would be the dominated move.
    function test_nonRevealCostsTheSameAsBeingWrong() public {
        uint256 id = _submit();

        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR; ++i) _commit(id, mods[i], APPROVE, 0);
        _commit(id, mods[4], REJECT, 0); // will reveal, and lose
        _commit(id, mods[5], REJECT, 0); // will withhold
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        for (uint256 i; i < FLOOR; ++i) _commit(id, mods[6 + i], APPROVE, 0);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i; i < FLOOR; ++i) _reveal(id, mods[i], APPROVE);
        for (uint256 i; i < FLOOR; ++i) _reveal(id, mods[6 + i], APPROVE);
        _reveal(id, mods[4], REJECT);
        // mods[5] never reveals

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);
        assertEq(mod.caseInfo(id).preliminary, APPROVE, "6-1 approve, unanimous-ish under A/N");

        mod.claim(id, mods[4]);
        mod.claim(id, mods[5]);
        assertEq(stakes.totalFrozen(mods[4]), FREEZE, "revealed and wrong");
        assertEq(
            stakes.totalFrozen(mods[5]), stakes.totalFrozen(mods[4]), "withheld: the same price"
        );
    }

    // ------------------------------------ the challenge round is different

    /// @dev A challenge whose committees do not materialise must NOT void the
    ///      case. If it did, any challenger could destroy a decided case by
    ///      challenging and then bringing nobody.
    function test_aChallengeRoundBelowTheFloorLetsTheStandingOutcomeFinalize() public {
        uint256 id = _submit();
        _firstRound(id, FLOOR, FLOOR, APPROVE);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, APPROVE, "the outcome that must survive");

        address challenger = mods[15];
        vm.prank(challenger);
        mod.challenge(id);
        assertEq(mod.caseInfo(id).challenges, 1);

        // the challenge round draws nobody at all
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.phase, uint8(Moderation.Phase.FINALIZED), "finalized, NOT unresolved");
        assertEq(c.preliminary, APPROVE, "the outcome that was challenged stands");
        assertEq(mod.refundOwed(id), 0, "the fee is not refunded: a judgment happened");
        assertEq(index.writes(), 1, "and the entry is written");

        // the challenger voted against the outcome that finalized, so they are
        // frozen — a vote that changed nothing and still cost the liability
        mod.claim(id, challenger);
        assertEq(stakes.totalFrozen(challenger), FREEZE, "a failed challenge is not free");
    }

    /// @dev The other half: a challenge round that DOES reach the floor gets its
    ///      fresh draw over the whole pool, so the floor has not disabled
    ///      challenges.
    function test_aChallengeRoundAtTheFloorStillRedraws() public {
        uint256 id = _submit();
        _firstRound(id, FLOOR, FLOOR, REJECT);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, REJECT);

        vm.prank(mods[15]);
        mod.challenge(id); // an Approve vote
        assertEq(mod.caseInfo(id).pooledApprove, 1);

        // staffed from moderators who did not vote in round 0
        _round(id, 1, 3, FLOOR, 9, FLOOR, APPROVE);
        _advance(SEED_LAG + 1);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.pooledApprove, 1 + 2 * FLOOR, "the challenge round's votes joined the pool");
        assertEq(c.pooledReject, 2 * FLOOR, "and round 0's are still there");
        assertEq(c.preliminary, APPROVE, "7-6 approve, redrawn over the whole pool");
    }
}
