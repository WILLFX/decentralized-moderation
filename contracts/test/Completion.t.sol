// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealModerationFixture} from "./helpers/RealModerationFixture.sol";
import {Moderation} from "../src/Moderation.sol";

/// @notice Completion, phase-event and bound-challenge safety regressions.
/// Real stake/index registries, reveal floor 3, 24 controlled staked identities.
/// Fixed-answer hash/history fixtures; no live-chain or independent-judgment claim.
/// Case/vote storage is never planted or overwritten. Time moves only in this VM.
contract CompletionTest is RealModerationFixture {

    function _blocked(bytes memory callData, bytes4 error) internal {
        (bool ok, bytes memory result) = address(mod).call(callData);
        assertFalse(ok, "an existing public exit unexpectedly succeeded");
        assertGe(result.length, 4);
        assertEq(bytes4(result), error);
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
