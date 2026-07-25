// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../../src/Moderation.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {StakeRegistryHarness} from "../harnesses/StakeRegistryHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {StackDeployer} from "../base/StackDeployer.sol";

/// TEMPORARY measurement: `realizeSeats` draw cost as a function of panel size,
/// to set MAX_PANEL from data instead of from 512 being a round number.
contract PanelCurveSpike is StackDeployer {
    uint256 internal constant XBZZ = 1e16;

    function _stand() internal returns (ModerationHarness m, StakeRegistryHarness sr) {
        MockBZZ b = new MockBZZ();
        (m, sr,) = _deployStack(b);
        // 1000 moderators, 8 units each: enough capacity for large panels.
        for (uint256 i = 0; i < 1000; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("bigmod", i)))));
            b.mint(a, 1000 * XBZZ);
            vm.prank(a);
            b.approve(address(sr), type(uint256).max);
            vm.prank(a);
            sr.stake(80 * XBZZ);
        }
        vm.warp(vm.getBlockTimestamp() + 7 days);
        for (uint256 i = 0; i < 1000; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("bigmod", i)))));
            sr.activate(a);
            vm.prank(a);
            sr.setDutyUnits(8);
        }
        _settleEpoch(sr);
    }

    function _cost(uint256 seats) internal returns (uint256 used) {
        (ModerationHarness m,) = _stand();
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectRound(caseId);
        uint256 g = gasleft();
        m.__drawPanel(caseId, 0, seats, keccak256(abi.encode("seed", seats)));
        used = g - gasleft();
    }

    function _one(uint256 seats) internal {
        uint256 used = _cost(seats);
        emit log_named_uint(string(abi.encodePacked("seats_", vm.toString(seats))), used);
        emit log_named_uint("  per_seat", used / seats);
    }

    function test_curve_47() public { _one(47); }
    function test_curve_56() public { _one(56); }
    function test_curve_64() public { _one(64); }
    function test_curve_80() public { _one(80); }
    function test_curve_96() public { _one(96); }
    function test_curve_128() public { _one(128); }
}
