// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice Guards and reported state, all found by the full mutation sweep.
///
/// Moderation scored 73.2% with 49 survivors. Most were one of three kinds:
/// state that no on-chain rule reads, guards that no test tried to violate, and
/// equivalent mutants. These close the first two.
contract GuardsTest is Test {
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

    function _commit(uint256 id, address m, uint8 v) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, m, v, bytes32("s"));
        vm.prank(m);
        mod.commit(id, h);
    }

    // ------------------------------------------------- reported turnout

    /// @dev `commitsB`, `revealsA` and `revealsB` are read by no on-chain rule —
    ///      they are returned by `caseInfo` for a reader to show per-committee
    ///      turnout, and §11's per-committee minimum will consume them. Nothing
    ///      on chain depending on them is exactly why mutating them survived.
    ///      They are still behaviour, and a reader trusting them deserves them
    ///      to be right.
    function test_perCommitteeTurnoutIsReportedCorrectly() public {
        uint256 id = _submit();

        _advance(SEED_LAG + 1);
        for (uint256 i; i < 4; ++i) _commit(id, mods[i], APPROVE);
        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.commitsA, 4);
        assertEq(c.commitsB, 0, "committee B has not opened");

        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        for (uint256 i = 4; i < 7; ++i) _commit(id, mods[i], APPROVE);
        c = mod.caseInfo(id);
        assertEq(c.commitsA, 4, "A's count is not disturbed by B");
        assertEq(c.commitsB, 3);

        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        // three of A reveal, two of B — the counters must track them apart
        for (uint256 i; i < 3; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }
        for (uint256 i = 4; i < 6; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }
        c = mod.caseInfo(id);
        assertEq(c.revealsA, 3, "committee A's reveals");
        assertEq(c.revealsB, 2, "committee B's reveals");
        assertEq(uint256(c.pooledApprove), 5, "and the pool is their sum");
    }

    /// @dev A challenge opens a fresh pair, so the per-committee counters reset
    ///      while the pooled tally does not.
    function test_challengeResetsCommitteeCountsNotTheTally() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _commit(id, mods[3], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);

        vm.prank(mods[11]);
        mod.challenge(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.commitsA, 0);
        assertEq(c.commitsB, 0);
        assertEq(c.revealsA, 0);
        assertEq(c.revealsB, 0);
        assertEq(c.pooledApprove, 4, "the tally carries");
        assertEq(c.pooledReject, 1, "plus the challenge vote");
    }

    // ------------------------------------------------------------ guards

    /// @dev `_committeeOf` returns 0 outside a commit phase, and `commit` turns
    ///      that into `BadPhase`. Nothing tried committing in the wrong phase, so
    ///      a mutant returning 1 there — which would let a vote be cast during
    ///      reveal — survived.
    function test_cannotCommitOutsideACommitPhase() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL));

        bytes32 h = mod.commitHash(id, 0, mods[9], APPROVE, bytes32("s"));
        vm.prank(mods[9]);
        vm.expectRevert(Moderation.BadPhase.selector);
        mod.commit(id, h);

        // and once the challenge window is open
        for (uint256 i; i < 3; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(id);
        _advance(SEED_LAG + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.CHALLENGE));

        vm.prank(mods[9]);
        vm.expectRevert(Moderation.BadPhase.selector);
        mod.commit(id, h);
    }

    /// @dev The draw cannot run before the tally is frozen. `closeReveal` arms
    ///      the outcome seed; until then `outcomeSeedBlock` is 0 and `draw` must
    ///      refuse. A mutant relaxing that guard would draw on `blockhash(0)`,
    ///      which is zero — a fixed, known entropy for every case.
    function test_cannotDrawBeforeTheTallyIsFrozen() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) _commit(id, mods[i], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);
        for (uint256 i; i < 3; ++i) {
            vm.prank(mods[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }

        assertEq(mod.caseInfo(id).outcomeSeedBlock, 0, "not armed yet");
        vm.expectRevert(Moderation.TooEarly.selector);
        mod.draw(id);
    }

    /// @dev A refund is payable once. `refundOwed` must be cleared, not left at
    ///      some non-zero residue — a mutant setting it to 1 lets the submitter
    ///      drain the contract a wei at a time, and nothing tried a second call.
    function test_refundCannotBeWithdrawnTwice() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id); // nobody committed: UNRESOLVED

        assertEq(mod.refundOwed(id), FEE);
        mod.withdrawRefund(id);
        assertEq(mod.refundOwed(id), 0, "cleared, not merely reduced");

        vm.expectRevert(Moderation.NothingToClaim.selector);
        mod.withdrawRefund(id);
    }

    /// @dev A removal that dies for want of voters must release its hold on the
    ///      target, or a case nobody judged locks the listing against removal
    ///      forever. `_finalize` clears it and was tested; `_toUnresolved` also
    ///      clears it and was not.
    function test_unresolvedRemovalReleasesItsHold() public {
        // list something
        uint256 listing = _submit();
        _advance(SEED_LAG + 1);
        for (uint256 i; i < 4; ++i) _commit(listing, mods[i], APPROVE);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(listing);
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(listing);
        for (uint256 i; i < 4; ++i) {
            vm.prank(mods[i]);
            mod.reveal(listing, APPROVE, bytes32("s"));
        }
        _wait(REVEAL_WINDOW + 1);
        mod.closeReveal(listing);
        _advance(SEED_LAG + 1);
        mod.draw(listing);
        _wait(CHALLENGE_WINDOW + 1);
        mod.closeChallenge(listing);

        // a removal nobody votes in
        vm.prank(submitter);
        uint256 rem = mod.submitRemoval(listing, FEE);
        assertEq(mod.openRemovalOf(listing), rem, "held");

        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(rem);
        assertEq(mod.caseInfo(rem).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.openRemovalOf(listing), 0, "hold released by the dead case");

        // so another removal can be brought
        vm.prank(submitter);
        mod.submitRemoval(listing, FEE);
    }

    /// @dev An unresolved case refunds its whole pot and keeps nothing.
    function test_unresolvedCaseKeepsNothing() public {
        uint256 id = _submit();
        _advance(SEED_LAG + 1);
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);

        assertEq(mod.caseInfo(id).pot, 0, "the pot is emptied into the refund");
        assertEq(mod.refundOwed(id), FEE);
        mod.withdrawRefund(id);
        assertEq(token.balanceOf(address(mod)), 0, "and the contract holds nothing");
    }
}
