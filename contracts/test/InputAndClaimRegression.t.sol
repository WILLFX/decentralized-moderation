// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HistoryFixture} from "./helpers/HistoryFixture.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

contract InputAndClaimRegressionTest is HistoryFixture {
    Moderation mod;
    StakeRegistry stakes;
    MockBZZ token;
    address constant VOTER = address(0x111);
    address constant PUBLISHER = address(0x222);
    uint256 constant FEE = 1200;

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockBZZ();
        stakes = new StakeRegistry(address(token), 1000);
        IndexRegistry index = new IndexRegistry();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            900, 1800, 3600, 3600, 8 days, 2, FEE, 3, 1, keccak256("guidelines")));
        stakes.setModeration(address(mod));
        index.setModeration(address(mod));
        token.mint(VOTER, 1000);
        vm.startPrank(VOTER);
        token.approve(address(stakes), 1000);
        stakes.stake();
        vm.stopPrank();
        token.mint(PUBLISHER, FEE);
        vm.prank(PUBLISHER);
        token.approve(address(mod), FEE);
    }

    function _submit() internal returns (uint256) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("topic");
        vm.prank(PUBLISHER);
        return mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
    }

    function test_zeroTopicAtAnyPositionRejectsBeforeFeeOrCaseCreation() public {
        for (uint256 zeroAt; zeroAt < 5; ++zeroAt) {
            bytes32[] memory topics = new bytes32[](5);
            for (uint256 j; j < 5; ++j) topics[j] = bytes32(j + 1);
            topics[zeroAt] = bytes32(0);
            uint256 next = mod.nextCaseId();
            vm.expectRevert(Moderation.BadTopics.selector);
            vm.prank(PUBLISHER);
            mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
            assertEq(mod.nextCaseId(), next);
            assertEq(token.balanceOf(PUBLISHER), FEE);
            assertEq(token.balanceOf(address(mod)), 0);
        }
        assertEq(_submit(), 1);
    }

    function test_zeroCommitmentLeavesCountsAndStakeUnchangedAndValidCommitStillWorks() public {
        uint256 caseId = _submit();
        vm.roll(103);
        uint256 deadline = mod.caseInfo(caseId).phaseDeadline;
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(Moderation.NoCommitment.selector);
            vm.prank(VOTER);
            mod.commit(caseId, bytes32(0));
        }
        assertEq(mod.caseInfo(caseId).commitsA, 0);
        assertEq(mod.caseInfo(caseId).phaseDeadline, deadline);
        assertEq(stakes.openVotes(VOTER), 0);
        bytes32 commitment = mod.commitHash(caseId, 0, VOTER, 1, bytes32("salt"));
        vm.prank(VOTER);
        mod.commit(caseId, commitment);
        assertEq(mod.caseInfo(caseId).commitsA, 1);
        assertEq(stakes.openVotes(VOTER), 1);
    }

    function test_zeroCommitmentInSecondCommitteeDoesNotConsumeVote() public {
        address secondVoter = address(0x333);
        token.mint(secondVoter, 1000);
        vm.startPrank(secondVoter);
        token.approve(address(stakes), 1000);
        stakes.stake();
        vm.stopPrank();
        uint256 caseId = _submit();
        vm.roll(103);
        bytes32 firstCommitment = mod.commitHash(caseId, 0, VOTER, 1, bytes32("salt"));
        vm.prank(VOTER);
        mod.commit(caseId, firstCommitment);
        vm.warp(uint256(mod.caseInfo(caseId).phaseDeadline));
        mod.closeCommitA(caseId);
        _readyB(mod, caseId);
        vm.roll(uint256(mod.caseInfo(caseId).seedBlockB) + 1);
        uint256 deadline = mod.caseInfo(caseId).phaseDeadline;
        vm.expectRevert(Moderation.NoCommitment.selector);
        vm.prank(secondVoter);
        mod.commit(caseId, bytes32(0));
        assertEq(mod.caseInfo(caseId).commitsB, 0);
        assertEq(mod.caseInfo(caseId).phaseDeadline, deadline);
        assertEq(stakes.openVotes(secondVoter), 0);
        assertEq(mod.voteOf(caseId, secondVoter).commitment, bytes32(0));
        bytes32 commitment = mod.commitHash(caseId, 0, secondVoter, 1, bytes32("salt"));
        vm.prank(secondVoter);
        mod.commit(caseId, commitment);
        assertEq(mod.caseInfo(caseId).commitsB, 1);
        assertEq(mod.caseInfo(caseId).commitsA, 1);
        assertEq(stakes.openVotes(secondVoter), 1);
    }

    function _unresolvedClaim(bool reveal) internal {
        uint256 caseId = _submit();
        vm.roll(103);
        bytes32 commitment = mod.commitHash(caseId, 0, VOTER, 1, bytes32("salt"));
        vm.prank(VOTER);
        mod.commit(caseId, commitment);
        vm.warp(uint256(mod.caseInfo(caseId).phaseDeadline) + 1);
        mod.closeCommitA(caseId);
        _readyB(mod, caseId);
        vm.roll(uint256(mod.caseInfo(caseId).seedBlockB) + 3);
        vm.warp(uint256(mod.caseInfo(caseId).phaseDeadline) + 1);
        mod.closeCommitB(caseId);
        if (reveal) {
            vm.prank(VOTER);
            mod.reveal(caseId, 1, bytes32("salt"));
        }
        vm.warp(uint256(mod.caseInfo(caseId).phaseDeadline) + 1);
        mod.closeReveal(caseId);
        vm.expectEmit(true, true, false, true, address(mod));
        emit Moderation.Claimed(caseId, VOTER, 0, !reveal);
        mod.claim(caseId, VOTER);
        assertEq(stakes.isFrozen(VOTER), !reveal);
        assertEq(stakes.openVotes(VOTER), 0);
        assertEq(token.balanceOf(VOTER), 0);
        assertEq(mod.refundOwed(caseId), FEE);
    }

    function test_unresolvedNonrevealerEventMatchesActualFreeze() public { _unresolvedClaim(false); }
    function test_unresolvedRevealerEventReportsNoFreeze() public { _unresolvedClaim(true); }
}
