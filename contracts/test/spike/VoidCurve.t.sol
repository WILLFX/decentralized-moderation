// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../../src/Moderation.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {StakeRegistryHarness} from "../harnesses/StakeRegistryHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {StackDeployer} from "../base/StackDeployer.sol";

/// TEMPORARY measurement (M2.6-P1-2). With the seat DRAW batched, the panel-size
/// cap is no longer bound by the draw. This measures what IS binding now: `_void`
/// still loops the whole `seatHolders` array with no cursor, and it runs INSIDE
/// `closeReveal`, so exceeding the block limit reverts the transition and strands
/// the case in an expired REVEAL. That is work-order P0-7.
///
/// Delete with the rest of test/spike/ at milestone close.
contract VoidCurveSpike is StackDeployer {
    uint256 internal constant XBZZ = 1e16;

    /// Cost of disposing `n` seat-holders in a VOID, measured through the harness
    /// on an injected round so the panel size is the only variable.
    function _voidCost(uint256 n) internal returns (uint256 used) {
        MockBZZ b = new MockBZZ();
        (ModerationHarness m, StakeRegistryHarness sr,) = _deployStack(b);

        uint256 pot = 100 * XBZZ;
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, pot);
        b.mint(address(m), pot);
        m.__injectRound(caseId);

        // n seat-holders that committed and never revealed — the VOID disposition
        // path: freeze the committed slice, settle duty, penalise the no-show.
        uint256 camt = 10 * XBZZ;
        for (uint256 i = 0; i < n; i++) {
            address v = address(uint160(uint256(keccak256(abi.encode("voidmod", i)))));
            m.__injectSeat(caseId, 0, v, 1, camt, 0); // revealCode 0 = committed, no reveal
        }
        b.mint(address(sr), n * camt);

        uint256 g = gasleft();
        m.claim(caseId); // drives the same per-holder disposal loop
        used = g - gasleft();
    }

    function _one(uint256 n) internal {
        uint256 used = _voidCost(n);
        emit log_named_uint(string(abi.encodePacked("holders_", vm.toString(n))), used);
        emit log_named_uint("  per_holder", used / n);
    }

    function test_void_24() public { _one(24); }
    function test_void_48() public { _one(48); }
    function test_void_96() public { _one(96); }
}
