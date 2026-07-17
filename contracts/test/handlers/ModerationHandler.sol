// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Moderation} from "../../src/Moderation.sol";
import {ModerationHarness} from "../harnesses/ModerationHarness.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @notice Invariant-campaign driver. The fuzzer calls these bounded actions in
///         random order; each is robust to being called in any state (it guards
///         its preconditions and returns instead of reverting on a bad call).
///         Full cases are driven to settlement within a single action so the
///         invariant checker samples rich cross-case states (live pots, frozen
///         stake, accumulated track) between calls.
contract ModerationHandler is CommonBase, StdCheats, StdUtils {
    ModerationHarness public immutable mod;
    MockBZZ public immutable bzz;
    address[] public actors;

    uint256 internal constant XBZZ = 1e16;
    uint256 internal constant SEED_LAG = 2;

    // Ghost: net principal each actor deposited (stake) minus withdrawn. The
    // no-internal-transfer invariant (§9.2) is that an actor's stake never drops
    // below this — principal only leaves via the actor's own withdraw.
    mapping(address => uint256) public netDeposited;
    uint256 public casesSettled;

    constructor(ModerationHarness _mod, MockBZZ _bzz, address[] memory _actors) {
        mod = _mod;
        bzz = _bzz;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- staking actions -----------------------------------------------------

    function hStake(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, XBZZ, 2000 * XBZZ);
        if (mod.totalStakeOf(a) == 0 && amount < 10 * XBZZ) amount = 10 * XBZZ;
        bzz.mint(a, amount);
        vm.prank(a);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(a);
        try mod.stake(amount) {
            netDeposited[a] += amount;
        } catch {}
    }

    function hActivate(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        (, uint256 pending,,,, uint256 activatesAt,,,) = mod.moderatorInfo(a);
        if (pending == 0 || block.timestamp < activatesAt) return;
        try mod.activate(a) {} catch {}
    }

    function hRequestExitPranked(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        (uint256 free,,,,,, uint256 exitAmount,,) = mod.moderatorInfo(a);
        if (exitAmount != 0 || free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(a);
        try mod.requestExit(amount) {} catch {}
    }

    function hWithdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        (,,,,,, uint256 exitAmount, uint256 exitReqAt,) = mod.moderatorInfo(a);
        if (exitAmount == 0) return;
        vm.warp(block.timestamp + 8 days); // ensure cooldown elapsed
        vm.prank(a);
        try mod.withdraw() {
            netDeposited[a] -= exitAmount;
        } catch {}
    }

    function hThaw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        (,,, uint256 frozen, uint256 frozenUntil,,,,) = mod.moderatorInfo(a);
        if (frozen == 0) return;
        if (block.timestamp < frozenUntil) vm.warp(frozenUntil + 1);
        try mod.thaw(a) {} catch {}
    }

    // --- run a full case to settlement ---------------------------------------

    function hRunCase(uint256 submitterSeed, uint256 voteSeed, bool doAppeal) external {
        if (mod.totalEligibleWeight() == 0) return;
        address submitter = _actor(submitterSeed);

        uint256 fee = mod.minFee(1);
        bzz.mint(submitter, fee);
        vm.prank(submitter);
        bzz.approve(address(mod), type(uint256).max);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256(abi.encode("t", voteSeed % 32)); // vary topic to avoid dedup collisions
        vm.prank(submitter);
        uint256 caseId;
        try mod.submit(Moderation.Kind.SUBMISSION, keccak256(abi.encode(voteSeed)), bytes32(0), topics, 0, fee) returns (
            uint256 id
        ) {
            caseId = id;
        } catch {
            return;
        }

        if (!_runRound(caseId, 0, voteSeed)) return;

        if (doAppeal && _phase(caseId) == Moderation.Phase.APPEAL_WINDOW && _depth(caseId) == 0) {
            uint256 floor = mod.appealFloor(caseId);
            address challenger = _actor(voteSeed + 1);
            bzz.mint(challenger, floor);
            vm.prank(challenger);
            bzz.approve(address(mod), type(uint256).max);
            vm.prank(challenger);
            try mod.contributeAppealBond(caseId, floor) {} catch {
                return;
            }
            if (_phase(caseId) == Moderation.Phase.DRAW) {
                if (!_runRound(caseId, 1, voteSeed >> 1)) return;
            }
        }

        // finalize (if still in an appeal window) and claim.
        if (_phase(caseId) == Moderation.Phase.APPEAL_WINDOW) {
            (,,,,, uint256 deadline,) = mod.caseInfo(caseId);
            vm.warp(deadline);
            try mod.finalize(caseId) {} catch {
                return;
            }
        }
        if (_phase(caseId) == Moderation.Phase.FINALIZED) {
            try mod.claim(caseId) {
                casesSettled++;
            } catch {}
        }
    }

    /// Drive one round from DRAW through to APPEAL_WINDOW (or terminal). Voters
    /// split by parity of the seed so cases produce coherent AND incoherent
    /// voters (exercising freeze paths). Returns false if the round couldn't be
    /// advanced (and the caller should stop).
    function _runRound(uint256 caseId, uint256 depth, uint256 voteSeed) internal returns (bool) {
        vm.roll(block.number + SEED_LAG + 1);
        try mod.realizeSeats(caseId) {} catch {
            return false;
        }
        // re-poke if the seed re-armed
        uint256 guard;
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            if (guard++ > 4) return false;
            vm.roll(block.number + SEED_LAG + 1);
            try mod.realizeSeats(caseId) {} catch {
                return false;
            }
        }
        if (_phase(caseId) != Moderation.Phase.COMMIT) return false;

        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, depth);
        // commit
        for (uint256 i; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, depth, i);
            Moderation.Vote v = ((voteSeed + i) % 2 == 0) ? Moderation.Vote.Approve : Moderation.Vote.Reject;
            bytes32 h = mod.computeCommit(caseId, depth, sh, v, bytes32(uint256(0xabc))); // M-01
            vm.prank(sh);
            try mod.commitVote(caseId, h) {} catch {}
        }
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(block.timestamp + 25 hours);
            try mod.closeCommit(caseId) {} catch {
                return false;
            }
        }
        // reveal
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            for (uint256 i; i < shCount; i++) {
                address sh = mod.seatHolderAt(caseId, depth, i);
                Moderation.Vote v = ((voteSeed + i) % 2 == 0) ? Moderation.Vote.Approve : Moderation.Vote.Reject;
                vm.prank(sh);
                try mod.revealVote(caseId, v, bytes32(uint256(0xabc))) {} catch {}
            }
        }
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(block.timestamp + 25 hours);
            try mod.closeReveal(caseId) {} catch {
                return false;
            }
        }
        // realize outcome if tallied
        guard = 0;
        while (_phase(caseId) == Moderation.Phase.TALLY) {
            if (guard++ > 4) return false;
            vm.roll(block.number + SEED_LAG + 1);
            try mod.realizeOutcome(caseId) {} catch {
                return false;
            }
        }
        // widen may have sent us back to COMMIT; treat as advanced=false to stop.
        return _phase(caseId) == Moderation.Phase.APPEAL_WINDOW || _phase(caseId) == Moderation.Phase.FINALIZED
            || _phase(caseId) == Moderation.Phase.VOID;
    }

    function _phase(uint256 caseId) internal view returns (Moderation.Phase p) {
        (,, p,,,,) = mod.caseInfo(caseId);
    }

    function _depth(uint256 caseId) internal view returns (uint256 d) {
        (,,, d,,,) = mod.caseInfo(caseId);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// Setup-only: record principal staked outside the fuzzed actions so the
    /// no-internal-transfer ghost starts consistent. Not a fuzz target.
    function setNetDeposited(address a, uint256 amount) external {
        netDeposited[a] = amount;
    }
}
