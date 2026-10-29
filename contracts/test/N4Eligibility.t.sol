// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HistoryFixture} from "./helpers/HistoryFixture.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// @notice The smaller lottery against real registries and a three-reveal floor.
contract N4EligibilityTest is HistoryFixture {
    Moderation mod;
    StakeRegistry stakes;
    IndexRegistry index;
    MockBZZ token;
    address constant PUBLISHER = address(0x5011);
    uint256 constant FEE = 1200;
    bytes32 constant SALT = bytes32("N4 regression");

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockBZZ();
        stakes = new StakeRegistry(address(token), 1000);
        index = new IndexRegistry();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            900, 1800, 3600, 3600, 8 days, 2, FEE, 3, 1, keccak256("guidelines")));
        stakes.setModeration(address(mod));
        index.setModeration(address(mod));
        _stakeMembers(0, 64);
        token.mint(PUBLISHER, 10 * FEE);
        vm.prank(PUBLISHER);
        token.approve(address(mod), type(uint256).max);
    }

    function _member(uint256 i) internal pure returns (address) {
        return address(uint160(0x9000 + i));
    }

    function _stakeMembers(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            address member = _member(i);
            token.mint(member, 1000);
            vm.startPrank(member);
            token.approve(address(stakes), 1000);
            stakes.stake();
            vm.stopPrank();
        }
    }

    function _submit() internal returns (uint256) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(PUBLISHER);
        return mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
    }

    function _commitCommittee(uint256 id, address[6] memory voters, uint256 offset) internal {
        uint256 placed;
        uint8 round = mod.caseInfo(id).challenges;
        for (uint256 i; i < 64 && placed < 3; ++i) {
            address member = _member(i);
            if (mod.voteOf(id, member).commitment != bytes32(0) || !mod.isEligible(id, member)) continue;
            bytes32 h = mod.commitHash(id, round, member, 1, SALT);
            vm.prank(member);
            mod.commit(id, h);
            voters[offset + placed] = member;
            ++placed;
        }
        assertEq(placed, 3, "fixture must provide three fresh eligible voters");
    }

    function _commitPair(uint256 id) internal returns (address[6] memory voters) {
        uint8 round = mod.caseInfo(id).challenges;
        uint256 seedA = mod.caseInfo(id).seedBlockA;
        vm.roll(seedA + 1);
        vm.setBlockhash(seedA, keccak256(abi.encode("N4 A", round)));
        _commitCommittee(id, voters, 0);
        uint256 seedB = mod.caseInfo(id).seedBlockB;
        vm.roll(seedB + 1);
        vm.warp(mod.pairScheduleOf(id).deadlineA);
        _recordHistory(seedB, keccak256(abi.encode("N4 B", round)));
        _commitCommittee(id, voters, 3);
        assertEq(mod.caseInfo(id).commitsA, 3);
        assertEq(mod.caseInfo(id).commitsB, 3);
        vm.warp(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id);
    }

    function _reveal(uint256 id, address member) internal {
        vm.prank(member);
        mod.reveal(id, 1, SALT);
    }

    function _completePair(uint256 id) internal {
        address[6] memory voters = _commitPair(id);
        for (uint256 i; i < voters.length; ++i) _reveal(id, voters[i]);
        assertEq(mod.caseInfo(id).revealsA, 3);
        assertEq(mod.caseInfo(id).revealsB, 3);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256(abi.encode("N4 outcome", mod.caseInfo(id).challenges)));
        mod.draw(id);
    }

    function _challenge(uint256 id) internal {
        for (uint256 i; i < 64; ++i) {
            address member = _member(i);
            if (mod.voteOf(id, member).commitment != bytes32(0)) continue;
            Moderation.Case memory challengeIntent1 = mod.caseInfo(id);
            vm.prank(member);
            mod.challenge(id, challengeIntent1.challenges, challengeIntent1.preliminary);
            return;
        }
        revert("fixture needs a fresh challenger");
    }

    function test_initialAndBothChallengePairsUseN4WithThreeRevealsEach() public {
        uint256 id = _submit();
        assertEq(mod.minRevealsPerCommittee(), 3);
        for (uint8 round; round < 3; ++round) {
            assertEq(mod.caseInfo(id).eligBits, 2, "64 staked uses N-4, not N-5");
            assertEq(mod.caseInfo(id).challenges, round);
            _completePair(id);
            assertEq(mod.caseInfo(id).pot, FEE);
            if (round < 2) _challenge(id);
        }
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
        assertEq(mod.refundOwed(id), 0);
    }

    function test_twoBRevealsStillFailThePerCommitteeFloorUnderN4() public {
        uint256 id = _submit();
        assertEq(mod.caseInfo(id).eligBits, 2);
        address[6] memory voters = _commitPair(id);
        for (uint256 i; i < 5; ++i) _reveal(id, voters[i]);
        assertEq(mod.caseInfo(id).revealsA, 3);
        assertEq(mod.caseInfo(id).revealsB, 2);
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.refundOwed(id), FEE);
        mod.claim(id, voters[0]);
        assertFalse(stakes.isFrozen(voters[0]));
        mod.claim(id, voters[5]);
        assertTrue(stakes.isFrozen(voters[5]));
        assertEq(stakes.openVotes(voters[0]), 0);
        assertEq(stakes.openVotes(voters[5]), 0);
        mod.withdrawRefund(id);
        assertEq(token.balanceOf(address(mod)), 0);
    }

    function test_stakedCountChangesDoNotChangePinnedBitsIncludingChallenges() public {
        uint256 original = _submit();
        assertEq(mod.caseInfo(original).eligBits, 2);
        _stakeMembers(64, 128);
        assertEq(stakes.stakedCount(), 128);
        uint256 later = _submit();
        assertEq(mod.caseInfo(later).eligBits, 3, "new case uses the larger staked count");
        assertEq(mod.caseInfo(original).eligBits, 2);
        _completePair(original);
        _challenge(original);
        assertEq(mod.caseInfo(original).eligBits, 2, "challenge retains original snapshot");
        _completePair(original);
        _challenge(original);
        assertEq(mod.caseInfo(original).eligBits, 2);
        _completePair(original);
        assertEq(mod.caseInfo(original).phase, uint8(Moderation.Phase.FINALIZED));
    }
}
