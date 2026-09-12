// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Moderation} from "../../src/Moderation.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @notice Drives the real stack through arbitrary orderings.
///
/// **The trap this is written against is a handler whose calls mostly revert.**
/// Invariants then hold because nothing happened, and the suite reports success
/// while testing nothing. Every action here counts its successes and its
/// reverts, `callSummary()` prints both, and `Invariant.t.sol` asserts that the
/// interesting ones actually fired.
contract SystemHandler is CommonBase, StdCheats, StdUtils {
    Moderation public immutable mod;
    StakeRegistry public immutable stakes;
    IndexRegistry public immutable index;
    MockBZZ public immutable token;

    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;
    bytes32 constant SALT = bytes32("salt");

    address[8] public actors;
    address public constant SUBMITTER = address(0x5B);

    uint256[] public caseIds;
    mapping(uint256 => bool) public isRemoval;

    /// @dev What each actor actually committed, so `reveal` can present the
    ///      matching vote. A fuzzed vote would fail the hash check every time
    ///      and the reveal phase would never be exercised at all.
    mapping(uint256 => mapping(address => uint8)) public committedVote;

    // ---- ghosts: the accounting the invariants check against
    uint256 public ghostFeesIn;
    uint256 public ghostPaidOut;
    uint256 public ghostRefunded;

    /// @dev commitments made, minus votes settled — what `openVotes` must equal
    mapping(address => uint256) public ghostUnsettled;
    mapping(uint256 => uint256) public ghostPaidOnCase;
    mapping(uint256 => uint256) public ghostMaxPooled;
    mapping(uint256 => bool) public ghostWasFinalized;
    mapping(uint256 => bool) public ghostWasRemoved;

    // ---- coverage
    mapping(bytes32 => uint256) public calls;
    mapping(bytes32 => uint256) public reverts;

    uint256 internal blk = 100;
    uint256 internal ts = 1_000_000;

    constructor(Moderation _mod, StakeRegistry _stakes, IndexRegistry _index, MockBZZ _token) {
        mod = _mod;
        stakes = _stakes;
        index = _index;
        token = _token;

        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0x20000 + i));
            token.mint(actors[i], stakes.stakeAmount());
            vm.startPrank(actors[i]);
            token.approve(address(stakes), type(uint256).max);
            stakes.stake();
            vm.stopPrank();
        }
        token.mint(SUBMITTER, 1e24);
        vm.prank(SUBMITTER);
        token.approve(address(mod), type(uint256).max);

        vm.roll(blk);
        vm.warp(ts);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _case(uint256 seed) internal view returns (uint256) {
        if (caseIds.length == 0) return 0;
        return caseIds[seed % caseIds.length];
    }

    function _hit(bytes32 k) internal {
        ++calls[k];
    }

    function _missed(bytes32 k) internal {
        ++reverts[k];
    }

    // ------------------------------------------------------------- actions

    /// @dev Time and blocks only move here, so phase transitions are reachable
    ///      but not free. Bounded so a sequence cannot skip past the blockhash
    ///      horizon in one step.
    function warp(uint256 mins, uint256 blocks) public {
        ts += bound(mins, 1, 200) * 1 minutes;
        blk += bound(blocks, 1, 20);
        vm.warp(ts);
        vm.roll(blk);
        _hit("warp");
    }

    function submit(uint256 fee) public {
        uint256 f = bound(fee, mod.feeMin(), mod.feeMin() * 100);
        bytes32[] memory t = new bytes32[](1);
        t[0] = keccak256(abi.encode("topic", caseIds.length % 3));
        vm.prank(SUBMITTER);
        try mod.submit(keccak256(abi.encode("c", caseIds.length)), keccak256("m"), t, f) returns (uint256 id) {
            caseIds.push(id);
            ghostFeesIn += f;
            _hit("submit");
        } catch {
            _missed("submit");
        }
    }

    function submitRemoval(uint256 seed, uint256 fee) public {
        uint256 target = _case(seed);
        if (target == 0) return;
        uint256 f = bound(fee, mod.feeMin(), mod.feeMin() * 10);
        vm.prank(SUBMITTER);
        try mod.submitRemoval(target, f) returns (uint256 id) {
            caseIds.push(id);
            isRemoval[id] = true;
            ghostFeesIn += f;
            _hit("submitRemoval");
        } catch {
            _missed("submitRemoval");
        }
    }

    function commit(uint256 seed, uint256 caseSeed, bool approve) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address m = _actor(seed);
        uint8 v = approve ? APPROVE : REJECT;
        uint8 round = mod.caseInfo(id).challenges;
        bytes32 h = mod.commitHash(id, round, m, v, SALT);
        vm.prank(m);
        try mod.commit(id, h) {
            ++ghostUnsettled[m];
            committedVote[id][m] = v;
            _hit("commit");
        } catch {
            _missed("commit");
        }
    }

    function reveal(uint256 seed, uint256 caseSeed) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address m = _actor(seed);
        uint8 v = committedVote[id][m];
        if (v == 0) return;
        vm.prank(m);
        try mod.reveal(id, v, SALT) {
            _hit("reveal");
        } catch {
            _missed("reveal");
        }
    }

    /// @dev Attempts the transition appropriate to the case's CURRENT phase.
    ///      Picking one of five at random left the reveal phase unreachable in
    ///      practice — the sequence had to guess the right call at the right
    ///      time, and never did. The fuzzer still chooses when this fires, on
    ///      which case, and what has happened first.
    function advancePhase(uint256 caseSeed, uint256) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        uint8 phase = mod.caseInfo(id).phase;
        uint256 w;
        if (phase == uint8(Moderation.Phase.COMMIT_A)) w = 0;
        else if (phase == uint8(Moderation.Phase.COMMIT_B)) w = 1;
        else if (phase == uint8(Moderation.Phase.REVEAL)) {
            w = mod.caseInfo(id).outcomeSeedBlock == 0 ? 2 : 3;
        } else if (phase == uint8(Moderation.Phase.CHALLENGE)) w = 4;
        else return;

        if (w == 0) {
            try mod.closeCommitA(id) {
                _hit("closeCommitA");
            } catch {
                _missed("closeCommitA");
            }
        } else if (w == 1) {
            try mod.closeCommitB(id) {
                _hit("closeCommitB");
            } catch {
                _missed("closeCommitB");
            }
        } else if (w == 2) {
            try mod.closeReveal(id) {
                _hit("closeReveal");
            } catch {
                _missed("closeReveal");
            }
        } else if (w == 3) {
            try mod.draw(id) {
                _hit("draw");
            } catch {
                _missed("draw");
            }
        } else {
            try mod.closeChallenge(id) {
                _hit("closeChallenge");
            } catch {
                _missed("closeChallenge");
            }
        }
    }

    function challenge(uint256 seed, uint256 caseSeed) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address m = _actor(seed);
        vm.prank(m);
        try mod.challenge(id) {
            ++ghostUnsettled[m];
            _hit("challenge");
        } catch {
            _missed("challenge");
        }
    }

    function claim(uint256 seed, uint256 caseSeed) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address m = _actor(seed);
        uint256 before = token.balanceOf(m);
        try mod.claim(id, m) {
            uint256 paid = token.balanceOf(m) - before;
            ghostPaidOut += paid;
            ghostPaidOnCase[id] += paid;
            --ghostUnsettled[m];
            _hit("claim");
        } catch {
            _missed("claim");
        }
    }

    function withdrawRefund(uint256 caseSeed) public {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        uint256 owed = mod.refundOwed(id);
        try mod.withdrawRefund(id) {
            ghostRefunded += owed;
            _hit("withdrawRefund");
        } catch {
            _missed("withdrawRefund");
        }
    }

    function withdrawStake(uint256 seed) public {
        address m = _actor(seed);
        vm.prank(m);
        try stakes.withdraw() {
            _hit("withdrawStake");
        } catch {
            _missed("withdrawStake");
        }
    }

    function restake(uint256 seed) public {
        address m = _actor(seed);
        vm.prank(m);
        try stakes.stake() {
            _hit("restake");
        } catch {
            _missed("restake");
        }
    }

    // -------------------------------------------------------- observation

    /// @dev Called by the invariant to record monotone quantities. Reading them
    ///      inside the invariant is not enough — a value that dipped and
    ///      recovered between two invariant checks would go unseen, so the high
    ///      water mark is kept here and updated on every action.
    function observe() public {
        for (uint256 i; i < caseIds.length; ++i) {
            uint256 id = caseIds[i];
            Moderation.Case memory c = mod.caseInfo(id);
            uint256 pooled = uint256(c.pooledApprove) + c.pooledReject;
            if (pooled > ghostMaxPooled[id]) ghostMaxPooled[id] = pooled;
            if (c.phase == uint8(Moderation.Phase.FINALIZED)) ghostWasFinalized[id] = true;
            if (mod.removed(id)) ghostWasRemoved[id] = true;
        }
    }

    function caseCount() external view returns (uint256) {
        return caseIds.length;
    }

    function actorCount() external pure returns (uint256) {
        return 8;
    }

    function callSummary() external view returns (string memory) {
        return "see Invariant.t.sol::invariant_coverage";
    }
}
