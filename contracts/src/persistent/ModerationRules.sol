// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../Moderation.sol";

library ModerationRules {
    function hash(Moderation.Config memory cfg) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                cfg.token,
                cfg.commitWindow,
                cfg.revealWindow,
                cfg.challengeWindow,
                cfg.maxWaitForThird,
                cfg.freezePerLoss,
                cfg.seedLag,
                cfg.feeMin,
                cfg.minRevealsPerCommittee,
                cfg.guidelinesVersion,
                cfg.guidelinesHash
            )
        );
    }
}
