// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HistoryFixture} from "./helpers/HistoryFixture.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

contract ProductionSchedulingTest is HistoryFixture {
    Moderation mod;
    StakeRegistry stakes;
    IndexRegistry index;
    MockBZZ token;
    address[24] members;
    address constant PUBLISHER = address(0x5011);
    uint256 constant FEE = 1200;
    bytes32 constant SALT = bytes32("schedule salt");
    bytes32 constant ENTROPY = keccak256("selected B target");

    function setUp() public {
        _deploy(3600);
    }

    function _deploy(uint256 maximumWait) internal {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockBZZ();
        stakes = new StakeRegistry(address(token), 1000);
        index = new IndexRegistry();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            900, 1800, 3600, maximumWait, 8 days, 2, FEE, 3, 1, keccak256("guidelines")));
        stakes.setModeration(address(mod));
        index.setModeration(address(mod));
        for (uint256 i; i < members.length; ++i) {
            members[i] = address(uint160(0x1000 + i));
            token.mint(members[i], 1000);
            vm.startPrank(members[i]);
            token.approve(address(stakes), 1000);
            stakes.stake();
            vm.stopPrank();
        }
        token.mint(PUBLISHER, 100 * FEE);
        vm.prank(PUBLISHER);
        token.approve(address(mod), type(uint256).max);
    }

    function _submit() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(PUBLISHER);
        return mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
    }

    function _commit(uint256 id, uint256 member) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, members[member], 1, SALT);
        vm.prank(members[member]);
        mod.commit(id, h);
    }

    function _reject(uint256 id, uint256 member, bytes4 error) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, members[member], 1, SALT);
        vm.expectRevert(error);
        vm.prank(members[member]);
        mod.commit(id, h);
    }

    function _firstA(uint256 id, uint256 count) internal {
        vm.roll(uint256(mod.caseInfo(id).seedBlockA) + 1);
        for (uint256 i; i < count; ++i) _commit(id, i);
    }

    function _historyReady(uint256 id, uint256 age) internal {
        uint256 target = mod.caseInfo(id).seedBlockB;
        vm.roll(target + age);
        vm.warp(mod.pairScheduleOf(id).deadlineA);
        _recordHistory(target, ENTROPY);
    }

    function _state(uint256 id, address voter) internal view returns (bytes32) {
        return keccak256(abi.encode(mod.caseInfo(id), mod.pairScheduleOf(id),
            mod.voteOf(id, voter), stakes.openVotes(voter), token.balanceOf(address(mod))));
    }

    function test_fallbackAndThirdCommitRevisionUseKnownTargets() public {
        uint256 id = _submit();
        assertEq(mod.caseInfo(id).seedBlockB, 822);
        assertEq(mod.pairScheduleOf(id).deadlineA, 1_003_600);
        assertEq(mod.pairScheduleOf(id).deadlineB, 1_007_200);
        _firstA(id, 2);
        assertEq(mod.caseInfo(id).seedBlockB, 822, "two commits retain fallback");
        _commit(id, 2);
        assertEq(mod.caseInfo(id).seedBlockB, 285);
        assertEq(mod.pairScheduleOf(id).deadlineA, 1_000_900);
        assertEq(mod.pairScheduleOf(id).deadlineB, 1_004_500);
        assertTrue(mod.pairScheduleOf(id).revised);
        bytes32 schedule = keccak256(abi.encode(mod.pairScheduleOf(id)));
        _commit(id, 3);
        assertEq(keccak256(abi.encode(mod.pairScheduleOf(id))), schedule);
        assertEq(mod.caseInfo(id).seedBlockB, 285);
    }

    function test_thirdCommitCannotReviseAKnownFallback() public {
        // Keep A's eligibility hash inside its horizon when the fallback arrives,
        // so the attempted third vote reaches the schedule revision guard.
        _deploy(900);
        uint256 id = _submit();
        _firstA(id, 2);
        // Deliberately violate the timing premise to exercise the explicit guard.
        vm.roll(mod.caseInfo(id).seedBlockB);
        bytes32 beforeState = _state(id, members[2]);
        _reject(id, 2, Moderation.SeedUnavailable.selector);
        assertEq(_state(id, members[2]), beforeState);
    }

    function test_fallbackActivatesWithTwoACommittersAndNoCloseCall() public {
        uint256 id = _submit();
        _firstA(id, 2);
        _historyReady(id, 1);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_A));
        bytes32 beforeView = _state(id, members[3]);
        assertTrue(mod.isEligible(id, members[3]));
        assertEq(_state(id, members[3]), beforeView, "view does not activate or cache");
        _commit(id, 3);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_B));
        assertEq(mod.caseInfo(id).commitsA, 2);
        assertEq(mod.caseInfo(id).commitsB, 1);
        assertEq(mod.voteOf(id, members[3]).committee, 2);
        assertEq(mod.pairScheduleOf(id).entropyB, ENTROPY);
        assertFalse(mod.pairScheduleOf(id).revised);
        assertEq(mod.caseInfo(id).seedBlockB, 822);
    }

    function test_invalidEntrantsCannotActivateCacheOrChangeLocks() public {
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, 1);
        bytes32 beforeState = _state(id, members[3]);
        vm.prank(members[3]);
        vm.expectRevert(Moderation.NoCommitment.selector);
        mod.commit(id, bytes32(0));
        assertEq(_state(id, members[3]), beforeState);
        beforeState = _state(id, members[0]);
        _reject(id, 0, Moderation.AlreadyVoted.selector);
        assertEq(_state(id, members[0]), beforeState);
        vm.prank(address(0xBAD));
        vm.expectRevert(Moderation.NotEligible.selector);
        mod.commit(id, bytes32(uint256(1)));
        assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0));
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_A));
        _commit(id, 3);
        assertEq(stakes.openVotes(members[3]), 1);
    }

    function test_missingMalformedZeroAndRevertingHistoryLeaveScheduleUntouched() public {
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, 1);
        bytes32 beforeState = _state(id, members[3]);
        uint256 target = mod.caseInfo(id).seedBlockB;
        vm.etch(HISTORY_ADDRESS, hex"");
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        _recordHistory(target, bytes32(0));
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        vm.mockCall(HISTORY_ADDRESS, abi.encode(target), hex"01");
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        vm.clearMockedCalls();
        vm.mockCall(HISTORY_ADDRESS, abi.encode(target), abi.encode(ENTROPY, ENTROPY));
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        vm.clearMockedCalls();
        vm.mockCallRevert(HISTORY_ADDRESS, abi.encode(target), hex"1234");
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        vm.clearMockedCalls();
        assertEq(_state(id, members[3]), beforeState);
        _recordHistory(target, ENTROPY);
        _commit(id, 3);
    }

    function testFuzz_historyIsUsableAtEveryServedAge(uint256 age) public {
        age = bound(age, 1, 8191);
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, age);
        _commit(id, 3);
        assertEq(mod.pairScheduleOf(id).entropyB, ENTROPY);
    }

    function test_targetBlockAndExpiredHistoryCannotActivate() public {
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, 0);
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        _historyReady(id, 8192);
        _reject(id, 3, Moderation.SeedUnavailable.selector);
        assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0));
        assertEq(mod.caseInfo(id).commitsB, 0);
    }

    function test_historyWindowEndpointsAreInclusiveAndRejectNextAge() public {
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, 1);
        assertTrue(mod.isEligible(id, members[3]));
        _historyReady(id, 8191);
        assertTrue(mod.isEligible(id, members[3]));
        assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0), "views do not retain history");
        _historyReady(id, 8192);
        vm.expectRevert(Moderation.SeedUnavailable.selector);
        mod.isEligible(id, members[3]);
    }

    function test_lotteryLoserCannotActivateOrCache() public {
        // The current N-4 rule still uses the staked-count denominator.
        for (uint256 i = 24; i < 64; ++i) {
            address member = address(uint160(0x1000 + i));
            token.mint(member, 1000);
            vm.startPrank(member);
            token.approve(address(stakes), 1000);
            stakes.stake();
            vm.stopPrank();
        }
        uint256 id = _submit();
        assertEq(mod.caseInfo(id).eligBits, 2);
        vm.roll(uint256(mod.caseInfo(id).seedBlockA) + 1);
        for (uint256 i; i < members.length && mod.caseInfo(id).commitsA < 3; ++i) {
            if (mod.isEligible(id, members[i])) _commit(id, i);
        }
        assertEq(mod.caseInfo(id).commitsA, 3);
        _historyReady(id, 1);
        bool found;
        for (uint256 i; i < members.length; ++i) {
            if (mod.voteOf(id, members[i]).commitment != bytes32(0) || mod.isEligible(id, members[i])) continue;
            bytes32 beforeState = _state(id, members[i]);
            _reject(id, i, Moderation.NotEligible.selector);
            assertEq(_state(id, members[i]), beforeState);
            found = true;
            break;
        }
        assertTrue(found, "fixture must include a lottery loser");
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_A));
        assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0));
    }

    function test_cachedHashSurvivesHistoryExpiryWithoutChangingDeadline() public {
        uint256 id = _submit();
        _firstA(id, 3);
        _historyReady(id, 1);
        _commit(id, 3);
        uint256 deadline = mod.pairScheduleOf(id).deadlineB;
        vm.roll(uint256(mod.caseInfo(id).seedBlockB) + 8192);
        vm.etch(HISTORY_ADDRESS, hex"");
        _commit(id, 4);
        assertEq(mod.pairScheduleOf(id).deadlineB, deadline, "second commit does not restart clock");
        assertEq(mod.pairScheduleOf(id).entropyB, ENTROPY);
        _commit(id, 5);
        assertEq(mod.pairScheduleOf(id).deadlineB, 1_001_800, "third B starts ordinary window");
        vm.warp(1_000_910);
        _commit(id, 6);
        assertEq(mod.pairScheduleOf(id).deadlineB, 1_001_800);
    }

    function test_delayedOptionalCloseCannotRearmOrRestartBWindow() public {
        uint256 id = _submit();
        _firstA(id, 3);
        uint256 target = mod.caseInfo(id).seedBlockB;
        uint256 deadline = mod.pairScheduleOf(id).deadlineB;
        vm.warp(mod.pairScheduleOf(id).deadlineA + 600);
        mod.closeCommitA(id);
        assertEq(mod.caseInfo(id).seedBlockB, target);
        assertEq(mod.caseInfo(id).phaseDeadline, deadline);
        assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0));
        vm.warp(deadline);
        _reject(id, 3, Moderation.TooLate.selector);
        mod.closeCommitB(id);
        assertEq(mod.caseInfo(id).phaseDeadline, deadline + 1800, "reveal still opens on a transaction");
    }

    function test_absentBAndMissingHistoryReachOriginalRefundAndSettlement() public {
        uint256 id = _submit();
        _firstA(id, 3);
        vm.warp(mod.pairScheduleOf(id).deadlineB + 600);
        mod.closeCommitB(id); // No closeCommitA or B activation is required.
        uint256 revealEnd = mod.caseInfo(id).phaseDeadline;
        assertEq(revealEnd, 1_006_900, "late close opens a full 30-minute reveal");
        for (uint256 i; i < 3; ++i) {
            vm.prank(members[i]);
            mod.reveal(id, 1, SALT);
        }
        vm.warp(revealEnd);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.refundOwed(id), FEE);
        for (uint256 i; i < 3; ++i) {
            mod.claim(id, members[i]);
            assertEq(stakes.openVotes(members[i]), 0);
            assertFalse(stakes.isFrozen(members[i]));
        }
        mod.withdrawRefund(id);
        assertEq(token.balanceOf(address(mod)), 0);
    }

    function test_zeroInitialAStillRefundsWithoutActivatingB() public {
        uint256 id = _submit();
        _historyReady(id, 1);
        assertFalse(mod.isEligible(id, members[0]));
        _reject(id, 0, Moderation.BadPhase.selector);
        mod.closeCommitA(id);
        assertEq(mod.refundOwed(id), FEE);
    }

    function _finishPair(uint256 id, uint256 from) internal {
        uint256 seedA = mod.caseInfo(id).seedBlockA;
        vm.roll(seedA + 1);
        for (uint256 i = from; i < from + 3; ++i) _commit(id, i);
        _historyReady(id, 1);
        for (uint256 i = from + 3; i < from + 6; ++i) _commit(id, i);
        vm.warp(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id);
        for (uint256 i = from; i < from + 6; ++i) {
            vm.prank(members[i]);
            mod.reveal(id, 1, SALT);
        }
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256(abi.encode("outcome", from)));
        mod.draw(id);
    }

    function test_bothChallengesResetScheduleCacheAndRevisionAndPreserveFee() public {
        uint256 id = _submit();
        uint256 previousTarget;
        for (uint8 round; round < 3; ++round) {
            assertFalse(mod.pairScheduleOf(id).revised);
            assertEq(mod.pairScheduleOf(id).entropyB, bytes32(0));
            assertGt(mod.caseInfo(id).seedBlockB, previousTarget);
            uint256 approvalsBefore = mod.caseInfo(id).pooledApprove;
            _finishPair(id, uint256(round) * 6);
            assertTrue(mod.pairScheduleOf(id).revised);
            assertEq(mod.pairScheduleOf(id).entropyB, ENTROPY);
            assertEq(mod.caseInfo(id).pot, FEE);
            assertEq(mod.caseInfo(id).pooledApprove, approvalsBefore + 6);
            previousTarget = mod.caseInfo(id).seedBlockB;
            if (round < 2) {
                vm.prank(members[22 + round]);
                mod.challenge(id);
                assertEq(mod.caseInfo(id).outcomeSeedBlock, 0);
            }
        }
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
    }

    function test_removalOpensTheSameFallbackSchedule() public {
        uint256 listing = _submit();
        _finishPair(listing, 0);
        vm.warp(mod.caseInfo(listing).phaseDeadline);
        mod.closeChallenge(listing);
        vm.prank(PUBLISHER);
        uint256 removal = mod.submitRemoval(listing, FEE);
        assertGt(mod.caseInfo(removal).seedBlockB, mod.caseInfo(removal).seedBlockA);
        assertEq(mod.pairScheduleOf(removal).entropyB, bytes32(0));
        assertFalse(mod.pairScheduleOf(removal).revised);
        assertEq(mod.caseInfo(removal).actionType, mod.ACTION_REMOVE());
    }

    function test_unactivatedChallengeBPreservesStandingOutcomeAndPartialRewards() public {
        uint256 id = _submit();
        _finishPair(id, 0);
        assertEq(mod.caseInfo(id).preliminary, 1);
        vm.prank(members[22]);
        mod.challenge(id);
        vm.roll(uint256(mod.caseInfo(id).seedBlockA) + 1);
        for (uint256 i = 6; i < 9; ++i) _commit(id, i);
        vm.warp(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id); // B never activated, stored phase was still A.
        for (uint256 i = 6; i < 9; ++i) {
            vm.prank(members[i]);
            mod.reveal(id, 1, SALT);
        }
        vm.warp(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
        assertEq(mod.caseInfo(id).preliminary, 1);
        assertEq(mod.refundOwed(id), 0);
        assertEq(mod.caseInfo(id).pooledApprove, 9);
        mod.claim(id, members[6]);
        assertEq(token.balanceOf(members[6]), FEE / 9);
        assertFalse(stakes.isFrozen(members[6]));
        assertEq(stakes.openVotes(members[6]), 0);
        mod.claim(id, members[22]);
        assertTrue(stakes.isFrozen(members[22]));
        assertEq(stakes.openVotes(members[22]), 0);
    }
}
