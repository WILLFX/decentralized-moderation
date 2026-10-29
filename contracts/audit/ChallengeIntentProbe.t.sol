// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ChallengeRoundTest} from "../test/ChallengeRound.t.sol";
import {Moderation} from "../src/Moderation.sol";

/// @notice Regression retained from the earlier delayed-challenge witness.
/// The legacy selector must now reject without changing a public choice.
/// Uses the existing floor-one lifecycle fixture; no live wallet or chain.
contract ChallengeIntentProbe is ChallengeRoundTest {
    function test_regressionLegacyDelayedChallengeCannotUseLaterOutcome() public {
        uint256 id = _submit();
        _round(id, 0, 0, 4, APPROVE);
        assertEq(mod.caseInfo(id).preliminary, APPROVE);

        // An unused sender reviews this request while the opposing vote is Reject.
        bytes memory reviewedCall = abi.encodeWithSignature("challenge(uint256)", id);

        assertEq(reviewedCall.length, 36, "only selector and case ID are encoded");
        Moderation.Case memory challengeIntent1 = mod.caseInfo(id);

        // Someone else advances the case before that reviewed request executes.
        vm.prank(mods[10]);
        mod.challenge(id, challengeIntent1.challenges, challengeIntent1.preliminary);
        _armOutcome(id, 1, 4, 9, REJECT);
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        _advance(SEED_LAG + 1);

        // Choose a known-answer entropy fixture, without replacing any case state.
        bytes32 entropy;
        bool found;
        for (uint256 i; i < 256; ++i) {
            entropy = keccak256(abi.encode("delayed challenge fixture", i));
            (uint8 outcome,) = mod.decideAt(id, entropy);
            if (outcome == REJECT) {
                found = true;
                break;
            }
        }
        assertTrue(found, "a Reject fixture must be found");
        vm.setBlockhash(target, entropy);
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, REJECT);
        assertEq(mod.caseInfo(id).challenges, 1);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.CHALLENGE));

        // Execute the original bytes from the original unused sender.
        bytes32 beforeState = keccak256(abi.encode(mod.caseInfo(id), mod.voteOf(id, mods[11])));
        vm.prank(mods[11]);
        (bool accepted, bytes memory result) = address(mod).call(reviewedCall);
        assertFalse(accepted);
        assertEq(bytes4(result), Moderation.ChallengeIntentRequired.selector);
        assertEq(keccak256(abi.encode(mod.caseInfo(id), mod.voteOf(id, mods[11]))), beforeState);
        assertEq(stakes.openVotes(mods[11]), 0);
    }
}
