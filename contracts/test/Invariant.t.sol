// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {ModerationHandler} from "./handlers/ModerationHandler.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {StackDeployer} from "./base/StackDeployer.sol";

/// Handler-driven invariant campaign. Random staking + full-case actions across
/// overlapping state; the §9 accounting invariants must hold after every call.
contract InvariantTest is StackDeployer {
    StakeRegistry internal stakeReg;
    IndexRegistry internal indexReg;
    ModerationHarness internal mod;
    MockBZZ internal bzz;
    ModerationHandler internal handler;
    address[] internal actors;

    uint256 internal constant XBZZ = 1e16;

    function setUp() public {
        bzz = new MockBZZ();
        (mod, stakeReg, indexReg) = _deployStack(bzz);

        for (uint256 i = 0; i < 6; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new ModerationHandler(mod, stakeReg, bzz, actors);

        // Pre-stake and activate everyone so cases can run from the start.
        uint256 seed = 500 * XBZZ;
        for (uint256 i = 0; i < actors.length; i++) {
            bzz.mint(actors[i], 100_000 * XBZZ);
            vm.prank(actors[i]);
            bzz.approve(address(stakeReg), type(uint256).max);
            vm.prank(actors[i]);
            stakeReg.stake(seed);
            handler.setNetDeposited(actors[i], seed);
        }
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < actors.length; i++) {
            stakeReg.activate(actors[i]);
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

    /// §9.1 + §9.11, now spanning two contracts (M2.5 port): the logic contract
    /// holds exactly the pot money it is accounting for, and the registry holds
    /// exactly the staked buckets. Neither contract can quietly absorb the
    /// other's tokens — a reward credited without its transfer, or a transfer
    /// without its credit, breaks one side of the pair.
    function invariant_conservation() public view {
        _assertStackConservation(mod, stakeReg, bzz);
    }

    /// §9.3: aggregate bucket totals equal the sum of per-actor buckets, and
    /// pending/exit are subsets of free.
    function invariant_partition() public view {
        uint256 sf;
        uint256 sc;
        uint256 sfz;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 free, uint256 pending, uint256 committed, uint256 frozen,,, uint256 exitAmount,,) =
                stakeReg.moderatorInfo(actors[i]);
            assertLe(pending, free, "pending <= free");
            assertLe(exitAmount, free, "exit <= free");
            sf += free;
            sc += committed;
            sfz += frozen;
        }
        // Challengers (non-actor appellants) never hold stake, so actor sums are
        // the whole staked supply.
        assertEq(stakeReg.totalFreeStake(), sf, "free total");
        assertEq(stakeReg.totalCommittedStake(), sc, "committed total");
        assertEq(stakeReg.totalFrozenStake(), sfz, "frozen total");
    }

    /// §9.2: no actor's stake principal is ever transferred away — their total
    /// stake never drops below their net deposits (rewards only add; losses
    /// freeze but never remove principal).
    function invariant_no_principal_lost() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertGe(
                stakeReg.totalStakeOf(actors[i]),
                handler.netDeposited(actors[i]),
                "principal never leaves except via own withdraw"
            );
        }
    }
}
