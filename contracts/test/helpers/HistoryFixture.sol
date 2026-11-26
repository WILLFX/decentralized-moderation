// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../../src/Moderation.sol";

import {ModerationAuthority} from "../../src/ModerationAuthority.sol";
interface FixtureRegistry {
    function authority() external view returns (ModerationAuthority);
    function configure(ModerationAuthority a) external;
}

/// @dev EIP-2935 runtime with fixture hashes. This simulates chain history;
///      it does not verify network consensus or the five-second timing premise.
abstract contract HistoryFixture is Test {
    address internal constant HISTORY_ADDRESS = 0x0000F90827F1C53a10cb7A02335B175320002935;

    function _newModeration(Moderation.Config memory cfg) internal returns (Moderation m) {
        ModerationAuthority a = FixtureRegistry(cfg.stakes).authority();
        if (address(a) == address(0)) {
            a = new ModerationAuthority(address(this), 1, cfg.token, 1000);
            FixtureRegistry(cfg.stakes).configure(a);
            FixtureRegistry(cfg.index).configure(a);
            a.bindRegistries(cfg.stakes, cfg.index);
        }
        m = new Moderation(cfg, a);
        _activate(m);
    }

    function _activate(Moderation m) internal {
        ModerationAuthority a = m.authority();
        a.propose(address(m), address(m).codehash, m.rulesHash());
        (,,, uint256 ready) = a.proposal();
        vm.warp(ready);
        a.activate();
    }

    /// Select a known outcome for settlement scenarios, independent of deployment
    /// address. Draw mathematics remains covered by DrawTest and external vectors.
    function _fixtureOutcome(Moderation m, uint256 id, uint8 wanted) internal {
        for (uint256 n = 1; n < 1000; ++n) {
            bytes32 entropy = keccak256(abi.encode("settlement fixture", n));
            (uint8 outcome,) = m.decideAt(id, entropy);
            if (outcome == wanted) {
                vm.setBlockhash(m.caseInfo(id).outcomeSeedBlock, entropy);
                return;
            }
        }
        revert("no fixture entropy for requested outcome");
    }

    function _recordHistory(uint256 height, bytes32 value) internal {
        vm.etch(HISTORY_ADDRESS, hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500");
        vm.store(HISTORY_ADDRESS, bytes32(height % 8191), value);
    }

    function _readyB(Moderation target, uint256 id) internal returns (uint256 height) {
        height = block.number;
        if (target.caseInfo(id).phase != uint8(Moderation.Phase.COMMIT_B)) return height;
        uint256 seed = target.caseInfo(id).seedBlockB;
        if (height <= seed) height = seed + 1;
        vm.roll(height);
        bytes32 value = keccak256(abi.encode("fixture history", seed));
        _recordHistory(seed, value);
        if (height - seed <= 256) vm.setBlockhash(seed, value);
    }
}
