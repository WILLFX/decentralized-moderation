// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice Exposes `shareOf` over a planted tally, so the `winners == 0` branch
///         and the single-winner case can be checked without steering a real draw
///         to a low-probability outcome.
contract ShareHarness is Moderation {
    constructor(address t, address s, address i)
        Moderation(t, s, i, 15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, 1, 1)
    {}

    function plant(uint256 caseId, uint32 a, uint32 r, uint8 preliminary, uint128 pot) external {
        Case storage c = cases[caseId];
        c.pooledApprove = a;
        c.pooledReject = r;
        c.preliminary = preliminary;
        c.pot = pot;
    }
}

/// @notice Holes that a mutation campaign found and the suite did not cover.
///
/// Every test here was written against a specific surviving mutant, named in its
/// docstring. They are grouped by what the mutant would have cost, because that
/// ordering is the argument for the tests existing: the first three are fund
/// safety and moderator safety, the next four are guards on the challenge path,
/// and the rest are boundaries the protocol states exactly.
///
/// The campaign that produced them is in `contracts/README.md`. Two of these
/// mutants had been dismissed as equivalent and are not: `vt.settled = false`
/// lets a coherent voter claim the pot repeatedly, and turning `claim`'s guard
/// from `||` to `&&` lets anyone freeze any address they choose.
contract SettlementTest is Test {
    Moderation mod;
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;

    address submitter = address(0x5011);
    address[10] mods;
    address outsider = address(0xDEAD);

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;
    uint256 constant COMMIT_WINDOW = 15 minutes;
    uint256 constant REVEAL_WINDOW = 30 minutes;
    uint256 constant CHALLENGE_WINDOW = 1 hours;
    uint256 constant MAX_WAIT = 1 hours;
    uint256 constant FREEZE = 8 days;
    uint256 constant SEED_LAG = 2;
    uint256 constant FEE = 1000;
    uint256 constant FLOOR = 1;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(
            address(token), address(stakes), address(index),
            COMMIT_WINDOW, REVEAL_WINDOW, CHALLENGE_WINDOW, MAX_WAIT, FREEZE, SEED_LAG, FEE, FLOOR
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

    function _commit(uint256 id, address m, uint8 v) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    function _reveal(uint256 id, address m, uint8 v) internal {
        vm.prank(m);
        mod.reveal(id, v, bytes32("s"));
    }

    /// @dev One committee-A voter and one committee-B voter, both `v`, taken to
    ///      FINALIZED. Unanimous, so the outcome is `v` with certainty under A/N.
    function _finalizedCase(uint8 v) internal returns (uint256 id) {
        id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _commit(id, mods[1], v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, mods[0], v);
        _reveal(id, mods[1], v);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(id);
        assertEq(mod.caseInfo(id).preliminary, v, "unanimous, so certain");
    }

    // ------------------------------------------------- fund and actor safety

    /// @dev Kills `vt.settled = true` -> `false`, which the full suite passed.
    ///      Without the flag a coherent voter re-enters `claim` and is paid again
    ///      each time, draining the contract's balance one share at a time. This
    ///      exact mutant was once committed to `main` by accident, so the suite
    ///      demonstrably never covered it.
    function test_claimIsPayableOnce() public {
        uint256 id = _finalizedCase(APPROVE);

        uint256 share = mod.shareOf(id);
        assertGt(share, 0, "there is something to pay");

        mod.claim(id, mods[0]);
        assertEq(token.balanceOf(mods[0]), share, "paid once");

        vm.expectRevert(Moderation.NothingToClaim.selector);
        mod.claim(id, mods[0]);
        assertEq(token.balanceOf(mods[0]), share, "and not twice");
    }

    /// @dev Kills the `||` -> `&&` mutant in `claim`'s guard. `claim` is
    ///      permissionless in its `m` argument, so with `&&` an address that never
    ///      voted passes the guard, reaches `stakes.settle(m, true, ...)` with
    ///      `revealed == NONE`, and is FROZEN. Anyone could then freeze any
    ///      moderator they chose, on any finalized case, for free.
    function test_claimCannotFreezeAnAddressThatNeverVoted() public {
        uint256 id = _finalizedCase(APPROVE);

        vm.expectRevert(Moderation.NothingToClaim.selector);
        mod.claim(id, outsider);
        assertEq(stakes.totalFrozen(outsider), 0, "an outsider cannot be frozen");

        // and the same for a staked moderator who simply did not take this case
        vm.expectRevert(Moderation.NothingToClaim.selector);
        mod.claim(id, mods[9]);
        assertEq(stakes.totalFrozen(mods[9]), 0, "nor a moderator who never committed");
    }

    /// @dev Kills both `winners == 0` -> `winners == 1` mutants in `shareOf`.
    ///      A single coherent voter must take the whole pot; reading `1` as the
    ///      empty case pays them nothing and strands the fee. Reaching a
    ///      one-winner tally through a real draw needs a low-probability outcome,
    ///      so the tally is planted — `shareOf` is a pure function of it.
    function test_shareOfAtEveryWinnerCount() public {
        ShareHarness h = new ShareHarness(address(token), address(stakes), address(index));

        h.plant(1, 1, 5, APPROVE, 900);
        assertEq(h.shareOf(1), 900, "a sole winner takes the whole pot");

        h.plant(2, 3, 5, APPROVE, 900);
        assertEq(h.shareOf(2), 300, "three winners split it");

        h.plant(3, 0, 5, APPROVE, 900);
        assertEq(h.shareOf(3), 0, "no winners: nothing to divide, and no division");

        h.plant(4, 5, 1, REJECT, 900);
        assertEq(h.shareOf(4), 900, "the losing side's count is not the divisor");
    }

    // ------------------------------------------------------- challenge guards

    function _toChallengeWindow(uint8 v) internal returns (uint256 id) {
        id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _commit(id, mods[1], v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, mods[0], v);
        _reveal(id, mods[1], v);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.CHALLENGE));
    }

    /// @dev Kills the `||` -> `&&` mutant on `challenge`'s stake guard. The same
    ///      mutant in `commit` is caught; this one was not, so an address holding
    ///      no stake at all could buy a case two more committees.
    function test_unstakedAddressCannotChallenge() public {
        uint256 id = _toChallengeWindow(APPROVE);
        vm.prank(outsider);
        vm.expectRevert(Moderation.NotEligible.selector);
        mod.challenge(id);
    }

    /// @dev The other half of the same guard: a frozen moderator is serving a
    ///      penalty and must not be able to act, and a challenge is an act.
    function test_frozenModeratorCannotChallenge() public {
        uint256 id = _toChallengeWindow(APPROVE);
        stakes.settle(mods[5], true, FREEZE); // freeze mods[5] directly
        assertTrue(stakes.isFrozen(mods[5]));

        vm.prank(mods[5]);
        vm.expectRevert(Moderation.NotEligible.selector);
        mod.challenge(id);
    }

    /// @dev Kills `c.challenges >= MAX_CHALLENGES` -> `>` in `challenge`. At `>`
    ///      the cap is three, not two, and `specs/protocol.md` §4.2 says two. The
    ///      existing cap test walks two challenges and never attempts a third.
    function test_aThirdChallengeIsRejected() public {
        uint256 id = _toChallengeWindow(APPROVE);

        // challenge 1
        vm.prank(mods[6]);
        mod.challenge(id);
        _runChallengeRoundTo(id, mods[2], mods[3], APPROVE);

        // challenge 2 — the cap
        vm.prank(mods[7]);
        mod.challenge(id);
        assertEq(mod.caseInfo(id).challenges, 2);
        _runChallengeRoundTo(id, mods[4], mods[5], APPROVE);

        // the second challenge's draw finalizes the case at the cap, so a third
        // challenge has no open window to arrive in
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED), "finalized at the cap");
        vm.prank(mods[8]);
        vm.expectRevert(Moderation.BadPhase.selector);
        mod.challenge(id);
    }

    function _runChallengeRoundTo(uint256 id, address a, address b, uint8 v) internal {
        _advance(SEED_LAG + 1);
        _commit(id, a, v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _commit(id, b, v);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, a, v);
        _reveal(id, b, v);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
    }

    /// @dev Kills `block.number + seedLag` -> `-` on the seed armed by
    ///      `challenge`. A seed must be a FUTURE block: at a past one the
    ///      blockhash already exists, so the challenge round's committee A is
    ///      computable by the challenger at the moment they challenge — which is
    ///      the unpredictability the whole staging rests on. `submit`'s seed is
    ///      covered; the one on the challenge path was not.
    function test_everySeedIsAFutureBlock() public {
        uint256 id = _submit();
        assertGt(mod.caseInfo(id).seedBlockA, block.number, "committee A, at submit");

        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        assertGt(mod.caseInfo(id).seedBlockB, block.number, "committee B, at commit-A close");

        _advance(SEED_LAG + 1);
        _commit(id, mods[1], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, mods[0], APPROVE);
        _reveal(id, mods[1], APPROVE);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        assertGt(mod.caseInfo(id).outcomeSeedBlock, block.number, "the outcome seed");

        _advance(SEED_LAG + 1);
        mod.draw(id);
        vm.prank(mods[6]);
        mod.challenge(id);
        assertGt(
            mod.caseInfo(id).seedBlockA, block.number, "committee A of the CHALLENGE round"
        );
    }

    // ------------------------------------------------------------ boundaries

    /// @dev `MAX_TOPICS` is a maximum, so exactly `MAX_TOPICS` must be accepted.
    ///      Kills `topics.length > MAX_TOPICS` -> `>=`.
    function test_exactlyMaxTopicsIsAccepted() public {
        uint256 n = mod.MAX_TOPICS();
        bytes32[] memory topics = new bytes32[](n);
        for (uint256 i; i < n; ++i) topics[i] = keccak256(abi.encode("t", i));
        vm.prank(submitter);
        uint256 id = mod.submit(keccak256("c"), keccak256("m"), topics, FEE);
        assertEq(mod.caseInfo(id).topicCount, n, "all of them recorded");

        bytes32[] memory tooMany = new bytes32[](n + 1);
        for (uint256 i; i <= n; ++i) tooMany[i] = keccak256(abi.encode("t", i));
        vm.prank(submitter);
        vm.expectRevert(Moderation.BadTopics.selector);
        mod.submit(keccak256("c2"), keccak256("m"), tooMany, FEE);
    }

    /// @dev The commit window is closed AT its deadline, not after it. Kills
    ///      `block.timestamp >= c.phaseDeadline` -> `>` in `commit`.
    function test_commitAtExactlyTheDeadlineIsTooLate() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE);

        vm.warp(mod.caseInfo(id).phaseDeadline); // exactly, not past
        bytes32 h = mod.commitHash(id, 0, mods[1], APPROVE, bytes32("s"));
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TooLate.selector);
        mod.commit(id, h);
    }

    /// @dev And the mirror: a phase may be closed AT its deadline. Kills
    ///      `block.timestamp < c.phaseDeadline` -> `<=` in `closeCommitA`,
    ///      `closeCommitB`, `closeReveal` and `closeChallenge` — four survivors
    ///      of one shape, all on a boundary §4 states exactly.
    function test_everyPhaseClosesAtExactlyItsDeadline() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE);

        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeCommitA(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_B));

        _advance(SEED_LAG + 1);
        _commit(id, mods[1], APPROVE);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeCommitB(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL));

        _reveal(id, mods[0], APPROVE);
        _reveal(id, mods[1], APPROVE);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        assertGt(mod.caseInfo(id).outcomeSeedBlock, 0, "reveal closed at the deadline");

        _advance(SEED_LAG + 1);
        mod.draw(id);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeChallenge(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
    }

    /// @dev A challenge must not land at the instant the window shuts. Kills
    ///      `block.timestamp >= c.phaseDeadline` -> `>` in `challenge`.
    function test_challengeAtExactlyTheDeadlineIsTooLate() public {
        uint256 id = _toChallengeWindow(APPROVE);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        vm.prank(mods[6]);
        vm.expectRevert(Moderation.TooLate.selector);
        mod.challenge(id);
    }

    /// @dev A seed cannot be consumed at its own block: `blockhash(block.number)`
    ///      is zero, so a draw there runs on no entropy at all. Kills
    ///      `block.number <= sb` -> `<` in `draw`.
    function test_drawAtTheSeedBlockItselfIsTooEarly() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _commit(id, mods[1], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, mods[0], APPROVE);
        _reveal(id, mods[1], APPROVE);
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);

        uint256 sb = mod.caseInfo(id).outcomeSeedBlock;
        vm.roll(sb); // exactly the seed block
        vm.expectRevert(Moderation.TooEarly.selector);
        mod.draw(id);

        vm.roll(sb + 1); // one past, and it works
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, APPROVE);
    }

    /// @dev A challenger belongs to no committee, and the recorded vote must say
    ///      so. Kills `committee: 0` -> `1` on the challenge record. It was
    ///      dismissed as a field nothing reads; §4.4's floor made the committee
    ///      number load-bearing, and a challenger counted into committee A would
    ///      help satisfy a floor they are not part of.
    function test_aChallengerIsRecordedInNoCommittee() public {
        uint256 id = _toChallengeWindow(APPROVE);
        vm.prank(mods[6]);
        mod.challenge(id);

        Moderation.Vote memory v = mod.voteOf(id, mods[6]);
        assertEq(v.committee, 0, "a challenger is in neither committee");
        assertEq(v.revealed, REJECT, "and their vote is public, opposite the outcome");

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.revealsA, 0, "the challenge did not count toward committee A");
        assertEq(c.revealsB, 0, "nor committee B");
    }

    /// @dev An unresolved claim pays nothing and reports nothing paid. Kills the
    ///      `0` -> `1` and `false` -> `true` mutants on that event's arguments,
    ///      which are the only statement of what happened that a client sees.
    function test_theUnresolvedClaimEventReportsNothingPaid() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _commit(id, mods[0], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        _reveal(id, mods[0], APPROVE); // committee B never reveals: below the floor
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));

        // mods[0] revealed, so on an unresolved case they are neither paid nor frozen
        vm.expectEmit(true, true, false, true, address(mod));
        emit Moderation.Claimed(id, mods[0], 0, false);
        mod.claim(id, mods[0]);
    }

    /// @dev A one-wei share must still be transferred. Kills `paid != 0` -> `!= 1`,
    ///      under which the smallest non-zero reward is silently dropped and the
    ///      moderator is marked settled having been paid nothing.
    function test_aOneWeiShareIsStillPaid() public {
        Moderation m2 = new Moderation(
            address(token), address(stakes), address(index),
            COMMIT_WINDOW, REVEAL_WINDOW, CHALLENGE_WINDOW, MAX_WAIT, FREEZE, SEED_LAG, 1, FLOOR
        );
        vm.prank(submitter);
        token.approve(address(m2), type(uint256).max);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        uint256 id = m2.submit(keccak256("c"), keccak256("m"), topics, 2); // pot 2, 2 winners

        _advance(SEED_LAG + 1);
        bytes32 h = m2.commitHash(id, 0, mods[0], APPROVE, bytes32("s"));
        vm.prank(mods[0]);
        m2.commit(id, h);
        _wait(MAX_WAIT + 1);
        m2.closeCommitA(id);
        _advance(SEED_LAG + 1);
        h = m2.commitHash(id, 0, mods[1], APPROVE, bytes32("s"));
        vm.prank(mods[1]);
        m2.commit(id, h);
        _wait(MAX_WAIT + 1);
        m2.closeCommitB(id);
        vm.prank(mods[0]);
        m2.reveal(id, APPROVE, bytes32("s"));
        vm.prank(mods[1]);
        m2.reveal(id, APPROVE, bytes32("s"));
        _wait(REVEAL_WINDOW + 1);
        m2.closeReveal(id);
        _advance(SEED_LAG + 1);
        m2.draw(id);
        _wait(CHALLENGE_WINDOW + 1);
        m2.closeChallenge(id);

        assertEq(m2.shareOf(id), 1, "two winners over a pot of two");
        uint256 before = token.balanceOf(mods[0]);
        m2.claim(id, mods[0]);
        assertEq(token.balanceOf(mods[0]) - before, 1, "one wei, actually transferred");
    }

    /// @dev Two distinct submissions must get two distinct case ids. Kills
    ///      `nextCaseId++` -> `--`, under which the second case collides with and
    ///      overwrites the first.
    function test_caseIdsAreDistinctAndAscending() public {
        uint256 a = _submit();
        uint256 b = _submit();
        assertEq(a, 1);
        assertEq(b, 2, "the counter rises");
        assertEq(mod.caseInfo(a).pot, FEE, "and the first case still holds its own fee");
        assertEq(mod.caseInfo(b).pot, FEE);
    }
}
