// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice **A record of current behaviour, not an endorsement of it.**
///
/// `specs/protocol.md` §5 uses the raw share `A/N`, so a unanimous tally decides
/// with certainty. §4.1 starts the commit clock at the third commitment and says
/// plainly that three commits are a timer trigger and not a quorum. Nothing
/// requires committee B to contain anybody.
///
/// Those three choices are individually defensible and together they mean three
/// identities that are the only committers take a case with probability 1. This
/// test pins that so the consequence is visible in the suite rather than latent
/// in the arithmetic.
///
/// **If §11's minimum participation per committee lands, this test must change** —
/// and that is the point of it. It is the tripwire on a decision that has not
/// been taken.
contract ThreeVoteTest is Test {
    Moderation mod; MockBZZ token; MockStakes stakes; MockIndex index;
    address sub = address(0x5011);
    address[3] a;
    uint256 blk = 100; uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ(); stakes = new MockStakes(); index = new MockIndex();
        mod = new Moderation(address(token), address(stakes), address(index),
            15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, 1000);
        for (uint256 i; i < 3; ++i) { a[i] = address(uint160(0x900 + i)); stakes.add(a[i]); }
        token.mint(sub, 1e12); vm.prank(sub); token.approve(address(mod), type(uint256).max);
        vm.roll(blk); vm.warp(ts);
    }

    /// @dev Forty cases, forty different entropies, committee B empty throughout.
    ///      Certainty here is not luck and not a seed: `f(A/N) = f(1) = 1`.
    function test_threeIdentitiesTakeACaseWithCertainty() public {
        uint256 listed;
        uint256 TRIALS = 40;
        for (uint256 t; t < TRIALS; ++t) {
            bytes32[] memory topics = new bytes32[](1);
            topics[0] = keccak256("bio");
            vm.prank(sub);
            uint256 id = mod.submit(keccak256(abi.encode("c", t)), keccak256("m"), topics, 1000);

            blk += 3; vm.roll(blk);
            for (uint256 i; i < 3; ++i) {
                bytes32 h = mod.commitHash(id, 0, a[i], 1, bytes32("s"));
                vm.prank(a[i]); mod.commit(id, h);
            }
            ts += 2 hours; vm.warp(ts);
            mod.closeCommitA(id);
            blk += 3; vm.roll(blk); ts += 2 hours; vm.warp(ts);
            mod.closeCommitB(id);                      // committee B: nobody
            for (uint256 i; i < 3; ++i) { vm.prank(a[i]); mod.reveal(id, 1, bytes32("s")); }
            ts += 1 hours; vm.warp(ts);
            mod.closeReveal(id);
            blk += 3; vm.roll(blk);
            mod.draw(id);
            ts += 2 hours; vm.warp(ts);
            mod.closeChallenge(id);
            if (mod.caseInfo(id).preliminary == 1) ++listed;
        }
        emit log_named_uint("listed out of", TRIALS);
        emit log_named_uint("listed", listed);
        assertEq(listed, TRIALS, "three identities decided every case with certainty");
    }
}
