// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";

/// @notice Deploys the three contracts and closes the links between them.
///
/// **`verify()` is the deliverable here, not `run()`.** The two registries each
/// hold a one-shot `moderation` address, and `Moderation` holds their addresses
/// as immutables — so a stack that is deployed but not linked compiles, deploys,
/// and accepts submissions. It fails at the *first commit*, long after anyone is
/// watching the deployment. Every link is therefore asserted before the script
/// returns.
contract Deploy is Script {
    struct Params {
        address token;
        uint256 stakeAmount;
        uint256 commitWindow;
        uint256 revealWindow;
        uint256 challengeWindow;
        uint256 maxWaitForThird;
        uint256 freezePerLoss;
        uint256 seedLag;
        uint256 feeMin;
    }

    struct Stack {
        Moderation moderation;
        StakeRegistry stakes;
        IndexRegistry index;
    }

    error NotLinked(string what);
    error BadParams(string what);

    /// @dev The working values of `specs/protocol.md` §4. Every one of them is
    ///      a placeholder for a number §11 has not decided.
    function defaults(address token) public pure returns (Params memory p) {
        p.token = token;
        p.stakeAmount = 10e16; // 10 xBZZ at 16 decimals
        p.commitWindow = 15 minutes;
        p.revealWindow = 30 minutes;
        p.challengeWindow = 1 hours;
        p.maxWaitForThird = 1 hours;
        p.freezePerLoss = 8 days; // §11 — undecided
        p.seedLag = 2;
        p.feeMin = 1e14;
    }

    function deploy(Params memory p) public returns (Stack memory s) {
        if (p.token == address(0)) revert BadParams("token");
        if (p.stakeAmount == 0) revert BadParams("stakeAmount");
        if (p.seedLag == 0) revert BadParams("seedLag");
        // a seed must still be addressable when the phase it gates is reached
        if (p.seedLag >= 250) revert BadParams("seedLag too large");

        s.stakes = new StakeRegistry(p.token, p.stakeAmount);
        s.index = new IndexRegistry();
        s.moderation = new Moderation(
            p.token,
            address(s.stakes),
            address(s.index),
            p.commitWindow,
            p.revealWindow,
            p.challengeWindow,
            p.maxWaitForThird,
            p.freezePerLoss,
            p.seedLag,
            p.feeMin
        );

        s.stakes.setModeration(address(s.moderation));
        s.index.setModeration(address(s.moderation));

        verify(s);
    }

    /// @dev Both directions of every link. A one-way check passes on a stack
    ///      where `Moderation` points at the right registries and the registries
    ///      accept writes from something else entirely.
    function verify(Stack memory s) public view {
        if (address(s.moderation.stakes()) != address(s.stakes)) revert NotLinked("moderation->stakes");
        if (address(s.moderation.index()) != address(s.index)) revert NotLinked("moderation->index");
        if (s.stakes.moderation() != address(s.moderation)) revert NotLinked("stakes->moderation");
        if (s.index.moderation() != address(s.moderation)) revert NotLinked("index->moderation");
        if (address(s.moderation.token()) != address(s.stakes.token())) revert NotLinked("token mismatch");
    }

    function run() external returns (Stack memory s) {
        address token = vm.envAddress("TOKEN");
        vm.startBroadcast();
        s = deploy(defaults(token));
        vm.stopBroadcast();
    }
}
