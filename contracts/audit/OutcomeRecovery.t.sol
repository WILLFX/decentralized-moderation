// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {CompletionReviewProbes} from "./CompletionReviewProbes.t.sol";
import {Moderation} from "../src/Moderation.sol";
import {Vm} from "forge-std/Vm.sol";

/// Known-answer chain fixtures, not caller-chosen entropy on a real chain.
contract OutcomeRecoveryTest is CompletionReviewProbes {
    function _assertTransition(Vm.Log[] memory logs, uint8 expectedPhase) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mod) && logs[i].topics[0] == keccak256("PhaseChanged(uint256,uint8,uint8)")) {
                (uint8 from, uint8 to) = abi.decode(logs[i].data, (uint8, uint8));
                assertEq(from, uint8(Moderation.Phase.REVEAL));
                assertEq(to, expectedPhase);
                ++count;
            }
        }
        assertEq(count, 1);
    }
    function _mixed(uint8 round, uint256 offset) internal pure returns (uint8) {
        return round == 0 ? (offset % 3 == 2 ? 2 : 1) : (offset % 2 == 0 ? 1 : 2);
    }
    function _mixedArm(uint256 id, uint8 round, bool nonrevealer) internal {
        uint256 first = uint256(round) * 6;
        uint256 seedA = mod.caseInfo(id).seedBlockA;
        _tickBlock(seedA + 1);
        vm.setBlockhash(seedA, keccak256(abi.encode("A", round)));
        for (uint256 i; i < 3; ++i) _cast(id, first + i, _mixed(round, i));
        if (nonrevealer) _cast(id, 18, 1);
        _tickTime(mod.pairScheduleOf(id).deadlineA);
        mod.closeCommitA(id);
        uint256 seedB = mod.caseInfo(id).seedBlockB;
        if (block.number <= seedB) _tickBlock(seedB + 1);
        _recordHistory(seedB, keccak256(abi.encode("B", round)));
        for (uint256 i = 3; i < 6; ++i) _cast(id, first + i, _mixed(round, i));
        _tickTime(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id);
        for (uint256 i; i < 6; ++i) {
            vm.prank(members[first + i]); mod.reveal(id, _mixed(round, i), SALT);
        }
        _tickTime(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
    }
    function _matrix(bool removal, uint8 lastRound, uint8 fallbackOutcome) internal {
        uint256 listing;
        uint256 id;
        if (removal) {
            listing = _finalListing();
            vm.prank(PUBLISHER); id = mod.submitRemoval(listing, FEE);
        } else { id = _submit(); }
        for (uint8 r; r <= lastRound; ++r) {
            _mixedArm(id, r, r == lastRound);
            if (r < lastRound) {
                _drawAs(id, fallbackOutcome);
                vm.prank(members[22 + r]); mod.challenge(id, r, fallbackOutcome);
                // The challenger is tagged with the reviewed round, not the round opened.
                assertEq(mod.voteOf(id, members[22 + r]).round, r);
            }
        }
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(uint256(target) + mod.BLOCK_HISTORY_WINDOW());
        vm.expectRevert(Moderation.TooEarly.selector); mod.expireOutcome(id, lastRound, target);
        _tickBlock(block.number + 1);
        vm.expectRevert(Moderation.OutcomeIntentChanged.selector); mod.expireOutcome(id, lastRound, target + 1);
        vm.expectRevert(Moderation.OutcomeIntentChanged.selector); mod.expireOutcome(id, lastRound + 1, target);
        vm.recordLogs(); mod.expireOutcome(id, lastRound, target);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertTransition(logs, lastRound == 0 ? 6 : 5);
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("PreliminaryOutcome(uint256,uint8,uint8,uint8)"),
                "expiry must not announce a new draw");
        }
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], keccak256("OutcomeDrawExpired(uint256,uint8,uint256,uint8,uint8)"));
        (uint256 loggedTarget, uint8 outcome, uint8 terminal) = abi.decode(last.data, (uint256, uint8, uint8));
        assertEq(loggedTarget, target); assertEq(outcome, lastRound == 0 ? 0 : fallbackOutcome);
        assertEq(terminal, lastRound == 0 ? 6 : 5);
        assertEq(mod.caseInfo(id).phase, terminal);
        assertTrue(mod.outcomeExpired(id));
        if (removal) {
            assertEq(mod.openRemovalOf(listing), 0);
            assertEq(mod.removed(listing), lastRound != 0 && fallbackOutcome == 1);
        }
        assertEq(index.isListed(mod.caseInfo(id).claimKey, keccak256("biology")),
            removal ? !(lastRound != 0 && fallbackOutcome == 1) : lastRound != 0 && fallbackOutcome == 1);
        uint256 beforeBalance = token.balanceOf(address(mod));
        uint256 paid;
        for (uint256 i; i < (uint256(lastRound) + 1) * 6; ++i) paid += _settle(id, i, lastRound == 0);
        for (uint256 i; i < lastRound; ++i) paid += _settle(id, 22 + i, false);
        paid += _settle(id, 18, lastRound == 0);
        if (lastRound == 0) {
            assertEq(paid, 0); assertEq(mod.refundOwed(id), FEE);
            uint256 beforePublisher = token.balanceOf(PUBLISHER);
            mod.withdrawRefund(id);
            assertEq(token.balanceOf(PUBLISHER), beforePublisher + FEE);
            assertEq(token.balanceOf(address(mod)), beforeBalance - FEE);
            vm.expectRevert(Moderation.NothingToClaim.selector); mod.withdrawRefund(id);
        } else {
            assertEq(mod.refundOwed(id), 0);
            uint256 winners = fallbackOutcome == 1 ? mod.caseInfo(id).pooledApprove : mod.caseInfo(id).pooledReject;
            assertEq(paid, FEE / winners * winners);
            assertEq(token.balanceOf(address(mod)), beforeBalance - paid);
            assertLt(FEE - paid, winners); // only integer-division dust remains
        }
        vm.expectRevert(Moderation.BadPhase.selector); mod.expireOutcome(id, lastRound, target);
        vm.expectRevert(Moderation.BadPhase.selector); mod.draw(id);
    }
    function _settle(uint256 id, uint256 member, bool unresolved) internal returns (uint256 paid) {
        address who = members[member];
        Moderation.Vote memory vote = mod.voteOf(id, who);
        uint256 beforeBalance = token.balanceOf(who);
        uint256 beforeFrozen = stakes.totalFrozen(who);
        mod.claim(id, who);
        paid = token.balanceOf(who) - beforeBalance;
        bool freeze = vote.revealed == 0 || (!unresolved && vote.revealed != mod.caseInfo(id).preliminary);
        assertEq(stakes.totalFrozen(who) - beforeFrozen, freeze ? 8 days : 0);
        assertEq(stakes.openVotes(who), 0);
        assertTrue(mod.voteOf(id, who).settled);
        if (unresolved || vote.revealed != mod.caseInfo(id).preliminary) assertEq(paid, 0);
        else assertEq(paid, mod.shareOf(id));
        vm.expectRevert(Moderation.NothingToClaim.selector); mod.claim(id, who);
    }
    function test_regressionListInitialExpiry() public { _matrix(false, 0, 1); }
    function test_regressionRemoveInitialExpiry() public { _matrix(true, 0, 1); }
    function test_regressionListFirstApproveExpiry() public { _matrix(false, 1, 1); }
    function test_regressionListFirstRejectExpiry() public { _matrix(false, 1, 2); }
    function test_regressionListSecondApproveExpiry() public { _matrix(false, 2, 1); }
    function test_regressionListSecondRejectExpiry() public { _matrix(false, 2, 2); }
    function test_regressionRemoveFirstApproveExpiry() public { _matrix(true, 1, 1); }
    function test_regressionRemoveFirstRejectExpiry() public { _matrix(true, 1, 2); }
    function test_regressionRemoveSecondApproveExpiry() public { _matrix(true, 2, 1); }
    function test_regressionRemoveSecondRejectExpiry() public { _matrix(true, 2, 2); }
    function test_regressionHistoryLastBlockCachesOriginalIndefinitely() public {
        uint256 id = _submit(); _arm(id, 0, 1);
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        bytes32 original = keccak256("original outcome");
        _tickBlock(uint256(target) + 8191); _recordHistory(target, original);
        vm.recordLogs(); mod.cacheOutcome(id);
        Vm.Log[] memory cacheLogs = vm.getRecordedLogs();
        assertEq(cacheLogs.length, 1);
        assertEq(cacheLogs[0].topics[0], keccak256("OutcomeHashCached(uint256,uint8,uint256,bytes32)"));
        (uint256 cachedTarget, bytes32 loggedHash) = abi.decode(cacheLogs[0].data, (uint256, bytes32));
        assertEq(cachedTarget, target); assertEq(loggedHash, original);
        (, bytes32 cached, uint256 until,) = mod.outcomeRecoveryOf(id);
        assertEq(cached, original); assertEq(until, uint256(target) + 8191);
        _tickBlock(block.number + 10000);
        vm.etch(HISTORY_ADDRESS, hex"60006000fd");
        vm.expectRevert(Moderation.OutcomeRecoverable.selector); mod.expireOutcome(id, 0, target);
        vm.recordLogs(); mod.cacheOutcome(id); // idempotent; history no longer needed
        assertEq(vm.getRecordedLogs().length, 0);
        mod.draw(id); assertEq(mod.caseInfo(id).preliminary, 1);
    }
    function test_regressionOpcodeBoundaryAndNoHashInjection() public {
        uint256 id = _submit(); _arm(id, 0, 1);
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(target); vm.expectRevert(Moderation.TooEarly.selector); mod.cacheOutcome(id);
        _tickBlock(uint256(target) + 256);
        bytes32 original = keccak256("opcode target"); vm.setBlockhash(target, original);
        mod.cacheOutcome(id);
        (,bytes32 cached,,) = mod.outcomeRecoveryOf(id); assertEq(cached, original);
        vm.expectRevert(Moderation.BadPhase.selector); mod.closeReveal(id);
        assertEq(mod.caseInfo(id).outcomeSeedBlock, target);
    }
    function _failedHistory(bytes memory code) internal {
        uint256 id = _submit(); _arm(id, 0, 1);
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(uint256(target) + 257); vm.etch(HISTORY_ADDRESS, code);
        vm.expectRevert(Moderation.SeedUnavailable.selector); mod.cacheOutcome(id);
        vm.expectRevert(Moderation.SeedUnavailable.selector); mod.draw(id);
        vm.expectRevert(Moderation.TooEarly.selector); mod.expireOutcome(id, 0, target);
        (,bytes32 cached,,bool expired) = mod.outcomeRecoveryOf(id);
        assertEq(cached, bytes32(0)); assertFalse(expired);
        assertEq(mod.caseInfo(id).phase, 3);
        // A subsequent correct history read recovers the same target.
        _recordHistory(target, keccak256("restored original")); mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, 1);
    }
    function test_regressionRevertingHistoryIsNotExpiry() public { _failedHistory(hex"60006000fd"); }
    function test_regressionMalformedHistoryIsNotExpiry() public { _failedHistory(hex"60016000f3"); }
    function test_regressionZeroHistoryIsNotExpiry() public { _failedHistory(hex"60206000f3"); }
    function test_regressionAbsentHistoryIsNotExpiry() public { _failedHistory(hex""); }
    function test_regressionNextRoundCannotReuseEarlierHash() public {
        uint256 id = _submit(); _arm(id, 0, 1); _drawAs(id, 1);
        vm.prank(members[22]); mod.challenge(id, 0, 1);
        _arm(id, 6, 1);
        (,bytes32 cached,,) = mod.outcomeRecoveryOf(id); assertEq(cached, bytes32(0));
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(uint256(target) + 8192); mod.expireOutcome(id, 1, target);
        assertEq(mod.caseInfo(id).phase, 5);
    }
    function _cacheBoundaryCase(uint8 action, uint8 round) internal {
        uint256 id;
        if (action == 1) {
            uint256 listing = _finalListing();
            vm.prank(PUBLISHER); id = mod.submitRemoval(listing, FEE);
        } else id = _submit();
        for (uint8 r; r <= round; ++r) {
            _arm(id, uint256(r) * 6, 1);
            if (r < round) {
                _drawAs(id, 1);
                vm.prank(members[22 + r]); mod.challenge(id, r, 1);
            }
        }
        uint40 target = mod.caseInfo(id).outcomeSeedBlock;
        bytes32 original = keccak256(abi.encode("original", action, round));
        (uint8 expected, uint8 tickets) = mod.decideAt(id, original);
        _tickBlock(uint256(target) + 8191); _recordHistory(target, original); mod.cacheOutcome(id);
        _tickBlock(block.number + 8192);
        vm.expectRevert(Moderation.OutcomeRecoverable.selector); mod.expireOutcome(id, round, target);
        vm.recordLogs(); mod.draw(id);
        _assertTransition(vm.getRecordedLogs(), round == 2 ? 5 : 4);
        assertEq(mod.caseInfo(id).preliminary, expected);
        assertEq(mod.caseInfo(id).ticketsApprove, tickets);
        assertEq(mod.caseInfo(id).phase, round == 2 ? 5 : 4);
    }
    function test_regressionCachedListInitial() public { _cacheBoundaryCase(0, 0); }
    function test_regressionCachedListFirstChallenge() public { _cacheBoundaryCase(0, 1); }
    function test_regressionCachedListSecondChallenge() public { _cacheBoundaryCase(0, 2); }
    function test_regressionCachedRemoveInitial() public { _cacheBoundaryCase(1, 0); }
    function test_regressionCachedRemoveFirstChallenge() public { _cacheBoundaryCase(1, 1); }
    function test_regressionCachedRemoveSecondChallenge() public { _cacheBoundaryCase(1, 2); }

    function _assertOpening(Vm.Log[] memory logs, uint8 expectedFrom) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mod) && logs[i].topics[0] == keccak256("PhaseChanged(uint256,uint8,uint8)")) {
                (uint8 from, uint8 to) = abi.decode(logs[i].data, (uint8, uint8));
                assertEq(from, expectedFrom);
                assertEq(to, uint8(Moderation.Phase.COMMIT_A));
                ++count;
            }
        }
        assertEq(count, 1);
    }
    function _openingEvents(bool removal) internal {
        uint256 id;
        if (removal) {
            uint256 listing = _finalListing();
            vm.recordLogs();
            vm.prank(PUBLISHER); id = mod.submitRemoval(listing, FEE);
        } else { vm.recordLogs(); id = _submit(); }
        _assertOpening(vm.getRecordedLogs(), uint8(Moderation.Phase.NONE));
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_A));
        for (uint8 round; round < 2; ++round) {
            _arm(id, uint256(round) * 6, 1);
            _drawAs(id, 1);
            vm.recordLogs();
            vm.prank(members[22 + round]); mod.challenge(id, round, 1);
            _assertOpening(vm.getRecordedLogs(), uint8(Moderation.Phase.CHALLENGE));
            assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_A));
            assertEq(mod.caseInfo(id).challenges, round + 1);
        }
    }
    function test_regressionListOpeningAndBothChallengeEvents() public { _openingEvents(false); }
    function test_regressionRemoveOpeningAndBothChallengeEvents() public { _openingEvents(true); }

}
