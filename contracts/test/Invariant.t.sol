// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {ModerationHandler} from "./handlers/ModerationHandler.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// Handler-driven invariant campaign. Random staking + full-case actions across
/// overlapping state; the §9 accounting invariants must hold after every call.
contract InvariantTest is Test {
    ModerationHarness internal mod;
    MockBZZ internal bzz;
    ModerationHandler internal handler;
    address[] internal actors;

    uint256 internal constant XBZZ = 1e16;

    function setUp() public {
        bzz = new MockBZZ();
        mod = new ModerationHarness(IERC20(address(bzz)));

        for (uint256 i = 0; i < 6; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new ModerationHandler(mod, bzz, actors);

        // Pre-stake and activate everyone so cases can run from the start.
        uint256 seed = 500 * XBZZ;
        for (uint256 i = 0; i < actors.length; i++) {
            bzz.mint(actors[i], 100_000 * XBZZ);
            vm.prank(actors[i]);
            bzz.approve(address(mod), type(uint256).max);
            vm.prank(actors[i]);
            mod.stake(seed);
            handler.setNetDeposited(actors[i], seed);
        }
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < actors.length; i++) {
            mod.activate(actors[i]);
        }

        // Fuzz only the handler's action functions.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ModerationHandler.hStake.selector;
        selectors[1] = ModerationHandler.hActivate.selector;
        selectors[2] = ModerationHandler.hRequestExitPranked.selector;
        selectors[3] = ModerationHandler.hWithdraw.selector;
        selectors[4] = ModerationHandler.hThaw.selector;
        selectors[5] = ModerationHandler.hRunCase.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// §9.1 + §9.11: the token balance equals every accounted bucket exactly.
    function invariant_conservation() public view {
        uint256 buckets = mod.totalFreeStake() + mod.totalCommittedStake() + mod.totalFrozenStake();
        assertEq(
            bzz.balanceOf(address(mod)),
            buckets + mod.openPotsTotal() + mod.totalPendingBond() + mod.totalPendingPayout(),
            "conservation"
        );
    }

    /// §9.3: aggregate bucket totals equal the sum of per-actor buckets, and
    /// pending/exit are subsets of free.
    function invariant_partition() public view {
        uint256 sf;
        uint256 sc;
        uint256 sfz;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 free, uint256 pending, uint256 committed, uint256 frozen,,, uint256 exitAmount,,) =
                mod.moderatorInfo(actors[i]);
            assertLe(pending, free, "pending <= free");
            assertLe(exitAmount, free, "exit <= free");
            sf += free;
            sc += committed;
            sfz += frozen;
        }
        // Challengers (non-actor appellants) never hold stake, so actor sums are
        // the whole staked supply.
        assertEq(mod.totalFreeStake(), sf, "free total");
        assertEq(mod.totalCommittedStake(), sc, "committed total");
        assertEq(mod.totalFrozenStake(), sfz, "frozen total");
    }

    /// §9.2: no actor's stake principal is ever transferred away — their total
    /// stake never drops below their net deposits (rewards only add; losses
    /// freeze but never remove principal).
    function invariant_no_principal_lost() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertGe(
                mod.totalStakeOf(actors[i]),
                handler.netDeposited(actors[i]),
                "principal never leaves except via own withdraw"
            );
        }
    }
}
