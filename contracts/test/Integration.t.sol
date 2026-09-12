// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// @notice The three real contracts, wired as the deploy script wires them. No
///         mocks anywhere.
///
/// Every other suite substitutes a mock registry or a mock index, and the
/// interfaces `Moderation` calls through are declared locally — so a signature
/// that drifts from the real contract compiles and reverts at runtime. Nothing
/// below would survive that.
contract IntegrationTest is Test {
    Deploy deployer;
    Deploy.Stack s;
    MockBZZ token;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    uint256 constant STAKE = 10e16;
    uint256 constant FEE = 1e15;

    address submitter = address(0x5011);
    address[64] mods;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        deployer = new Deploy();
        s = deployer.deploy(deployer.defaults(address(token)));

        for (uint256 i; i < mods.length; ++i) {
            mods[i] = address(uint160(0x10000 + i));
            token.mint(mods[i], STAKE);
            vm.startPrank(mods[i]);
            token.approve(address(s.stakes), type(uint256).max);
            s.stakes.stake();
            vm.stopPrank();
        }
        token.mint(submitter, 1e18);
        vm.prank(submitter);
        token.approve(address(s.moderation), type(uint256).max);

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
        bytes32[] memory t = new bytes32[](1);
        t[0] = keccak256("biology");
        vm.prank(submitter);
        id = s.moderation.submit(keccak256("content"), keccak256("meta"), t, FEE);
    }

    /// @dev Commits every eligible moderator, and reports how many there were.
    function _commitEligible(uint256 id, uint8 v) internal returns (uint256 n) {
        for (uint256 i; i < mods.length; ++i) {
            if (!s.moderation.isEligible(id, mods[i])) continue;
            if (s.moderation.voteOf(id, mods[i]).commitment != bytes32(0)) continue;
            bytes32 h = s.moderation.commitHash(id, 0, mods[i], v, bytes32("s"));
            vm.prank(mods[i]);
            s.moderation.commit(id, h);
            ++n;
        }
    }

    function _revealAll(uint256 id, uint8 v) internal {
        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.voteOf(id, mods[i]).commitment == bytes32(0)) continue;
            vm.prank(mods[i]);
            s.moderation.reveal(id, v, bytes32("s"));
        }
    }

    // -----------------------------------------------------------------

    function test_deployVerifiesEveryLinkBothWays() public view {
        deployer.verify(s);
        assertEq(s.stakes.moderation(), address(s.moderation));
        assertEq(s.index.moderation(), address(s.moderation));
        assertEq(address(s.moderation.stakes()), address(s.stakes));
        assertEq(address(s.moderation.index()), address(s.index));
    }

    function test_verifyCatchesAnUnlinkedStack() public {
        Deploy.Stack memory broken;
        broken.stakes = new StakeRegistry(address(token), STAKE);
        broken.index = new IndexRegistry();
        broken.moderation = new Moderation(
            address(token), address(broken.stakes), address(broken.index),
            15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, FEE
        );
        // deployed, never linked — this is the state that otherwise fails at the
        // first commit, long after anyone is watching
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotLinked.selector, "stakes->moderation"));
        deployer.verify(broken);
    }

    /// @dev With 64 staked, `eligBits` is non-zero and eligibility actually
    ///      narrows. Every mock suite ran at 8 staked, where the threshold is 0
    ///      and every moderator is eligible — so this path had never run.
    function test_eligibilityActuallyNarrows() public {
        assertEq(s.stakes.stakedCount(), 64);
        uint256 id = _submit();
        _advance(3);

        uint256 eligible;
        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.isEligible(id, mods[i])) ++eligible;
        }
        assertGt(eligible, 0, "somebody can vote");
        assertLt(eligible, mods.length, "but not everybody: the hash narrows");
    }

    /// @dev A whole case against the real registries: stake, eligibility, two
    ///      staged committees, joint reveal, draw, finalize, index write, payout.
    function test_fullCaseAgainstRealContracts() public {
        uint256 id = _submit();

        _advance(3);
        uint256 nA = _commitEligible(id, APPROVE);
        _wait(2 hours);
        s.moderation.closeCommitA(id);

        _advance(3);
        uint256 nB = _commitEligible(id, APPROVE);
        _wait(2 hours);
        s.moderation.closeCommitB(id);

        assertGt(nA + nB, 0, "somebody committed");
        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.voteOf(id, mods[i]).commitment == bytes32(0)) continue;
            assertEq(s.stakes.openVotes(mods[i]), 1, "registry saw the commit");
        }

        _revealAll(id, APPROVE);
        _wait(1 hours);
        s.moderation.closeReveal(id);
        _advance(3);
        s.moderation.draw(id);
        _wait(2 hours);
        s.moderation.closeChallenge(id);

        Moderation.Case memory c = s.moderation.caseInfo(id);
        assertEq(c.phase, uint8(Moderation.Phase.FINALIZED));
        assertEq(c.preliminary, APPROVE);

        // the REAL index was written, with §7's two facts and the tally
        bytes32 claimKey = keccak256(abi.encode(keccak256("content"), keccak256("meta")));
        assertTrue(s.index.isListed(claimKey, keccak256("biology")));
        IndexRegistry.Entry memory e = s.index.entryOf(claimKey, keccak256("biology"));
        assertEq(e.approve, uint32(nA + nB));
        assertEq(e.reject, 0);
        assertTrue(e.allTicketsApprove, "unanimous tally, unanimous draw");
        assertFalse(e.everChallenged);

        // and the real registry settled
        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.voteOf(id, mods[i]).commitment == bytes32(0)) continue;
            s.moderation.claim(id, mods[i]);
            assertEq(s.stakes.openVotes(mods[i]), 0, "vote closed");
            assertEq(s.stakes.totalFrozen(mods[i]), 0, "coherent: no freeze");
            assertGt(token.balanceOf(mods[i]), 0, "paid");
        }
    }

    /// @dev The bug this suite was written to catch. Three commits, nobody
    ///      reveals, the case is UNRESOLVED — and the committers must still be
    ///      able to settle and withdraw. `claim` requiring FINALIZED stranded
    ///      their stake permanently, and no mock suite could see it because none
    ///      of them ran a real `withdraw`.
    function test_unresolvedCaseDoesNotStrandStake() public {
        uint256 id = _submit();
        _advance(3);
        uint256 n = _commitEligible(id, APPROVE);
        assertGt(n, 0);

        _wait(2 hours);
        s.moderation.closeCommitA(id);
        _advance(3);
        _wait(2 hours);
        s.moderation.closeCommitB(id);

        // nobody reveals
        _wait(1 hours);
        s.moderation.closeReveal(id);
        assertEq(s.moderation.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));

        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.voteOf(id, mods[i]).commitment == bytes32(0)) continue;
            s.moderation.claim(id, mods[i]);
            assertEq(s.stakes.openVotes(mods[i]), 0, "released");
            assertEq(s.stakes.totalFrozen(mods[i]), 0, "no verdict, so no penalty");

            vm.prank(mods[i]);
            s.stakes.withdraw();
            assertEq(token.balanceOf(mods[i]), STAKE, "stake back in full");
        }

        // and the submitter gets the fee back
        uint256 before = token.balanceOf(submitter);
        s.moderation.withdrawRefund(id);
        assertEq(token.balanceOf(submitter) - before, FEE);
    }

    /// @dev An incoherent voter is frozen by the real registry, and the freeze
    ///      then blocks both voting and withdrawal.
    function test_realFreezeBlocksVotingAndWithdrawal() public {
        uint256 id = _submit();
        _advance(3);

        address dissenter;
        for (uint256 i; i < mods.length; ++i) {
            if (!s.moderation.isEligible(id, mods[i])) continue;
            uint8 v = dissenter == address(0) ? REJECT : APPROVE;
            if (v == REJECT) dissenter = mods[i];
            bytes32 h = s.moderation.commitHash(id, 0, mods[i], v, bytes32("s"));
            vm.prank(mods[i]);
            s.moderation.commit(id, h);
        }
        require(dissenter != address(0), "need an eligible dissenter");

        _wait(2 hours);
        s.moderation.closeCommitA(id);
        _advance(3);
        _wait(2 hours);
        s.moderation.closeCommitB(id);

        for (uint256 i; i < mods.length; ++i) {
            if (s.moderation.voteOf(id, mods[i]).commitment == bytes32(0)) continue;
            uint8 v = mods[i] == dissenter ? REJECT : APPROVE;
            vm.prank(mods[i]);
            s.moderation.reveal(id, v, bytes32("s"));
        }

        _wait(1 hours);
        s.moderation.closeReveal(id);
        _advance(3);
        s.moderation.draw(id);
        _wait(2 hours);
        s.moderation.closeChallenge(id);

        vm.assume(s.moderation.caseInfo(id).preliminary == APPROVE);
        s.moderation.claim(id, dissenter);

        assertTrue(s.stakes.isFrozen(dissenter), "frozen by the real registry");
        assertEq(s.stakes.totalFrozen(dissenter), 8 days);
        assertEq(token.balanceOf(dissenter), 0, "and nothing taken in money");

        vm.prank(dissenter);
        vm.expectRevert(StakeRegistry.IsFrozen.selector);
        s.stakes.withdraw();
    }
}
