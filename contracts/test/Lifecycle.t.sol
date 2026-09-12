// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// @notice Stake custody reduced to what `specs/protocol.md` §2 asks for: a
///         stake, and a total frozen time. No bond, no liabilities, no claims.
contract MockStakes {
    mapping(address => bool) public active;
    mapping(address => uint256) public frozenUntil;
    mapping(address => uint256) public totalFrozen;
    uint256 public stakedCount;

    function add(address a) external {
        active[a] = true;
        ++stakedCount;
    }

    function isActive(address a) external view returns (bool) {
        return active[a];
    }

    function isFrozen(address a) external view returns (bool) {
        return frozenUntil[a] > block.timestamp;
    }

    /// @dev §2 — durations are ADDITIVE to a total, not extensions from now, so
    ///      the same losses cost the same whatever order they settle in.
    function freeze(address a, uint256 duration) external {
        totalFrozen[a] += duration;
        uint256 base = frozenUntil[a] > block.timestamp ? frozenUntil[a] : block.timestamp;
        frozenUntil[a] = base + duration;
    }
}

contract MockIndex {
    struct Entry {
        bool written;
        bool allTicketsApprove;
        bool everChallenged;
    }

    mapping(bytes32 => Entry) public entries;
    uint256 public writes;

    function writeEntry(bytes32 claimKey, bytes32, uint8, bool allTicketsApprove, bool everChallenged)
        external
    {
        entries[claimKey] = Entry(true, allTicketsApprove, everChallenged);
        ++writes;
    }
}

contract LifecycleTest is Test {
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

    address submitter = address(0x5011);
    address[8] mods;

    /// @dev Block height tracked explicitly. `block.number` is cached within a
    ///      call frame, so `vm.roll(block.number + n)` silently no-ops after the
    ///      first read in a test body.
    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function _advance(uint256 n) internal {
        blk += n;
        vm.roll(blk);
    }

    /// @dev `block.timestamp` is cached in a call frame for the same reason, so
    ///      time is tracked explicitly too.
    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(
            address(token),
            address(stakes),
            address(index),
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            CHALLENGE_WINDOW,
            MAX_WAIT,
            FREEZE,
            SEED_LAG,
            FEE
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

    function _submit() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        id = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    function _commit(uint256 id, address m, uint8 v, uint8 round) internal {
        // the hash is computed BEFORE the prank: `commitHash` is an external
        // call and would otherwise consume it, leaving `commit` to arrive from
        // the test contract
        bytes32 h = mod.commitHash(id, round, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    function _reveal(uint256 id, address m, uint8 v) internal {
        vm.prank(m);
        mod.reveal(id, v, bytes32("s"));
    }

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    // ---------------------------------------------------------------------

    /// @dev The property the staging exists for: while committee A is committing,
    ///      committee B's seed height has not been armed, so nobody — attacker
    ///      included — can compute who will be in it.
    function test_committeeBIsUnknowableWhileACommits() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);

        Moderation.Case memory c = mod.caseInfo(id);
        assertGt(c.seedBlockA, 0, "A seeded at submission");
        assertEq(c.seedBlockB, 0, "B NOT seeded while A commits");

        _commit(id, mods[0], APPROVE, 0);
        _commit(id, mods[1], APPROVE, 0);
        _commit(id, mods[2], APPROVE, 0);

        c = mod.caseInfo(id);
        assertEq(c.seedBlockB, 0, "still not seeded after A's third commit");

        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitA(id);

        c = mod.caseInfo(id);
        assertGt(c.seedBlockB, 0, "seeded only once A closed");
    }

    /// @dev §4.1 — three commitments start a 15-minute clock. They are not a
    ///      quorum, and a fourth commit does not extend the deadline.
    function test_thirdCommitStartsTheClockAndLaterCommitsDoNot() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);

        uint256 opened = mod.caseInfo(id).phaseDeadline;
        assertEq(opened, ts + MAX_WAIT, "max wait until the third");

        _commit(id, mods[0], APPROVE, 0);
        _commit(id, mods[1], APPROVE, 0);
        assertEq(mod.caseInfo(id).phaseDeadline, opened, "two commits change nothing");

        _commit(id, mods[2], APPROVE, 0);
        uint256 pinned = mod.caseInfo(id).phaseDeadline;
        assertEq(pinned, ts + COMMIT_WINDOW, "third pins it");

        _wait(1 minutes);
        _commit(id, mods[3], APPROVE, 0);
        assertEq(mod.caseInfo(id).phaseDeadline, pinned, "fourth does not extend");
    }

    function test_fullLifecycleToApproval() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);

        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitA(id);

        _advance(SEED_LAG + 1);
        for (uint256 i = 3; i < 6; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitB(id);

        // both committees reveal in the SAME phase — B never saw A's tally
        for (uint256 i; i < 6; ++i) _reveal(id, mods[i], APPROVE);

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.phase, uint8(Moderation.Phase.CHALLENGE), "challenge window open");
        assertEq(c.preliminary, APPROVE, "unanimous approve under A/N");
        assertEq(c.pooledApprove, 6);

        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
        assertEq(index.writes(), 1, "index written once per topic");

        // §4.3 — no money before finalization; now it moves
        uint256 before = token.balanceOf(mods[0]);
        mod.claim(id, mods[0]);
        assertEq(token.balanceOf(mods[0]) - before, FEE / 6, "share of the pot");
        assertEq(stakes.totalFrozen(mods[0]), 0, "coherent: no freeze");
    }

    /// @dev §6 — the only penalty is a freeze, added to a total.
    function test_incoherentVoterIsFrozenNotDebited() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);

        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE, 0);
        _commit(id, mods[3], REJECT, 0);
        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        for (uint256 i; i < 3; ++i) _reveal(id, mods[i], APPROVE);
        _reveal(id, mods[3], REJECT);

        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);

        assertEq(mod.caseInfo(id).preliminary, APPROVE, "3-1 approve");

        mod.claim(id, mods[3]);
        assertEq(stakes.totalFrozen(mods[3]), FREEZE, "frozen by the loss");
        assertEq(token.balanceOf(mods[3]), 0, "and nothing taken in money");
    }

    /// @dev §4.2 — a challenge is a vote opposite the published outcome. It
    ///      discloses its direction and opens a fresh staged pair.
    function test_challengeIsAnOppositeVoteAndReopensStaging() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE, 0);
        _wait(COMMIT_WINDOW + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        for (uint256 i; i < 3; ++i) _reveal(id, mods[i], APPROVE);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);

        assertEq(mod.caseInfo(id).preliminary, APPROVE);

        vm.prank(mods[7]);
        mod.challenge(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.pooledReject, 1, "the challenge counted as a Reject");
        assertEq(c.pooledApprove, 3, "and the pool carried forward");
        assertEq(c.challenges, 1);
        assertTrue(c.everChallenged, "never anonymous again");
        assertEq(c.phase, uint8(Moderation.Phase.COMMIT_A), "a fresh staged pair");
        assertEq(c.seedBlockB, 0, "B unknowable again");
        assertEq(c.commitsA, 0, "per-committee counts reset, tally does not");
    }

    function test_challengeCapIsTwo() public {
        assertEq(mod.MAX_CHALLENGES(), 2);
    }

    /// @dev Nobody commits: the case cannot hang. §11 leaves the policy open;
    ///      this is the bound, and the fee goes back.
    function test_noTurnoutRefunds() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.refundOwed(id), FEE);

        uint256 before = token.balanceOf(submitter);
        mod.withdrawRefund(id);
        assertEq(token.balanceOf(submitter) - before, FEE);
    }

    function test_cannotVoteTwiceInOneCase() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE, 0);
        bytes32 h = mod.commitHash(id, 0, mods[0], REJECT, bytes32("s"));
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.AlreadyVoted.selector);
        mod.commit(id, h);
    }

    function test_frozenModeratorCannotCommit() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        stakes.freeze(mods[0], FREEZE);
        bytes32 h = mod.commitHash(id, 0, mods[0], APPROVE, bytes32("s"));
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.NotEligible.selector);
        mod.commit(id, h);
    }
}
