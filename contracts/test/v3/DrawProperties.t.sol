// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @title §4.5 — the draw, swept rather than sampled
/// @notice The unit suite checks the draw at the handful of tallies a case can be
///         driven to. This checks it at EVERY tally up to `N = 24`, against the
///         closed form the specification quotes, exhaustively where the property is
///         exact and statistically where it is a rate.
///
/// @dev Why a separate suite: driving a case to a chosen tally costs a full
///      lifecycle and a cohort, so a sweep over ~300 tallies is not reachable that
///      way. The tally is written directly into storage instead — the draw reads
///      only `pooledApprove`/`pooledReject` and the stored entropy, so a synthetic
///      tally exercises exactly the arithmetic under test and nothing else.
///
///      This is the check `simulation/v3/protocol_v3.py` would give if Python here
///      had keccak; it does not, so the comparison is against the CLOSED FORM
///      rather than against the simulation's sampler. See the report — a true
///      two-implementation differential is the remaining gap.
contract DrawPropertiesTest is Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    IndexRegistry internal idx;
    Moderation internal mod;

    address internal gov;
    uint256 internal constant UNIT = 1e16;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TIMELOCK = 2 days;
    uint8 internal constant APPROVE = 1;

    uint256 internal caseId;

    function setUp() public {
        gov = makeAddr("gov");
        token = new MockBZZ();
        vm.prank(gov);
        reg = new StakeRegistry(IERC20(address(token)), 10 * UNIT, 5 * UNIT, 3 days, 7 days, TIMELOCK, 0.5e18);
        vm.prank(gov);
        idx = new IndexRegistry(TIMELOCK);
        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), gov);

        Moderation.Params memory p;
        p.blockTime = 5;
        p.commitWindow = 1200;
        p.revealWindow = 1200;
        p.challengeWindow = 43_200;
        p.lateWidenAt = 720;
        p.seedLag = 2;
        p.blockhashHorizon = 256;
        p.retryCooldown = 1 days;
        p.superQuorum = 16;
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
        p.feeBase = 0;
        p.feePerTopic = 0;
        p.threshold = type(uint256).max;
        vm.prank(gov);
        mod.applyParams(p);

        vm.roll(1000);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("t");
        address s = makeAddr("submitter");
        token.mint(s, 1000 * UNIT);
        vm.startPrank(s);
        token.approve(address(mod), type(uint256).max);
        caseId = mod.submit(keccak256("content"), keccak256("meta"), topics, 100 * UNIT);
        vm.stopPrank();
    }

    /// @dev `cases` is slot 3; the eight `uint32` counters share the struct's fourth
    ///      word, with `pooledApprove` at bit 96 and `pooledReject` at bit 128.
    ///      Verified by `forge inspect ... storage`, and asserted below on every
    ///      write so a storage reorder fails loudly instead of silently sweeping
    ///      the wrong numbers.
    function _setTally(uint32 approve, uint32 reject) internal {
        bytes32 base = keccak256(abi.encode(caseId, uint256(3)));
        bytes32 slot = bytes32(uint256(base) + 3);
        uint256 w = uint256(vm.load(address(mod), slot));
        uint256 mask = ~((uint256(type(uint32).max) << 96) | (uint256(type(uint32).max) << 128));
        w = (w & mask) | (uint256(approve) << 96) | (uint256(reject) << 128);
        vm.store(address(mod), slot, bytes32(w));

        Moderation.Case memory c = mod.caseInfo(caseId);
        assertEq(c.pooledApprove, approve, "fixture: pooledApprove not where expected");
        assertEq(c.pooledReject, reject, "fixture: pooledReject not where expected");
    }

    /// @dev `f(a) = 3a^2 - 2a^3`, WAD-scaled, evaluated at `â = (A+1)/(N+2)`.
    ///      This is the closed form §4.5 quotes and every figure in the spec is
    ///      derived from; the contract must reproduce it as a rate.
    function _fOfAHat(uint256 approve, uint256 total) internal pure returns (uint256) {
        uint256 a = ((approve + 1) * WAD) / (total + 2);
        uint256 a2 = (a * a) / WAD;
        uint256 a3 = (a2 * a) / WAD;
        return 3 * a2 - 2 * a3;
    }

    function _entropy(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("e", i));
    }

    // =========================================================================
    // I22 — monotone in the tally, for fixed entropy. Exhaustive.
    // =========================================================================

    /// @dev The strongest check here, because it needs no statistics: with `u` held
    ///      fixed, moving one Reject vote to Approve may only move the verdict
    ///      TOWARD Approve. Swept over every tally with `N <= 24` and eight
    ///      entropies — 2,600 exact comparisons, against the eight the unit suite
    ///      could afford.
    ///
    ///      This is what fails under `u mod (N+2) < A+1`: that form is uniform and
    ///      gives the same marginal rate, but it RESHUFFLES on every change of `N`,
    ///      so a single added vote acts as a fresh draw and the sweep finds an
    ///      inversion almost immediately.
    function test_I22_verdictIsMonotoneInApproveAcrossEveryTally() public {
        uint256 checks;
        for (uint32 n = 1; n <= 24; ++n) {
            for (uint256 e; e < 8; ++e) {
                bytes32 ent = _entropy(e);
                bool sawApprove;
                for (uint32 a; a <= n; ++a) {
                    _setTally(a, n - a);
                    (uint8 v,) = mod.decideAt(caseId, ent);
                    if (v == APPROVE) {
                        sawApprove = true;
                    } else if (sawApprove) {
                        assertTrue(false, "I22: verdict moved back to Reject as Approve votes were added");
                    }
                    checks++;
                }
            }
        }
        assertGt(checks, 2000, "the sweep actually swept");
    }

    // =========================================================================
    // I12 — both outcomes reachable at EVERY tally, including unanimous ones
    // =========================================================================

    /// @dev The configuration a party controlling every reveal can produce is the
    ///      unanimous one, and it is exactly where `A/N` gives certainty. Swept over
    ///      every unanimous tally rather than the single `N = 3` the unit suite
    ///      checks.
    function test_I12_bothOutcomesReachableAtEveryUnanimousTally() public {
        for (uint32 n = 1; n <= 16; ++n) {
            _setTally(n, 0);
            bool sawA;
            bool sawR;
            for (uint256 e; e < 256 && !(sawA && sawR); ++e) {
                (uint8 v,) = mod.decideAt(caseId, _entropy(e));
                if (v == APPROVE) sawA = true;
                else sawR = true;
            }
            assertTrue(sawA, "Approve unreachable at a unanimous tally");
            assertTrue(sawR, "Reject unreachable at a unanimous Approve tally - I12 is false");
        }
    }

    /// @dev The mirror: a unanimous REJECT tally must still admit Approve.
    function test_I12_bothOutcomesReachableAtEveryUnanimousRejectTally() public {
        for (uint32 n = 1; n <= 16; ++n) {
            _setTally(0, n);
            bool sawA;
            for (uint256 e; e < 512 && !sawA; ++e) {
                (uint8 v,) = mod.decideAt(caseId, _entropy(e));
                if (v == APPROVE) sawA = true;
            }
            assertTrue(sawA, "Approve unreachable at a unanimous Reject tally");
        }
    }

    // =========================================================================
    // The rate itself, against the closed form
    // =========================================================================

    /// @dev `P(Approve) = f(â)`. Checked as a rate over 512 entropies at a spread of
    ///      tallies, with a 4-sigma band — wide enough not to flake, narrow enough
    ///      that `A/N` (which differs by 25.9 points at `N = 1`) cannot pass.
    function test_s4_5_empiricalRateTracksTheClosedForm() public {
        uint32[6] memory ns = [uint32(1), 3, 8, 16, 24, 34];
        for (uint256 k; k < 6; ++k) {
            uint32 n = ns[k];
            for (uint32 a = 0; a <= n; a += (n / 2 == 0 ? 1 : n / 2)) {
                _setTally(a, n - a);
                uint256 trials = 512;
                uint256 approves;
                for (uint256 e; e < trials; ++e) {
                    (uint8 v,) = mod.decideAt(caseId, _entropy(e + 10_000 * k));
                    if (v == APPROVE) approves++;
                }
                uint256 expected = (_fOfAHat(a, n) * trials) / WAD;
                // 4 sigma of a binomial at p<=1: sqrt(trials)/2 * 4 == 2*sqrt(512) ~ 46
                assertApproxEqAbs(approves, expected, 52, "empirical rate left the closed form's band");
            }
        }
    }

    /// @dev I11 — no verdict is more confident than the tally it was drawn from.
    ///      At a unanimous tally the ceiling is `f((N+1)/(N+2))`, which is 74.07% at
    ///      `N = 1`. Under `A/N` it would be 100%.
    function test_I11_confidenceIsBoundedAtEveryTally() public {
        for (uint32 n = 1; n <= 12; ++n) {
            _setTally(n, 0);
            uint256 trials = 512;
            uint256 approves;
            for (uint256 e; e < trials; ++e) {
                (uint8 v,) = mod.decideAt(caseId, _entropy(e));
                if (v == APPROVE) approves++;
            }
            assertLt(approves, trials, "certainty reached at a finite tally");
            uint256 ceiling = (_fOfAHat(n, n) * trials) / WAD;
            assertApproxEqAbs(approves, ceiling, 52, "unanimous rate is f((N+1)/(N+2))");
        }
    }

    /// @dev §4.5's stated example, as a regression: at `N = 1` unanimous the draw
    ///      approves 74.07% of the time and the cohort is overruled 25.9%. The
    ///      number the whole `MIN_COMMITS` removal argument rests on.
    function test_s4_5_theSingleRevealCaseMatchesTheDocumentedFigure() public {
        _setTally(1, 0);
        // 1 wei below the exact value: WAD-scaled `f` truncates twice on the way.
        assertApproxEqAbs(_fOfAHat(1, 1), 740_740_740_740_740_740, 1, "f(2/3) = 0.7407");
        uint256 approves;
        for (uint256 e; e < 1024; ++e) {
            (uint8 v,) = mod.decideAt(caseId, _entropy(e));
            if (v == APPROVE) approves++;
        }
        assertApproxEqAbs(approves, 758, 74, "empirically 74.1%");
    }

    /// @dev The empty tally is well defined and gives `f(0.5)`. Not reachable
    ///      through the state machine (§4.3 routes `pooled == 0` to `NO_REVEALS`),
    ///      which is why the draw needs no `N > 0` guard — but the arithmetic must
    ///      still be total, because a revert here would be unrecoverable.
    function test_s4_5_theEmptyTallyIsACoinFlip() public {
        _setTally(0, 0);
        assertApproxEqAbs(_fOfAHat(0, 0), 500_000_000_000_000_000, 1, "f(1/2) = 0.5");
        uint256 approves;
        for (uint256 e; e < 512; ++e) {
            (uint8 v,) = mod.decideAt(caseId, _entropy(e));
            if (v == APPROVE) approves++;
        }
        assertApproxEqAbs(approves, 256, 52, "a coin flip on zero evidence");
    }
}
