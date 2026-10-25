// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HistoryFixture} from "../test/helpers/HistoryFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "../test/mocks/MockBZZ.sol";

/// @notice Diagnostic witnesses for the takeover audit. Passing means the reported
/// behavior exists, NOT that the behavior is correct. Run separately with
/// FOUNDRY_TEST=audit. Convert each witness to a regression test when fixing it.
contract TakeoverProbes is HistoryFixture {
    Moderation mod;
    StakeRegistry stakes;
    IndexRegistry index;
    MockBZZ token;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;
    uint256 constant FEE = 1200;
    uint256 constant STAKE = 1000;
    uint256 constant WAIT = 1 hours;
    uint256 constant REVEAL = 30 minutes;
    uint256 constant FREEZE = 8 days;
    bytes32 constant TOPIC = keccak256("biology");
    address constant PUBLISHER = address(0x5011);
    address[24] members;
    uint256 height = 100;
    uint256 timestamp = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new StakeRegistry(address(token), STAKE);
        index = new IndexRegistry();
        mod = new Moderation(Moderation.Config({
            token: address(token), stakes: address(stakes), index: address(index),
            commitWindow: 15 minutes, revealWindow: REVEAL, challengeWindow: WAIT,
            maxWaitForThird: WAIT, freezePerLoss: FREEZE, seedLag: 2,
            feeMin: FEE, minRevealsPerCommittee: 3,
            guidelinesVersion: 1, guidelinesHash: keccak256("audit-fixture")
        }));
        stakes.setModeration(address(mod));
        index.setModeration(address(mod));
        for (uint256 i; i < members.length; ++i) {
            members[i] = address(uint160(0x1000 + i));
            token.mint(members[i], STAKE);
            vm.startPrank(members[i]);
            token.approve(address(stakes), STAKE);
            stakes.stake();
            vm.stopPrank();
        }
        token.mint(PUBLISHER, 100 * FEE);
        vm.prank(PUBLISHER);
        token.approve(address(mod), type(uint256).max);
        vm.roll(height);
        vm.warp(timestamp);
    }

    function _blocks(uint256 count) internal {
        height += count;
        vm.roll(height);
    }

    function _time(uint256 seconds_) internal {
        timestamp += seconds_;
        vm.warp(timestamp);
    }

    function _submit(bytes32 topic) internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic;
        vm.prank(PUBLISHER);
        id = mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
    }

    function _commit(uint256 id, uint256 member, uint8 vote) internal {
        bytes32 h = mod.commitHash(id, 0, members[member], vote, bytes32("salt"));
        vm.prank(members[member]);
        mod.commit(id, h);
    }

    // First `approvals` members approve; the remaining members reject. Both
    // committees reach the deployed reveal floor of three when revealAll is true.
    function _round(uint256 id, uint256 approvals, bool revealAll) internal {
        _blocks(3);
        for (uint256 i; i < 3; ++i) _commit(id, i, i < approvals ? APPROVE : REJECT);
        _time(WAIT + 1);
        mod.closeCommitA(id);
        height = _readyB(mod, id);
        _blocks(3);
        for (uint256 i = 3; i < 6; ++i) _commit(id, i, i < approvals ? APPROVE : REJECT);
        _time(WAIT + 1);
        mod.closeCommitB(id);
        if (revealAll) {
            for (uint256 i; i < 6; ++i) {
                vm.prank(members[i]);
                mod.reveal(id, i < approvals ? APPROVE : REJECT, bytes32("salt"));
            }
        }
        _time(REVEAL + 1);
        mod.closeReveal(id);
    }

    function _entropyFor(uint256 id, uint8 expected) internal view returns (bytes32) {
        for (uint256 i = 1; i < 1024; ++i) {
            bytes32 entropy = bytes32(i);
            (uint8 outcome,) = mod.decideAt(id, entropy);
            if (outcome == expected) return entropy;
        }
        revert("fixture could not find entropy");
    }

    function _draw(uint256 id, uint8 outcome) internal {
        uint256 seed = mod.caseInfo(id).outcomeSeedBlock;
        _blocks(3);
        vm.setBlockhash(seed, _entropyFor(id, outcome));
        mod.draw(id);
    }

    function test_regressionOutcomeSeedCannotBeReplacedAfterItIsKnown() public {
        uint256 id = _submit(TOPIC);
        _round(id, 3, true);
        uint256 firstSeed = mod.caseInfo(id).outcomeSeedBlock;
        _blocks(3);
        bytes32 firstEntropy = _entropyFor(id, REJECT);
        vm.setBlockhash(firstSeed, firstEntropy);
        (uint8 firstOutcome,) = mod.decideAt(id, firstEntropy);
        assertEq(firstOutcome, REJECT);

        vm.prank(address(0xBAD)); // no stake, ownership, or challenge required
        vm.expectRevert(Moderation.BadPhase.selector);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).outcomeSeedBlock, firstSeed);
        assertEq(mod.caseInfo(id).challenges, 0);
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, REJECT, "draw uses the original known hash");
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.CHALLENGE));
    }

    function test_regressionZeroCommitmentsCannotInflateCountsOrLockStake() public {
        uint256 id = _submit(TOPIC);
        _blocks(3);
        vm.startPrank(members[0]);
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(Moderation.NoCommitment.selector);
            mod.commit(id, bytes32(0));
        }
        vm.stopPrank();
        assertEq(mod.caseInfo(id).commitsA, 0);
        assertEq(stakes.openVotes(members[0]), 0);
        vm.prank(members[0]);
        stakes.withdraw();
        assertEq(token.balanceOf(members[0]), STAKE);
    }

    function test_regressionZeroTopicRejectedBeforeFeeCollection() public {
        vm.expectRevert(Moderation.BadTopics.selector);
        _submit(bytes32(0));
        assertEq(mod.nextCaseId(), 1);
        assertEq(token.balanceOf(PUBLISHER), 100 * FEE);
        assertEq(token.balanceOf(address(mod)), 0);
    }

    function test_regressionUnresolvedClaimEventReportsAppliedFreeze() public {
        uint256 id = _submit(TOPIC);
        _round(id, 6, false);
        vm.recordLogs();
        mod.claim(id, members[0]);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawClaim;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(mod)) continue;
            if (logs[i].topics[0] != keccak256("Claimed(uint256,address,uint256,bool)")) continue;
            (uint256 paid, bool reportedFrozen) = abi.decode(logs[i].data, (uint256, bool));
            assertEq(paid, 0);
            assertTrue(reportedFrozen);
            sawClaim = true;
        }
        assertTrue(sawClaim);
        assertTrue(stakes.isFrozen(members[0]));
        assertEq(stakes.totalFrozen(members[0]), FREEZE);
    }

    function test_probeAnUnsettledLoserCanCommitToAnotherCase() public {
        uint256 id = _submit(TOPIC);
        _round(id, 5, true);
        _draw(id, APPROVE);
        _time(WAIT + 1);
        mod.closeChallenge(id);
        assertFalse(stakes.isFrozen(members[5]));

        uint256 next = _submit(TOPIC);
        _blocks(3);
        _commit(next, 5, APPROVE);
        assertEq(stakes.openVotes(members[5]), 2);
        mod.claim(id, members[5]); // permissionless settlement applies the freeze
        assertTrue(stakes.isFrozen(members[5]));
    }

    function test_probeDuplicateApprovalErasesTheIndexChallengeFlag() public {
        uint256 id = _submit(TOPIC);
        _round(id, 6, true);
        _draw(id, APPROVE);
        vm.prank(members[23]);
        mod.challenge(id);
        _time(WAIT + 1);
        mod.closeCommitA(id);
        height = _readyB(mod, id);
        _time(WAIT + 1);
        mod.closeCommitB(id);
        _time(REVEAL + 1);
        mod.closeReveal(id);
        bytes32 claimKey = mod.caseInfo(id).claimKey;
        assertTrue(index.entryOf(claimKey, TOPIC).everChallenged);

        uint256 duplicate = _submit(TOPIC);
        _round(duplicate, 6, true);
        _draw(duplicate, APPROVE);
        _time(WAIT + 1);
        mod.closeChallenge(duplicate);
        assertEq(mod.caseInfo(duplicate).claimKey, claimKey);
        assertEq(index.listedCount(TOPIC), 1);
        assertFalse(index.entryOf(claimKey, TOPIC).everChallenged);
        assertTrue(mod.caseInfo(id).everChallenged); // the old case still has its history
    }
}
