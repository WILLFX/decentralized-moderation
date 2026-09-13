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
        uint256 minRevealsPerCommittee;
        uint32 guidelinesVersion;
        bytes32 guidelinesHash;
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
    function defaults(address token) public view returns (Params memory p) {
        p.token = token;
        p.stakeAmount = 10e16; // 10 xBZZ at 16 decimals
        p.commitWindow = 15 minutes;
        p.revealWindow = 30 minutes;
        p.challengeWindow = 1 hours;
        p.maxWaitForThird = 1 hours;
        p.freezePerLoss = 8 days; // §11 — undecided
        p.seedLag = 2;
        p.feeMin = 1e14;
        // §11's per-committee minimum, on REVEALS. `simulation/FINDINGS-floor-price.md`
        // prices it: k = 3 costs 0.9% of cases at 20% turnout and a 75% reveal
        // rate, and forces a clique that would decide a case alone to hold on the
        // order of 96 identities instead of 3. Below 10% turnout no k both stops a
        // small clique and leaves ordinary cases resolvable, so this value is
        // conditional on turnout the testnet has not measured yet.
        p.minRevealsPerCommittee = 3;

        // Read from the document rather than hardcoded. A constant here would be a
        // number with no source that goes stale the first time anyone edits a line,
        // and the whole point of pinning the hash is that the deployed value and the
        // text in the repository are the same thing.
        p.guidelinesVersion = 1;
        p.guidelinesHash = keccak256(bytes(vm.readFile(GUIDELINES)));
    }

    /// @dev Relative to `contracts/`, which is where forge runs.
    string internal constant GUIDELINES = "../MODERATION_GUIDELINES.md";

    function deploy(Params memory p) public returns (Stack memory s) {
        if (p.token == address(0)) revert BadParams("token");
        if (p.stakeAmount == 0) revert BadParams("stakeAmount");
        if (p.seedLag == 0) revert BadParams("seedLag");
        // a seed must still be addressable when the phase it gates is reached
        if (p.seedLag >= 250) revert BadParams("seedLag too large");
        // 0 is rejected by the constructor too; caught here so a bad deploy fails
        // before any contract is created rather than halfway through the stack
        if (p.minRevealsPerCommittee == 0) revert BadParams("minRevealsPerCommittee");
        // both are rejected by the constructor too; caught here so a bad deploy fails
        // before any contract is created rather than halfway through the stack
        if (p.guidelinesVersion == 0) revert BadParams("guidelinesVersion");
        if (p.guidelinesHash == bytes32(0)) revert BadParams("guidelinesHash");
        // **The pin must be the document in this repository.** The contract cannot
        // check this — it has no filesystem — so the script is the only place it can
        // be enforced, and it is enforced on the caller's value rather than on
        // `defaults`': a caller who overrides the hash with anything else is refused.
        // Without this the pin would be self-agreeing, since `defaults` reads the
        // same file a test would compare against.
        if (p.guidelinesHash != keccak256(bytes(vm.readFile(GUIDELINES)))) {
            revert BadParams("guidelinesHash does not match MODERATION_GUIDELINES.md");
        }

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
            p.feeMin,
            p.minRevealsPerCommittee,
            p.guidelinesVersion,
            p.guidelinesHash
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
