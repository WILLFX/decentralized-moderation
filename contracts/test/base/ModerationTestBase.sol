// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../../src/Moderation.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @notice Shared setup and lifecycle-driving helpers for the Moderation tests.
///         Stands up a funded, activated moderator set and drives cases through
///         the phase machine by reading the actual (randomly drawn) seat-holders
///         from the contract.
abstract contract ModerationTestBase is Test {
    ModerationHarness internal mod;
    MockBZZ internal bzz;

    uint256 internal constant XBZZ = 1e16;
    uint256 internal constant MIN_STAKE = 10 * XBZZ;
    uint256 internal constant ACTIVATION_DELAY = 7 days;
    uint256 internal constant COMMIT_TIMEOUT = 24 hours;
    uint256 internal constant REVEAL_WINDOW = 24 hours;
    uint256 internal constant MAX_WIDEN = 3;
    uint256 internal constant SEED_LAG = 2;

    bytes32 internal constant SALT = keccak256("salt");
    bytes32 internal constant CONTENT = keccak256("content");
    bytes32 internal constant META = keccak256("meta");

    address[] internal mods;

    function setUp() public virtual {
        bzz = new MockBZZ();
        mod = new ModerationHarness(IERC20(address(bzz)));
        // Generous stake: a deep appeal chain locks stake in several concurrent
        // rounds at once (committed isn't released until claim, M2-5).
        _spawnModerators(8, 3000 * XBZZ);
    }

    function _spawnModerators(uint256 n, uint256 stakeEach) internal {
        uint256 start = mods.length;
        for (uint256 i = start; i < start + n; i++) {
            address m = makeAddr(string(abi.encodePacked("mod", i)));
            mods.push(m);
            bzz.mint(m, 100_000 * XBZZ);
            vm.prank(m);
            bzz.approve(address(mod), type(uint256).max);
            vm.prank(m);
            mod.stake(stakeEach);
        }
        vm.warp(block.timestamp + ACTIVATION_DELAY);
        for (uint256 i = 0; i < mods.length; i++) {
            (, uint256 pending,,,,,,,) = mod.moderatorInfo(mods[i]);
            if (pending > 0) mod.activate(mods[i]);
        }
        vm.roll(block.number + 1);
    }

    function _topics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = keccak256("marine biology");
    }

    function _submit(address who) internal returns (uint256 caseId) {
        // Compute minFee before arming the prank: an external call in the arg
        // list would consume the prank and run submit as the test contract.
        uint256 fee = mod.minFee(1);
        bzz.mint(who, fee);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(who);
        caseId = mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);
    }

    function _phase(uint256 caseId) internal view returns (Moderation.Phase p) {
        (, , p, , , , ) = mod.caseInfo(caseId);
    }

    function _depth(uint256 caseId) internal view returns (uint256 d) {
        (, , , d, , , ) = mod.caseInfo(caseId);
    }

    function _realizeSeats(uint256 caseId) internal {
        vm.roll(block.number + SEED_LAG + 1);
        mod.realizeSeats(caseId);
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            vm.roll(block.number + SEED_LAG + 1);
            mod.realizeSeats(caseId);
        }
    }

    function _commitAll(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, depth);
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, depth, i);
            bytes32 commitHash = mod.computeCommit(caseId, depth, sh, vote, SALT); // M-01: bound per voter
            vm.prank(sh);
            mod.commitVote(caseId, commitHash);
        }
    }

    function _revealAll(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, depth);
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, depth, i);
            vm.prank(sh);
            mod.revealVote(caseId, vote, SALT);
        }
    }

    function _realizeOutcome(uint256 caseId) internal {
        vm.roll(block.number + SEED_LAG + 1);
        mod.realizeOutcome(caseId);
        while (_phase(caseId) == Moderation.Phase.TALLY) {
            vm.roll(block.number + SEED_LAG + 1);
            mod.realizeOutcome(caseId);
        }
    }

    /// Drive one round (at `depth`) from COMMIT-open all the way to APPEAL_WINDOW
    /// with every seat-holder voting `vote`.
    function _runRoundToAppealWindow(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        _commitAll(caseId, depth, vote);
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(block.timestamp + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        _revealAll(caseId, depth, vote);
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(block.timestamp + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
        _realizeOutcome(caseId);
    }

    function _fund(address who, uint256 amount) internal {
        bzz.mint(who, amount);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
    }

    /// Fund `who` and contribute the full current appeal floor, advancing one depth.
    function _appeal(uint256 caseId, address who) internal {
        uint256 floor = mod.appealFloor(caseId);
        _fund(who, floor);
        vm.prank(who);
        mod.contributeAppealBond(caseId, floor);
    }

    /// Close the appeal window with no appeal and finalize.
    function _finalize(uint256 caseId) internal {
        (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
        vm.warp(deadline);
        mod.finalize(caseId);
    }

    /// Submit an undisputed case, run round 0 with `vote`, and finalize it.
    function _runUndisputed(address submitter, Moderation.Vote vote) internal returns (uint256 caseId) {
        caseId = _submit(submitter);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, vote);
        _finalize(caseId);
    }

    function _assertConservation() internal view {
        uint256 buckets = mod.totalFreeStake() + mod.totalCommittedStake() + mod.totalFrozenStake();
        assertEq(
            bzz.balanceOf(address(mod)),
            buckets + mod.openPotsTotal() + mod.totalPendingBond() + mod.totalPendingPayout(),
            "conservation: balance == staked buckets + live pots + pending bond + pending payout"
        );
    }
}
