// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationAuthority} from "../src/persistent/ModerationAuthority.sol";
import {PersistentStakeRegistry} from "../src/persistent/PersistentStakeRegistry.sol";
import {PersistentIndexRegistry} from "../src/persistent/PersistentIndexRegistry.sol";
import {PersistentModeration} from "../src/persistent/PersistentModeration.sol";

/// @notice Prepare a new registry family. Does not borrow the deployer's identity
/// as authorizer, bind registries on behalf of the multisig, or bypass its delay.
contract DeployPersistent is Script {
    struct Stack {
        ModerationAuthority authority;
        PersistentStakeRegistry stakes;
        PersistentIndexRegistry index;
        PersistentModeration moderation;
    }
    error InvalidParameters();

    function run(Moderation.Config memory cfg, uint256 stakeAmount, address authorizer, uint256 noticePeriod)
        external
        returns (Stack memory s)
    {
        if (
            cfg.stakes != address(0) || cfg.index != address(0) || cfg.seedLag >= 250
                || cfg.guidelinesHash != keccak256(bytes(vm.readFile("../MODERATION_GUIDELINES.md")))
        ) {
            revert InvalidParameters();
        }
        vm.startBroadcast();
        s.authority = new ModerationAuthority(authorizer, noticePeriod, cfg.token, stakeAmount);
        s.stakes = new PersistentStakeRegistry(s.authority);
        s.index = new PersistentIndexRegistry(s.authority);
        cfg.stakes = address(s.stakes);
        cfg.index = address(s.index);
        s.moderation = new PersistentModeration(cfg, s.authority);
        vm.stopBroadcast();
        // Deliberately inactive: authorizer must bind, propose the reviewed runtime
        // hash, and wait the full notice period. Activation is then permissionless.
    }
}
