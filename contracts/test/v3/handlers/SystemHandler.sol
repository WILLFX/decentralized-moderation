// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../../src/v3/IndexRegistry.sol";
import {MockBZZ} from "../../mocks/MockBZZ.sol";

/// @notice Drives the three REAL v3 contracts under the invariant runner.
/// @dev Every unit suite in `test/v3` is a story someone wrote: a fixed sequence
///      chosen because someone suspected it. This drives sequences nobody chose.
///      The handler's only job is to keep calls in-domain enough to be interesting
///      — `fail_on_revert = false`, so an out-of-domain call is a wasted step and
///      not a failure — and to maintain the ghost state the invariants need.
///
///      The ghost state exists for one reason: I23 (`liabilities == Σ claims`) is
///      an identity over an enumeration the registry deliberately does not keep, so
///      something outside the registry has to hold the list. That is exactly what
///      `liabilitiesMatch` was built to be fed.
contract SystemHandler is Test {
    MockBZZ public immutable token;
    StakeRegistry public immutable reg;
    IndexRegistry public immutable idx;
    Moderation public immutable mod;

    uint256 internal constant UNIT = 1e16;
    uint256 public constant MIN_STAKE = 10 * UNIT;
    uint256 public constant BOND_MIN = 5 * UNIT;
    uint256 public constant MATURATION = 3 days;
    uint256 public constant EXIT_COOLDOWN = 7 days;
    uint128 public constant LAMBDA = 2 * uint128(UNIT);
    uint128 public constant CHALLENGE_BOND = 3 * uint128(UNIT);
    uint256 public constant FEE = 1000 * UNIT;
    uint32 public constant SEED_LAG = 2;

    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;
    uint8 internal constant KIND_VOTE = 1;
    uint8 internal constant KIND_CHALLENGE = 2;

    address[] public actors;
    uint256[] public caseIds;
    bytes32[] public topics;

    // --- ghost state ---------------------------------------------------------

    /// @dev The enumeration the registry does not keep. Kept as a list plus a
    ///      position map so removal is O(1) and the list never contains a stale
    ///      entry — a ghost that drifts turns every invariant into a coin flip.
    mapping(address => uint256[]) internal openCaseIds;
    mapping(address => uint8[]) internal openKinds;
    mapping(address => mapping(bytes32 => uint256)) internal openPosPlusOne;

    /// @dev Every unit of token that entered the system, per actor, so
    ///      conservation is checkable without trusting either contract's ledger.
    uint256 public ghostPaidIn;
    mapping(uint256 => bool) public ghostTerminated;

    /// @dev What each actor actually committed, so a reveal can match its own
    ///      commitment. Without this the runner reveals a random side, the hash
    ///      never matches, and the reveal phase is unreachable — the suite would
    ///      pass having exercised half the machine.
    mapping(bytes32 => uint8) internal committedVote;

    uint256 public callsStake;
    uint256 public callsCommit;
    uint256 public callsReveal;
    uint256 public callsPoke;
    uint256 public callsClaim;
    uint256 public callsChallenge;
    uint256 public callsWithdraw;

    constructor(MockBZZ _token, StakeRegistry _reg, IndexRegistry _idx, Moderation _mod, address[] memory _actors) {
        token = _token;
        reg = _reg;
        idx = _idx;
        mod = _mod;
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
        topics.push(keccak256("t1"));
        topics.push(keccak256("t2"));
    }

    // --- helpers -------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function caseCount() external view returns (uint256) {
        return caseIds.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _case(uint256 seed) internal view returns (uint256) {
        if (caseIds.length == 0) return 0;
        return caseIds[seed % caseIds.length];
    }

    function _salt(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", a));
    }

    function _k(uint256 caseId, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(caseId, kind));
    }

    function _addClaim(address a, uint256 caseId, uint8 kind) internal {
        bytes32 k = _k(caseId, kind);
        if (openPosPlusOne[a][k] != 0) return;
        openCaseIds[a].push(caseId);
        openKinds[a].push(kind);
        openPosPlusOne[a][k] = openCaseIds[a].length;
    }

    function _dropClaim(address a, uint256 caseId, uint8 kind) internal {
        bytes32 k = _k(caseId, kind);
        uint256 p = openPosPlusOne[a][k];
        if (p == 0) return;
        uint256 i = p - 1;
        uint256 last = openCaseIds[a].length - 1;
        if (i != last) {
            uint256 movedCase = openCaseIds[a][last];
            uint8 movedKind = openKinds[a][last];
            openCaseIds[a][i] = movedCase;
            openKinds[a][i] = movedKind;
            openPosPlusOne[a][_k(movedCase, movedKind)] = i + 1;
        }
        openCaseIds[a].pop();
        openKinds[a].pop();
        delete openPosPlusOne[a][k];
    }

    /// @notice The enumeration `liabilitiesMatch` needs (I23).
    function openClaimsOf(address a) external view returns (uint256[] memory, uint8[] memory) {
        return (openCaseIds[a], openKinds[a]);
    }

    function topicsOf() external view returns (bytes32[] memory) {
        return topics;
    }

    /// @notice Stake and mature the actor set. Called once from `setUp`, NOT a fuzz
    ///         target.
    /// @dev `MATURATION` is three days of wall-clock while a commit window is 240
    ///      blocks. An actor who stakes after a case exists cannot mature inside
    ///      that case's window, so a runner left to discover the ordering spends
    ///      every step on it and never reaches the machine under test. Seeding the
    ///      cohort is the difference between a suite that explores the state space
    ///      and one that passes vacuously.
    function init() external {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            uint256 bond = BOND_MIN + 60 * UNIT;
            uint256 total = MIN_STAKE + bond;
            token.mint(a, total);
            ghostPaidIn += total;
            vm.startPrank(a);
            token.approve(address(reg), type(uint256).max);
            reg.stake(bond);
            vm.stopPrank();
            callsStake++;
        }
        vm.warp(block.timestamp + MATURATION + 1);
    }

    // --- actions -------------------------------------------------------------

    function hStake(uint256 actorSeed, uint256 extraSeed) external {
        address a = _actor(actorSeed);
        if (reg.stateOf(a) != StakeRegistry.State.NONE) return;
        uint256 bond = BOND_MIN + (extraSeed % (60 * UNIT));
        uint256 total = MIN_STAKE + bond;
        token.mint(a, total);
        ghostPaidIn += total;
        vm.startPrank(a);
        token.approve(address(reg), type(uint256).max);
        reg.stake(bond);
        vm.stopPrank();
        callsStake++;
    }

    function hPostBond(uint256 actorSeed, uint256 amtSeed) external {
        address a = _actor(actorSeed);
        if (reg.stateOf(a) == StakeRegistry.State.NONE) return;
        uint256 amt = 1 + (amtSeed % (20 * UNIT));
        token.mint(a, amt);
        ghostPaidIn += amt;
        vm.prank(a);
        reg.postBond(amt);
    }

    function hSubmit(uint256 seed) external {
        if (caseIds.length > 12) return; // keep the state space walkable
        address s = _actor(seed);
        token.mint(s, FEE);
        ghostPaidIn += FEE;
        vm.startPrank(s);
        token.approve(address(mod), type(uint256).max);
        try mod.submit(keccak256(abi.encode("c", seed, caseIds.length)), keccak256("m"), topics, FEE) returns (
            uint256 id
        ) {
            caseIds.push(id);
        } catch {}
        vm.stopPrank();
    }

    function hCommit(uint256 actorSeed, uint256 caseSeed, uint256 voteSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        Moderation.Case memory c = mod.caseInfo(id);
        if (c.phase != uint8(Moderation.Phase.COMMIT)) return;
        uint8 v = (voteSeed % 2 == 0) ? APPROVE : REJECT;
        bytes32 h = mod.commitHash(id, c.round, c.paramsVersion, a, v, _salt(a));
        vm.prank(a);
        try mod.commit(id, h) {
            _addClaim(a, id, KIND_VOTE);
            committedVote[keccak256(abi.encode(a, id, c.round))] = v;
            callsCommit++;
        } catch {}
    }

    function hReveal(uint256 actorSeed, uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        uint8 v = committedVote[keccak256(abi.encode(a, id, mod.caseInfo(id).round))];
        if (v == 0) return; // never committed in this round
        vm.prank(a);
        try mod.reveal(id, v, _salt(a)) {
            callsReveal++;
        } catch {}
    }

    function hChallenge(uint256 actorSeed, uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        vm.prank(a);
        try mod.challenge(id) {
            _addClaim(a, id, KIND_CHALLENGE);
            callsChallenge++;
        } catch {}
    }

    /// @dev Advances whichever §4.3 transition is enabled. I18 says at most one is,
    ///      so trying all four is not ambiguity — it is the invariant, exercised.
    function hPoke(uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        try mod.closeCommit(id) {
            callsPoke++;
        } catch {
            try mod.closeReveal(id) {
                callsPoke++;
            } catch {
                try mod.closeTally(id) {
                    callsPoke++;
                } catch {
                    try mod.draw(id) {
                        callsPoke++;
                    } catch {}
                }
            }
        }
        if (mod.caseInfo(id).terminal != uint8(Moderation.Terminal.NONE)) {
            ghostTerminated[id] = true;
        }
    }

    function hClaim(uint256 actorSeed, uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address a = _actor(actorSeed);
        try mod.claim(id, a) {
            _dropClaim(a, id, KIND_VOTE);
            callsClaim++;
        } catch {}
    }

    function hClaimChallenge(uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        address ch = mod.caseInfo(id).challenger;
        if (ch == address(0)) return;
        try mod.claimChallenge(id) {
            _dropClaim(ch, id, KIND_CHALLENGE);
        } catch {}
    }

    function hRequestExit(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try reg.requestExit() {} catch {}
    }

    function hWithdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try reg.withdraw() {
            callsWithdraw++;
        } catch {}
    }

    function hSweep() external {
        try mod.sweepMaintenance() {} catch {}
    }

    function hRefund(uint256 caseSeed) external {
        uint256 id = _case(caseSeed);
        if (id == 0) return;
        try mod.withdrawRefund(id) {} catch {}
    }

    /// @dev Time is an input to this system, not a background fact: every phase
    ///      guard is a block-height comparison and maturation is a timestamp one.
    function hRoll(uint256 seed) external {
        uint256 blocks = 1 + (seed % 80);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 5);
    }

    /// @dev A big jump, so the `blockhash` horizon and `NO_RANDOMNESS` are
    ///      reachable rather than theoretical.
    function hRollFar(uint256 seed) external {
        uint256 blocks = 300 + (seed % 9000);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 5);
    }
}
