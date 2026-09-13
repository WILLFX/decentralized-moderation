// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice **What the per-committee reveal floor buys, and what it does not.**
///
/// This suite used to pin the opposite: three identities that were the only
/// committers took a case with probability 1, forty times out of forty. That was
/// a tripwire on §11's undecided per-committee minimum. The minimum has since
/// landed, counted on REVEALS, and these two tests are what replaced it.
///
/// They are deliberately a pair, because the floor is easy to overstate in both
/// directions:
///
/// - the original attack is dead, and it dies at the *weakest* possible floor,
///   because it depended on committee B holding nobody at all;
/// - a clique that fields identities in BOTH committees still decides a case with
///   certainty once it clears the floor. The floor did not make capture
///   impossible. It made it cost `k` revealed, liable identities per committee.
///
/// So the floor's value is entirely the identity count it forces, which is what
/// `simulation/FINDINGS-floor-price.md` prices, and nothing about it removes the
/// fact that `A/N` makes a unanimous tally certain. If anyone later reads the
/// floor as having closed capture, the second test is the correction.
contract ThreeVoteTest is Test {
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;
    address sub = address(0x5011);
    uint256 blk = 100;
    uint256 ts = 1_000_000;

    uint8 constant APPROVE = 1;
    uint8 constant PHASE_UNRESOLVED = 6;
    uint256 constant FEE = 1000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        vm.roll(blk);
        vm.warp(ts);
    }

    function _deploy(uint256 floor) internal returns (Moderation mod) {
        mod = new Moderation(
            address(token), address(stakes), address(index),
            15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, FEE, floor
        );
        token.mint(sub, 1e12);
        vm.prank(sub);
        token.approve(address(mod), type(uint256).max);
    }

    function _clique(uint256 n) internal returns (address[] memory who) {
        who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = address(uint160(0x900 + i));
            stakes.add(who[i]);
        }
    }

    function _submit(Moderation mod, uint256 salt) internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("bio");
        vm.prank(sub);
        id = mod.submit(keccak256(abi.encode("c", salt)), keccak256("m"), topics, FEE);
        blk += 3;
        vm.roll(blk);
    }

    function _commitAll(Moderation mod, uint256 id, address[] memory who, uint256 from, uint256 to)
        internal
    {
        for (uint256 i = from; i < to; ++i) {
            bytes32 h = mod.commitHash(id, 0, who[i], APPROVE, bytes32("s"));
            vm.prank(who[i]);
            mod.commit(id, h);
        }
    }

    function _revealAll(Moderation mod, uint256 id, address[] memory who, uint256 to) internal {
        for (uint256 i; i < to; ++i) {
            vm.prank(who[i]);
            mod.reveal(id, APPROVE, bytes32("s"));
        }
    }

    /// @dev The attack this suite was built to pin, re-run at the weakest floor
    ///      the contract will accept. It depended on committee B being empty, and
    ///      `k = 1` already demands one revealed vote in EACH committee — so the
    ///      case terminates UNRESOLVED with the fee refunded and nothing listed.
    ///      Forty trials, because the claim being refuted was a claim of certainty.
    function test_emptySecondCommitteeNoLongerDecidesACase() public {
        Moderation mod = _deploy(1);
        address[] memory a = _clique(3);

        uint256 TRIALS = 40;
        for (uint256 t; t < TRIALS; ++t) {
            uint256 id = _submit(mod, t);

            _commitAll(mod, id, a, 0, 3); // all three land in committee A
            ts += 2 hours;
            vm.warp(ts);
            mod.closeCommitA(id);
            blk += 3;
            vm.roll(blk);
            ts += 2 hours;
            vm.warp(ts);
            mod.closeCommitB(id); // committee B: nobody
            _revealAll(mod, id, a, 3);
            ts += 1 hours;
            vm.warp(ts);
            mod.closeReveal(id);

            assertEq(mod.caseInfo(id).phase, PHASE_UNRESOLVED, "should not have resolved");
            assertEq(mod.refundOwed(id), FEE, "fee must be refunded, not kept");
            assertEq(index.writes(), 0, "nothing may be listed");

            // and there is no outcome to draw: the case left REVEAL for a
            // terminal phase, so `draw` has nothing to act on
            vm.expectRevert(Moderation.BadPhase.selector);
            mod.draw(id);
        }
    }

    /// @dev The other half, and the uncomfortable one. Six identities — three
    ///      revealing in each committee — clear a floor of 3 and take the case with
    ///      certainty, because `A/N` on a unanimous tally is still 1 and `f(1) = 1`.
    ///      The floor converted "3 identities" into "2k revealed, liable
    ///      identities"; it did not convert certainty into a probability.
    function test_aCliqueThatFieldsBothCommitteesStillTakesItWithCertainty() public {
        Moderation mod = _deploy(3);
        address[] memory a = _clique(6);

        uint256 TRIALS = 40;
        uint256 listed;
        for (uint256 t; t < TRIALS; ++t) {
            uint256 id = _submit(mod, t);

            _commitAll(mod, id, a, 0, 3); // committee A
            ts += 2 hours;
            vm.warp(ts);
            mod.closeCommitA(id);
            blk += 3;
            vm.roll(blk);
            _commitAll(mod, id, a, 3, 6); // committee B
            ts += 2 hours;
            vm.warp(ts);
            mod.closeCommitB(id);
            _revealAll(mod, id, a, 6);
            ts += 1 hours;
            vm.warp(ts);
            mod.closeReveal(id);
            blk += 3;
            vm.roll(blk);
            mod.draw(id);
            ts += 2 hours;
            vm.warp(ts);
            mod.closeChallenge(id);

            if (mod.caseInfo(id).preliminary == APPROVE) ++listed;
        }
        assertEq(listed, TRIALS, "a clique clearing the floor still decides with certainty");
    }
}
