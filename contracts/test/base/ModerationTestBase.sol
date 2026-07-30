// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../../src/Moderation.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {StackDeployer} from "../base/StackDeployer.sol";

/// @notice Shared setup and lifecycle-driving helpers for the Moderation tests.
///         Stands up a funded, activated moderator set and drives cases through
///         the phase machine by reading the actual (randomly drawn) seat-holders
///         from the contract.
abstract contract ModerationTestBase is StackDeployer {
    StakeRegistry internal stakeReg;
    IndexRegistry internal indexReg;
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
        (mod, stakeReg, indexReg) = _deployStack(bzz);
        // Generous stake: a deep appeal chain locks stake in several concurrent
        // rounds at once (committed isn't released until claim, M2-5).
        _spawnModerators(8, 3000 * XBZZ);
    }

    /// Stake goes to the registry now (M2.5 port): moderators deposit, activate
    /// and pledge duty there directly, never through the logic contract.
    function _spawnModerators(uint256 n, uint256 stakeEach) internal {
        uint256 start = mods.length;
        for (uint256 i = start; i < start + n; i++) {
            address m = makeAddr(string(abi.encodePacked("mod", i)));
            mods.push(m);
            bzz.mint(m, 100_000 * XBZZ);
            vm.prank(m);
            bzz.approve(address(stakeReg), type(uint256).max);
            vm.prank(m);
            stakeReg.stake(stakeEach);
        }
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        // Compute BEFORE pranking: an external call in the arg list eats the prank.
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        uint256 units = stakeEach / riskPerSeat;
        for (uint256 i = 0; i < mods.length; i++) {
            (, uint256 pending,,,,,,,) = stakeReg.moderatorInfo(mods[i]);
            if (pending > 0) stakeReg.activate(mods[i]);
            // H-07: stake alone is not drawable — a moderator must PLEDGE duty
            // capacity. Pledge generously so panels fill as before.
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(units);
        }
        // M2.6-P0-3: newly staked/pledged weight becomes drawable at the NEXT
        // eligibility epoch, not immediately — that deferral is the whole point.
        // Cross the boundary and apply, so the fixture starts with a live pool.
        vm.roll(vm.getBlockNumber() + REG_EPOCH_BLOCKS);
        stakeReg.advanceEpoch(type(uint256).max);
    }

    function _topics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = keccak256("marine biology");
    }

    function _submit(address who) internal returns (uint256 caseId) {
        return _submitContent(who, CONTENT, META);
    }

    /// Submit specific content. Dedup is registry-owned and permanent since
    /// M2.6-P0-1b, so a test that wants a SECOND indexable case under the same
    /// topic must vary the content — reusing it is now correctly refused.
    function _submitContent(address who, bytes32 contentHash, bytes32 metaHash)
        internal
        returns (uint256 caseId)
    {
        // Compute minFee before arming the prank: an external call in the arg
        // list would consume the prank and run submit as the test contract.
        uint256 fee = mod.minFee(1);
        bzz.mint(who, fee);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(who);
        caseId = mod.submit(Moderation.Kind.SUBMISSION, contentHash, metaHash, _topics(), 0, fee);
    }

    /// Open a legacy removal (M2.6-P0-1c) against a permanent registry entry id.
    function _submitLegacyRemoval(address who, uint256 globalEntryId) internal returns (uint256 caseId) {
        uint256 fee = mod.minFee(1); // before the prank: an external call in the arg list eats it
        _fund(who, fee);
        vm.prank(who);
        caseId = mod.submitLegacyRemoval(globalEntryId, fee);
    }

    /// The supersafe subset for a topic. `Moderation.supersafeEntries(bytes32)`
    /// was removed in M2.6 (unbounded, and the contract is EIP-170-bound), so the
    /// tests read the registry's paginated view the way a front end now must.
    ///
    /// Reads the registry `m` ACTUALLY writes to, not the suite-level `indexReg`.
    /// Several tests deploy their own stack and pass that `m` in; against the base
    /// fixture's registry those entries do not exist, so every `length == 0`
    /// assertion held vacuously and could not have caught a supersafe regression.
    function _supersafe(ModerationHarness m, bytes32 topicKey)
        internal
        view
        returns (IndexRegistry.Entry[] memory)
    {
        IndexRegistry ir = m.indexReg();
        return ir.supersafeEntries(topicKey, m.getParams().supersafeAge, 0, ir.entryCount(topicKey));
    }

    /// The (logic, caseId) currently holding a content reservation, or (0,0).
    /// Replaces the removed, ambiguous `Moderation.dedupOwner`.
    function _dedupOwner(bytes32 key) internal view returns (address logic, uint256 caseId) {
        bool exists;
        (exists, logic, caseId) = indexReg.contentReservation(key);
        if (!exists) return (address(0), 0);
    }

    function _phase(uint256 caseId) internal view returns (Moderation.Phase p) {
        (, , p, , , , ) = mod.caseInfo(caseId);
    }

    function _depth(uint256 caseId) internal view returns (uint256 d) {
        (, , , d, , , ) = mod.caseInfo(caseId);
    }

    /// Drive DRAW -> COMMIT. M2.6-P0-3: staged eligibility changes are applied at
    /// the epoch boundary by a permissionless keeper call, so settle the epoch
    /// before poking — `drawPanel` refuses to sample an unsettled epoch.
    function _realizeSeats(uint256 caseId) internal {
        _rollToSeed(caseId);
        mod.realizeSeats(caseId);
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            _rollToSeed(caseId);
            mod.realizeSeats(caseId);
        }
    }

    /// Roll past this round's snapshot block and apply any staged eligibility
    /// changes. M2.6-P0-3: a seed whose window would straddle an epoch boundary is
    /// DEFERRED to the next epoch, so the snapshot block can be well beyond
    /// `seedLag` — rolling a fixed `SEED_LAG + 1` is no longer enough.
    function _rollToSeed(uint256 caseId) internal {
        // M2.6-item-2b: `roundInfo` is indexed by ROUND, and a depth now holds
        // several. Reading by depth would poll a stale round's snapshot block and
        // `realizeSeats` would revert `SeedNotReady` forever.
        (,,,,,,,, uint256 snapshotBlock,) = mod.roundInfo(caseId, mod.__roundCount(caseId) - 1);
        uint256 target = snapshotBlock + 1;
        if (vm.getBlockNumber() < target) vm.roll(target);
        else vm.roll(vm.getBlockNumber() + 1);
        stakeReg.advanceEpoch(type(uint256).max);
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

    /// M2.6-item-2b: COMMIT no longer always closes to REVEAL. Commitment below
    /// `minReveals` WIDENS instead — a round that cannot reach quorum should draw
    /// more seats, not open a reveal window it can never fill. Fixtures that
    /// exercise the reveal path with a handful of committers therefore need the rest
    /// of the panel to commit too. Commits every seat-holder that has not already.
    function _topUpCommitQuorum(uint256 caseId, Moderation.Vote vote) internal {
        uint256 ri = mod.__roundCount(caseId) - 1;
        (, uint256 n,,,,,,,,) = mod.roundInfo(caseId, ri);
        for (uint256 i = 0; i < n; i++) {
            address sh = mod.seatHolderAt(caseId, ri, i);
            if (mod.__committedSeats(caseId, ri, sh) > 0) continue;
            bytes32 h = mod.computeCommit(caseId, ri, sh, vote, SALT);
            vm.prank(sh);
            mod.commitVote(caseId, h);
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
        vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
        mod.realizeOutcome(caseId);
        while (_phase(caseId) == Moderation.Phase.TALLY) {
            vm.roll(vm.getBlockNumber() + SEED_LAG + 1);
            mod.realizeOutcome(caseId);
        }
    }

    /// Drive one round (at `depth`) from COMMIT-open all the way to APPEAL_WINDOW
    /// with every seat-holder voting `vote`.
    function _runRoundToAppealWindow(uint256 caseId, uint256 depth, Moderation.Vote vote) internal {
        _commitAll(caseId, depth, vote);
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        _revealAll(caseId, depth, vote);
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
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
        return _runUndisputedContent(submitter, CONTENT, META, vote);
    }

    /// As `_runUndisputed`, for specific content.
    function _runUndisputedContent(address submitter, bytes32 contentHash, bytes32 metaHash, Moderation.Vote vote)
        internal
        returns (uint256 caseId)
    {
        caseId = _submitContent(submitter, contentHash, metaHash);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, vote);
        _finalize(caseId);
    }

    /// M2.5 port: conservation now spans two contracts — the logic contract holds
    /// only pot money, the registry holds exactly the staked buckets.
    function _assertConservation() internal view {
        _assertStackConservation(mod, stakeReg, bzz);
    }
}
