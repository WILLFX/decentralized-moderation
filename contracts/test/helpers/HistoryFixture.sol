// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Moderation} from "../../src/Moderation.sol";

/// @dev EIP-2935 runtime with fixture hashes. This simulates chain history;
///      it does not verify network consensus or the five-second timing premise.
abstract contract HistoryFixture is Test {
    address internal constant HISTORY_ADDRESS = 0x0000F90827F1C53a10cb7A02335B175320002935;

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
