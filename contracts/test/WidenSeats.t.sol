// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// F2 regression: a widen re-draw can add seats to a voter that already revealed.
/// Settlement must pay (and mean-track) only the seats tallied at reveal, not the
/// inflated post-widen count — otherwise the re-drawn voter siphons reward from
/// its co-winners.
contract WidenSeatsTest is Test {
    uint256 internal constant XBZZ = 1e16;

    function test_widen_inflated_seats_do_not_change_settlement() public {
        MockBZZ bzz = new MockBZZ();
        ModerationHarness mod = new ModerationHarness(IERC20(address(bzz)));

        // Two equally-tallied coherent voters (2 seats each), final APPROVE.
        uint256 pot = 1000 * XBZZ + 12345; // odd -> dust
        uint256 caseId = mod.__injectFinalized(0, Moderation.Outcome.Approve, pot);
        bzz.mint(address(mod), pot);
        mod.__injectRound(caseId);

        address vv = makeAddr("V");
        address ww = makeAddr("W");
        uint256 camt = 20 * XBZZ;
        mod.__injectSeat(caseId, 0, vv, 2, camt, 1); // Approve, 2 tallied seats
        mod.__injectSeat(caseId, 0, ww, 2, camt, 1); // Approve, 2 tallied seats
        bzz.mint(address(mod), 2 * camt);

        // A widen re-drew 10 extra seats onto V *after* V revealed.
        mod.__injectWidenSeats(caseId, 0, vv, 10);

        mod.claim(caseId);

        (uint256 vFree,,,,,,,,) = mod.moderatorInfo(vv);
        (uint256 wFree,,,,,,,,) = mod.moderatorInfo(ww);
        // Equal tallied seats -> equal reward; the 10 phantom seats are inert.
        assertEq(vFree, wFree, "widen-inflated seats must not enlarge V's reward");
        // And each got their stake back plus a positive reward.
        assertGt(vFree, camt, "coherent voter paid");
    }
}
