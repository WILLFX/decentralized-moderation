// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ModerationAuthority} from "../src/ModerationAuthority.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {Moderation} from "../src/Moderation.sol";

/// @notice Prepare a new registry family. Does not borrow the deployer's identity
/// as authorizer, bind registries on behalf of the multisig, or bypass its delay.
contract Deploy is Script {
    struct Stack {
        ModerationAuthority authority;
        StakeRegistry stakes;
        IndexRegistry index;
        Moderation moderation;
    }
    error InvalidParameters();
    error BadParams(string what);
    error NotLinked(string what);

    function run(Moderation.Config memory cfg, uint256 stakeAmount, address authorizer, uint256 noticePeriod)
        public virtual
        returns (Stack memory s)
    {
        vm.startBroadcast();
        s = deploy(cfg, stakeAmount, authorizer, noticePeriod);
        vm.stopBroadcast();
    }

    function deploy(Moderation.Config memory cfg, uint256 stakeAmount, address authorizer, uint256 noticePeriod)
        public virtual returns (Stack memory s)
    {
        if (cfg.guidelinesVersion == 0) revert BadParams("guidelinesVersion");
        if (cfg.guidelinesHash == bytes32(0)) revert BadParams("guidelinesHash");
        if (cfg.guidelinesHash != keccak256(bytes(vm.readFile("../MODERATION_GUIDELINES.md"))))
            revert BadParams("guidelinesHash does not match MODERATION_GUIDELINES.md");
        if (
            cfg.stakes != address(0) || cfg.index != address(0) || cfg.seedLag == 0 || cfg.seedLag >= 250
                || cfg.minRevealsPerCommittee == 0
        ) {
            revert InvalidParameters();
        }
        s.authority = new ModerationAuthority(authorizer, noticePeriod, cfg.token, stakeAmount);
        s.stakes = new StakeRegistry(s.authority);
        s.index = new IndexRegistry(s.authority);
        cfg.stakes = address(s.stakes);
        cfg.index = address(s.index);
        s.moderation = new Moderation(cfg, s.authority);
        // Deliberately inactive: authorizer must bind, propose the reviewed runtime
        // hash, and wait the full notice period. Activation is then permissionless.
    }
    function defaults(address token) public view returns (Moderation.Config memory) {
        return Moderation.Config(token, address(0), address(0), 15 minutes, 30 minutes,
            1 hours, 1 hours, 8 days, 2, 1e14, 3, 1,
            keccak256(bytes(vm.readFile("../MODERATION_GUIDELINES.md"))));
    }

    /// Check after the authorizer has bound the registries; activation is separate.
    function verify(Stack memory s) public view {
        if (address(s.moderation.stakes()) != address(s.stakes)) revert NotLinked("moderation->stakes");
        if (address(s.moderation.index()) != address(s.index)) revert NotLinked("moderation->index");
        if (address(s.stakes.authority()) != address(s.authority)) revert NotLinked("stakes->authority");
        if (address(s.index.authority()) != address(s.authority)) revert NotLinked("index->authority");
        if (address(s.moderation.authority()) != address(s.authority)) revert NotLinked("moderation->authority");
        if (s.authority.stakes() != address(s.stakes)) revert NotLinked("authority->stakes");
        if (s.authority.index() != address(s.index)) revert NotLinked("authority->index");
        if (address(s.moderation.token()) != address(s.stakes.token())) revert NotLinked("token mismatch");
    }
}
