// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FreezeMath} from "../src/lib/FreezeMath.sol";

/// Verifies the freezing-power curve (§6.4) against values computed independently
/// in Python from `1 + (CAP-1)(1 - e^(-meanTrack/SAT))`. The contract does WAD
/// integer math (solady expWad), so an exact float match is not expected — a
/// tight relative tolerance confirms the curve, not the last integer bit. Exact
/// integer agreement is checked end-to-end by the differential vectors (M2-8).
contract FreezeMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant CAP = 4 * 1e18;
    uint256 constant SAT = 60 * 1e18;
    uint256 constant BASE = 7 days;
    uint256 constant TOL = 1e10; // 1e-8 relative

    function _power(uint256 meanTrackCount) internal pure returns (uint256) {
        return FreezeMath.freezingPower(meanTrackCount * WAD, SAT, CAP);
    }

    function test_power_at_zero_is_one() public pure {
        assertEq(_power(0), WAD, "no track -> power 1");
    }

    function test_power_curve_matches_reference() public pure {
        // (meanTrack, expected power in WAD) — Python reference.
        assertApproxEqRel(_power(1), 1049585638535147392, TOL);
        assertApproxEqRel(_power(5), 1239866756112029952, TOL);
        assertApproxEqRel(_power(10), 1460554825328157440, TOL);
        assertApproxEqRel(_power(20), 1850406068278632192, TOL);
        assertApproxEqRel(_power(30), 2180408020862099456, TOL);
        assertApproxEqRel(_power(60), 2896361676485672960, TOL);
        assertApproxEqRel(_power(120), 3593994150290162176, TOL);
    }

    function test_power_bounded_by_cap() public pure {
        assertLt(_power(600), CAP, "power stays below cap");
        assertApproxEqRel(_power(600), 3999863800210712064, TOL);
    }

    function test_duration_matches_reference() public pure {
        assertApproxEqRel(FreezeMath.freezeDuration(10 * WAD, SAT, CAP, BASE), 883343, TOL);
        assertApproxEqRel(FreezeMath.freezeDuration(60 * WAD, SAT, CAP, BASE), 1751719, TOL);
    }

    function test_power_monotonic_in_track() public pure {
        uint256 prev = _power(0);
        for (uint256 t = 1; t <= 200; t += 7) {
            uint256 p = _power(t);
            assertGe(p, prev, "power non-decreasing in track");
            prev = p;
        }
    }
}
