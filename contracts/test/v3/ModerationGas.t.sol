// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

contract GasIndex is IIndexRegistry {
    uint256 public n;

    function writeEntry(bytes32, bytes32, uint8, uint8) external {
        n++;
    }
}

/// @notice Measured gas for every path a case takes, for `GAS_BUDGETS.md`.
/// @dev Figures are measured with `gasleft()` around the call, so they exclude the
///      21,000-gas transaction base and calldata cost. The index is a counting
///      stub: a real `IndexRegistry` write is a cold SSTORE per topic on top.
contract ModerationGasTest is Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    GasIndex internal idx;
    Moderation internal mod;

    address internal gov;
    address internal submitter;

    uint256 internal constant UNIT = 1e16;
    uint256 internal constant MIN_STAKE = 10 * UNIT;
    uint256 internal constant BOND_MIN = 5 * UNIT;
    uint256 internal constant MATURATION = 3 days;
    uint256 internal constant TIMELOCK = 2 days;
    uint32 internal constant SEED_LAG = 2;
    uint256 internal constant FEE = 1000 * UNIT;
    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;

    bytes32[] internal topics;

    function setUp() public {
        gov = makeAddr("gov");
        submitter = makeAddr("submitter");
        token = new MockBZZ();
        vm.prank(gov);
        reg = new StakeRegistry(IERC20(address(token)), MIN_STAKE, BOND_MIN, MATURATION, 7 days, TIMELOCK, 0.5e18);
        idx = new GasIndex();
        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), gov);

        uint8 bits = reg.MAY_CREATE() | reg.MAY_DISCHARGE();
        vm.prank(gov);
        reg.proposeCaps(address(mod), bits);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        reg.executeCaps();

        Moderation.Params memory p;
        p.blockTime = 5;
        p.commitWindow = 1200;
        p.revealWindow = 1200;
        p.challengeWindow = 43_200;
        p.lateWidenAt = 720;
        p.seedLag = SEED_LAG;
        p.blockhashHorizon = 256;
        p.retryCooldown = 1 days;
        p.lateWidenFactorBps = 15_000;
        p.drawBountyBps = 50;
        p.claimBountyBps = 100;
        p.reserveBps = 2000;
        p.maintenanceBps = 1000;
        p.lambda = 2 * uint128(UNIT);
        p.revealBond = 2 * uint128(UNIT);
        p.penaltyDebit = uint128(UNIT);
        p.challengeBond = 3 * uint128(UNIT);
        p.trackDecay = 0.95e18;
        p.feeBase = uint128(100 * UNIT);
        p.feePerTopic = uint128(10 * UNIT);
        p.threshold = type(uint256).max;
        vm.prank(gov);
        mod.applyParams(p);

        topics.push(keccak256("t1"));
        topics.push(keccak256("t2"));
        topics.push(keccak256("t3"));
        topics.push(keccak256("t4"));
        topics.push(keccak256("t5")); // MAX_TOPICS: the worst case for the index write

        token.mint(submitter, 10_000_000 * UNIT);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);
        vm.roll(1000);
    }

    function _mod(uint256 i) internal returns (address a) {
        a = makeAddr(string(abi.encodePacked("m", vm.toString(i))));
        if (reg.stateOf(a) != StakeRegistry.State.NONE) return a;
        token.mint(a, MIN_STAKE + BOND_MIN + 200 * UNIT);
        vm.startPrank(a);
        token.approve(address(reg), type(uint256).max);
        reg.stake(BOND_MIN + 200 * UNIT);
        vm.stopPrank();
    }

    function _salt(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode("s", a));
    }

    /// @dev A full 34-voter case — the cohort size §4.5's figures are quoted at —
    ///      through both the unchallenged and challenged paths.
    function test_gas_report() public {
        uint256 N = 34;
        address[] memory who = new address[](N);
        for (uint256 i; i < N; ++i) {
            who[i] = _mod(i);
        }
        vm.warp(block.timestamp + MATURATION + 1);

        uint256 g = gasleft();
        vm.prank(submitter);
        uint256 id = mod.submit(keccak256("c"), keccak256("m"), topics, FEE);
        console.log("submit (5 topics)            ", g - gasleft());

        vm.roll(block.number + SEED_LAG + 1);

        Moderation.Case memory ci = mod.caseInfo(id);
        for (uint256 i; i < N; ++i) {
            bytes32 h = mod.commitHash(id, ci.round, ci.paramsVersion, who[i], i < 20 ? APPROVE : REJECT, _salt(who[i]));
            if (i == 1) g = gasleft();
            vm.prank(who[i]);
            mod.commit(id, h);
            if (i == 1) console.log("commit (warm)                ", g - gasleft());
        }

        vm.roll(mod.caseInfo(id).phaseDeadline);
        g = gasleft();
        mod.closeCommit(id);
        console.log("closeCommit -> REVEAL        ", g - gasleft());

        for (uint256 i; i < N; ++i) {
            if (i == 1) g = gasleft();
            vm.prank(who[i]);
            mod.reveal(id, i < 20 ? APPROVE : REJECT, _salt(who[i]));
            if (i == 1) console.log("reveal                       ", g - gasleft());
        }

        vm.roll(mod.caseInfo(id).phaseDeadline);
        g = gasleft();
        mod.closeReveal(id);
        console.log("closeReveal -> TALLY (+index)", g - gasleft());

        vm.roll(mod.caseInfo(id).phaseDeadline);
        g = gasleft();
        mod.closeTally(id);
        console.log("closeTally -> DRAW           ", g - gasleft());

        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + 1);
        g = gasleft();
        mod.draw(id);
        console.log("draw -> FINALIZED (+index)   ", g - gasleft());

        // Settlement, both branches.
        uint8 verdict = mod.caseInfo(id).verdict;
        uint256 coherent = type(uint256).max;
        uint256 incoherent = type(uint256).max;
        for (uint256 i; i < N; ++i) {
            uint8 v = i < 20 ? APPROVE : REJECT;
            if (v == verdict && coherent == type(uint256).max) coherent = i;
            if (v != verdict && incoherent == type(uint256).max) incoherent = i;
        }
        g = gasleft();
        mod.claim(id, who[coherent]);
        console.log("claim (coherent: pay+track)  ", g - gasleft());
        g = gasleft();
        mod.claim(id, who[incoherent]);
        console.log("claim (incoherent: debit)    ", g - gasleft());

        g = gasleft();
        mod.withdrawRefund(id);
        console.log("withdrawRefund               ", g - gasleft());
    }

    /// @dev The three `UNRESOLVED` terminals, and the non-reveal settlement branch.
    function test_gas_report_unresolved() public {
        // Stake and mature every participant up front, so no scenario below
        // depends on a warp landing after another scenario has moved the clock.
        address m0 = _mod(100);
        address m1 = _mod(101);
        vm.warp(block.timestamp + MATURATION + 1);
        assertTrue(reg.isActive(m0) && reg.isActive(m1), "fixture: both are ACTIVE");

        vm.prank(submitter);
        uint256 a = mod.submit(keccak256("a"), keccak256("m"), topics, FEE);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        uint256 g = gasleft();
        mod.closeCommit(a);
        console.log("closeCommit -> NO_TURNOUT    ", g - gasleft());

        vm.prank(submitter);
        uint256 b = mod.submit(keccak256("b"), keccak256("m"), topics, FEE);
        vm.roll(block.number + SEED_LAG + 1);
        Moderation.Case memory ci = mod.caseInfo(b);
        bytes32 hb = mod.commitHash(b, ci.round, ci.paramsVersion, m0, APPROVE, _salt(m0));
        vm.prank(m0);
        mod.commit(b, hb);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeCommit(b);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        g = gasleft();
        mod.closeReveal(b);
        console.log("closeReveal -> NO_REVEALS    ", g - gasleft());
        g = gasleft();
        mod.claim(b, m0);
        console.log("claim (non-revealer: debit)  ", g - gasleft());

        vm.prank(submitter);
        uint256 c = mod.submit(keccak256("c2"), keccak256("m"), topics, FEE);
        vm.roll(block.number + SEED_LAG + 1);
        ci = mod.caseInfo(c);
        bytes32 hc = mod.commitHash(c, ci.round, ci.paramsVersion, m1, APPROVE, _salt(m1));
        vm.prank(m1);
        mod.commit(c, hc);
        vm.roll(mod.caseInfo(c).phaseDeadline);
        mod.closeCommit(c);
        vm.prank(m1);
        mod.reveal(c, APPROVE, _salt(m1));
        vm.roll(mod.caseInfo(c).phaseDeadline);
        mod.closeReveal(c);
        vm.roll(mod.caseInfo(c).phaseDeadline);
        mod.closeTally(c);
        vm.roll(uint256(mod.caseInfo(c).outcomeSeedBlock) + 257);
        g = gasleft();
        mod.draw(c);
        console.log("draw -> NO_RANDOMNESS        ", g - gasleft());
        assertEq(mod.caseInfo(c).unresolvedReason, uint8(Moderation.Reason.NO_RANDOMNESS));
    }

    /// @dev The challenged path's extra calls.
    function test_gas_report_challenged() public {
        vm.prank(submitter);
        uint256 id = mod.submit(keccak256("ch"), keccak256("m"), topics, FEE);
        address[] memory who = new address[](4);
        for (uint256 i; i < 4; ++i) {
            who[i] = _mod(200 + i);
        }
        address ch = _mod(300);
        vm.warp(block.timestamp + MATURATION + 1);
        vm.roll(block.number + SEED_LAG + 1);
        Moderation.Case memory ci = mod.caseInfo(id);
        for (uint256 i; i < 4; ++i) {
            bytes32 hi = mod.commitHash(id, ci.round, ci.paramsVersion, who[i], APPROVE, _salt(who[i]));
            vm.prank(who[i]);
            mod.commit(id, hi);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            mod.reveal(id, APPROVE, _salt(who[i]));
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);

        uint256 g = gasleft();
        vm.prank(ch);
        mod.challenge(id);
        console.log("challenge (register only)    ", g - gasleft());

        vm.roll(mod.caseInfo(id).phaseDeadline);
        g = gasleft();
        mod.closeTally(id);
        console.log("closeTally -> COMMIT (r=1)   ", g - gasleft());

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + 1);
        mod.draw(id);

        g = gasleft();
        mod.claimChallenge(id);
        console.log("claimChallenge               ", g - gasleft());
    }
}
