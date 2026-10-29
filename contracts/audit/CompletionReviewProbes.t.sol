// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ProductionSchedulingTest} from "../test/ProductionScheduling.t.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";

/// @notice Completion, phase-event and bound-challenge safety regressions.
/// Real stake/index registries, reveal floor 3, 24 controlled staked identities.
/// Fixed-answer hash/history fixtures; no live-chain or independent-judgment claim.
/// Case/vote storage is never planted or overwritten. Time moves only in this VM.
contract CompletionReviewProbes is ProductionSchedulingTest {
    function _tickBlock(uint256 height) internal {
        require(height >= block.number, "review: block cannot go backwards");
        vm.warp(block.timestamp + (height - block.number) * 5);
        vm.roll(height);
    }

    function _tickTime(uint256 timestamp) internal {
        if (timestamp > block.timestamp) {
            _tickBlock(block.number + (timestamp - block.timestamp + 4) / 5);
        }
    }

    function _cast(uint256 id, uint256 member, uint8 vote) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, members[member], vote, SALT);
        vm.prank(members[member]);
        mod.commit(id, h);
    }

    function _revealedPair(uint256 id, uint256 first, uint8 vote) internal {
        uint256 seedA = mod.caseInfo(id).seedBlockA;
        _tickBlock(seedA + 1);
        vm.setBlockhash(seedA, keccak256(abi.encode("review A", id, first)));
        for (uint256 i = first; i < first + 3; ++i) _cast(id, i, vote);
        _tickTime(mod.pairScheduleOf(id).deadlineA);
        mod.closeCommitA(id);
        uint256 seedB = mod.caseInfo(id).seedBlockB;
        if (block.number <= seedB) _tickBlock(seedB + 1);
        _recordHistory(seedB, keccak256(abi.encode("review B", id, first)));
        for (uint256 i = first + 3; i < first + 6; ++i) _cast(id, i, vote);
        _tickTime(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id);
        for (uint256 i = first; i < first + 6; ++i) {
            vm.prank(members[i]);
            mod.reveal(id, vote, SALT);
        }
        _tickTime(mod.caseInfo(id).phaseDeadline);
        assertEq(mod.caseInfo(id).revealsA, 3);
        assertEq(mod.caseInfo(id).revealsB, 3);
    }

    function _arm(uint256 id, uint256 first, uint8 vote) internal {
        _revealedPair(id, first, vote);
        mod.closeReveal(id);
    }

    /// @dev Pick a known-answer fixture, not an attacker ability to pick chain entropy.
    function _drawAs(uint256 id, uint8 wanted) internal {
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(target + 1);
        for (uint256 i; i < 1024; ++i) {
            bytes32 entropy = keccak256(abi.encode("review outcome", id, i));
            (uint8 result,) = mod.decideAt(id, entropy);
            if (result == wanted) {
                vm.setBlockhash(target, entropy);
                mod.draw(id);
                assertEq(mod.caseInfo(id).preliminary, wanted);
                return;
            }
        }
        revert("review: no known-answer entropy found");
    }

    function _finalListing() internal returns (uint256 id) {
        id = _submit();
        _arm(id, 0, 1);
        _drawAs(id, 1);
        _tickTime(mod.caseInfo(id).phaseDeadline);
        mod.closeChallenge(id);
        for (uint256 i; i < 6; ++i) mod.claim(id, members[i]);
        assertEq(stakes.openVotes(members[0]), 0);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
    }

    function _blocked(bytes memory callData, bytes4 error) internal {
        (bool ok, bytes memory result) = address(mod).call(callData);
        assertFalse(ok, "an existing public exit unexpectedly succeeded");
        assertGe(result.length, 4);
        assertEq(bytes4(result), error);
    }

    function _assertUncachedExpirySettles(uint256 id, uint256 member) internal {
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(target + 257);
        _blocked(abi.encodeCall(Moderation.draw, (id)), Moderation.SeedUnavailable.selector);
        _blocked(abi.encodeCall(Moderation.expireOutcome, (id, mod.caseInfo(id).challenges, uint40(target))), Moderation.TooEarly.selector);
        _tickBlock(target + mod.BLOCK_HISTORY_WINDOW() + 1);
        mod.expireOutcome(id, mod.caseInfo(id).challenges, uint40(target));
        mod.claim(id, members[member]);
        assertEq(stakes.openVotes(members[member]), 0);
    }

    function test_regressionInitialDrawExpiryReleasesFeeAndStake() public {
        uint256 id = _submit();
        _arm(id, 0, 1);
        assertEq(mod.caseInfo(id).preliminary, 0);
        _assertUncachedExpirySettles(id, 0);
        assertEq(token.balanceOf(address(mod)), FEE);
    }

    function _challengeExpiry(uint8 round) internal {
        uint256 id = _submit();
        for (uint8 r; r <= round; ++r) {
            _arm(id, uint256(r) * 6, 1);
            if (r < round) {
                _drawAs(id, 1);
                Moderation.Case memory challengeIntent2 = mod.caseInfo(id);
                vm.prank(members[22 + r]);
                mod.challenge(id, challengeIntent2.challenges, challengeIntent2.preliminary);
            }
        }
        assertEq(mod.caseInfo(id).challenges, round);
        assertEq(mod.caseInfo(id).preliminary, 1, "standing outcome exists but is not claimable");
        _assertUncachedExpirySettles(id, uint256(round) * 6);
        assertEq(stakes.openVotes(members[22]), 1, "challenger remains open until its own settlement");
    }

    function test_regressionFirstChallengeDrawExpiryFinalizesStandingOutcome() public {
        _challengeExpiry(1);
    }

    function test_regressionSecondChallengeDrawExpiryHasExit() public {
        _challengeExpiry(2);
    }

    function test_regressionRemovalDrawExpiryReleasesRemovalSlot() public {
        uint256 listing = _finalListing();
        vm.prank(PUBLISHER);
        uint256 id = mod.submitRemoval(listing, FEE);
        _arm(id, 0, 1);
        _assertUncachedExpirySettles(id, 0);
        assertEq(mod.openRemovalOf(listing), 0);
        assertFalse(mod.removed(listing), "no removal was finalized");
        vm.prank(PUBLISHER);
        mod.submitRemoval(listing, FEE);
    }

    function test_regressionArmedDrawEventMatchesStoredPhase() public {
        uint256 id = _submit();
        _revealedPair(id, 0, 1);
        vm.recordLogs();
        mod.closeReveal(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("OutcomeDrawArmed(uint256,uint8,uint256,uint256)"));
        (uint256 target, uint256 until) = abi.decode(logs[0].data, (uint256, uint256));
        assertEq(target, mod.caseInfo(id).outcomeSeedBlock);
        assertEq(until, target + mod.BLOCK_HISTORY_WINDOW());
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL));
    }

    function _delayedChallenge(bool removal, bool flip) internal {
        uint256 id;
        if (removal) {
            uint256 listing = _finalListing();
            vm.prank(PUBLISHER);
            id = mod.submitRemoval(listing, FEE);
        } else { id = _submit(); }
        _arm(id, 0, 1);
        _drawAs(id, 1);
        bytes memory reviewedCall = abi.encodeWithSignature("challenge(uint256,uint8,uint8)", id, uint8(0), uint8(1));
        assertEq(reviewedCall.length, 100, "round and outcome travel with the request");
        uint8 reviewedChoice = 2;
        Moderation.Case memory challengeIntent1 = mod.caseInfo(id);
        vm.prank(members[22]);
        mod.challenge(id, challengeIntent1.challenges, challengeIntent1.preliminary);
        _arm(id, 6, flip ? 2 : 1);
        _drawAs(id, flip ? 2 : 1);
        assertEq(stakes.openVotes(members[23]), 0);
        bytes32 beforeState = _state(id, members[23]);
        vm.prank(members[23]);
        _blocked(reviewedCall, Moderation.ChallengeIntentChanged.selector);
        assertEq(_state(id, members[23]), beforeState, "stale request has no effects");
        assertEq(stakes.openVotes(members[23]), 0);
        Moderation.Case memory fresh = mod.caseInfo(id);
        vm.prank(members[23]);
        mod.challenge(id, fresh.challenges, fresh.preliminary);
        Moderation.Vote memory v = mod.voteOf(id, members[23]);
        assertEq(v.round, 1);
        assertEq(v.revealed, flip ? 1 : reviewedChoice);
        assertEq(stakes.openVotes(members[23]), 1);
        assertEq(mod.caseInfo(id).challenges, 2);
    }

    function test_regressionDelayedListChallengePreservesReviewedIntent() public { _delayedChallenge(false, true); }
    function test_regressionDelayedRemovalChallengePreservesReviewedIntent() public { _delayedChallenge(true, true); }
    function test_regressionDelayedChallengeSameOutcomeRejectsOldRound() public { _delayedChallenge(false, false); }

    function test_regressionWrongChallengeArgumentsHaveNoEffects() public {
        uint256 id = _submit();
        _arm(id, 0, 1); _drawAs(id, 1);
        bytes32 beforeState = _state(id, members[23]);
        for (uint8 round; round < 3; ++round) {
            for (uint8 outcome; outcome < 4; ++outcome) {
                if (round == 0 && outcome == 1) continue;
                vm.prank(members[23]);
                _blocked(abi.encodeWithSignature("challenge(uint256,uint8,uint8)", id, round, outcome),
                    outcome == 0 || outcome == 3 ? Moderation.BadOutcome.selector : Moderation.ChallengeIntentChanged.selector);
                assertEq(_state(id, members[23]), beforeState);
            }
        }
        vm.prank(members[23]);
        (bool accepted,) = address(mod).call(abi.encodeWithSignature("challenge(uint256,uint8,uint8)", id, uint256(256), uint8(1)));
        assertFalse(accepted, "noncanonical uint8 is refused by the ABI decoder");
        assertEq(_state(id, members[23]), beforeState);
    }

    function test_regressionLegacySelectorCannotCastOrBypassWithTrailingWords() public {
        uint256 id = _submit();
        _arm(id, 0, 1); _drawAs(id, 1);
        assertEq(mod.challengeIntentVersion(), 1);
        bytes32 beforeState = _state(id, members[23]);
        bytes memory legacy = abi.encodeWithSignature("challenge(uint256)", id);
        vm.prank(members[23]);
        _blocked(legacy, Moderation.ChallengeIntentRequired.selector);
        vm.prank(members[23]);
        _blocked(bytes.concat(legacy, abi.encode(uint8(0), uint8(1))), Moderation.ChallengeIntentRequired.selector);
        assertEq(_state(id, members[23]), beforeState);
        vm.prank(members[23]);
        mod.challenge(id, 0, 1);
        assertEq(mod.voteOf(id, members[23]).revealed, 2);
        assertEq(stakes.openVotes(members[23]), 1);
    }
}
