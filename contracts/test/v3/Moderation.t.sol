// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";

/// @notice Records every index write so I15 can be checked by COUNT and ORDER, not
///         only by final state. A test that reads the last write cannot tell a
///         write at the terminal from one during settlement.
/// @title Moderation (v3) — §4 state machine suite
/// @notice Every test names the invariant or section it checks. Tests marked
///         MUTATION were verified by removing the named property from the source
///         and confirming this test goes red; the campaign is in the commit message.
contract ModerationV3Test is Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    IndexRegistry internal idx;
    Moderation internal mod;

    address internal gov;
    address internal submitter;
    address internal poker;
    address internal treasury;

    // Test fixture values. §1 leaves several of these open and this suite picks
    // numbers only so a case can run — see DEVIATIONS D3-6. None is a proposal.
    uint256 internal constant UNIT = 1e16; // xBZZ is 16 decimals
    uint256 internal constant MIN_STAKE = 10 * UNIT;
    uint256 internal constant BOND_MIN = 5 * UNIT;
    uint256 internal constant MATURATION = 3 days;
    uint256 internal constant EXIT_COOLDOWN = 7 days;
    uint256 internal constant TIMELOCK = 2 days;
    uint256 internal constant MIN_TRACK_DECAY = 0.5e18;

    uint32 internal constant BLOCK_TIME = 5;
    uint32 internal constant COMMIT_WINDOW = 1200; // 240 blocks
    uint32 internal constant REVEAL_WINDOW = 1200; // 240 blocks
    uint32 internal constant CHALLENGE_WINDOW = 43_200; // 8,640 blocks
    uint32 internal constant SEED_LAG = 2;
    uint32 internal constant HORIZON = 256;

    uint32 internal constant COMMIT_BLOCKS = 240;
    uint32 internal constant REVEAL_BLOCKS = 240;
    uint32 internal constant CHALLENGE_BLOCKS = 8640;

    uint128 internal constant LAMBDA = 2 * uint128(UNIT);
    uint128 internal constant REVEAL_BOND = 2 * uint128(UNIT);
    uint128 internal constant PENALTY_D = 1 * uint128(UNIT);
    uint128 internal constant CHALLENGE_BOND = 3 * uint128(UNIT);
    uint256 internal constant FEE = 1000 * UNIT;

    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;

    bytes32[] internal topics;

    function setUp() public {
        gov = makeAddr("gov");
        submitter = makeAddr("submitter");
        poker = makeAddr("poker");
        treasury = makeAddr("treasury");

        token = new MockBZZ();
        vm.prank(gov);
        reg = new StakeRegistry(
            IERC20(address(token)), MIN_STAKE, BOND_MIN, MATURATION, EXIT_COOLDOWN, TIMELOCK, MIN_TRACK_DECAY
        );
        vm.prank(gov);
        idx = new IndexRegistry(TIMELOCK);
        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), gov);

        // Governance grants Moderation the two capabilities §2.4 defines.
        uint8 bits = reg.MAY_CREATE() | reg.MAY_DISCHARGE();
        vm.prank(gov);
        reg.proposeCaps(address(mod), bits);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        reg.executeCaps();

        vm.prank(gov);
        idx.proposeWriter(address(mod), true);
        (,, uint256 wEta,) = idx.pendingWriterProposal();
        vm.warp(wEta);
        vm.prank(gov);
        idx.executeWriter();

        vm.prank(gov);
        mod.applyParams(_params());

        topics.push(keccak256("topic-a"));
        topics.push(keccak256("topic-b"));

        token.mint(submitter, 1_000_000 * UNIT);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);

        vm.roll(1000);
    }

    function _params() internal pure returns (Moderation.Params memory p) {
        p.blockTime = BLOCK_TIME;
        p.commitWindow = COMMIT_WINDOW;
        p.revealWindow = REVEAL_WINDOW;
        p.challengeWindow = CHALLENGE_WINDOW;
        p.lateWidenAt = 720; // minute 12 of a 20-minute commit phase
        p.seedLag = SEED_LAG;
        p.blockhashHorizon = HORIZON;
        p.retryCooldown = 1 days;
        p.superQuorum = 16;
        p.lateWidenFactorBps = 15_000;
        p.drawBountyBps = 50;
        p.claimBountyBps = 100;
        p.reserveBps = 2000;
        p.maintenanceBps = 1000;
        p.lambda = LAMBDA;
        p.revealBond = REVEAL_BOND;
        p.penaltyDebit = PENALTY_D;
        p.challengeBond = CHALLENGE_BOND;
        p.trackDecay = 0.95e18;
        p.feeBase = uint128(100 * UNIT);
        p.feePerTopic = uint128(10 * UNIT);
        p.threshold = type(uint256).max; // everyone eligible: this suite is not about §3.3
    }

    // --- fixture helpers ------------------------------------------------------

    /// @dev Idempotent: a moderator may take part in several cases in one test,
    ///      which is the shape I3 and the custody boundary are actually about.
    function _moderator(uint256 i) internal returns (address a) {
        a = makeAddr(string(abi.encodePacked("mod", vm.toString(i))));
        if (reg.stateOf(a) != StakeRegistry.State.NONE) return a;
        uint256 bond = BOND_MIN + 50 * UNIT;
        token.mint(a, MIN_STAKE + bond);
        vm.startPrank(a);
        token.approve(address(reg), type(uint256).max);
        reg.stake(bond);
        vm.stopPrank();
    }

    function _matureAll() internal {
        vm.warp(block.timestamp + MATURATION + 1);
    }

    function _submit() internal returns (uint256 caseId) {
        vm.prank(submitter);
        caseId = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    /// @dev A case with its own claim key, for tests that need several at once.
    ///      §8.4 reserves the key, so reusing one content hash is refused — which
    ///      is the contract working, not a fixture convenience to route around.
    function _submitFresh(uint256 n) internal returns (uint256 caseId) {
        vm.prank(submitter);
        caseId = mod.submit(keccak256(abi.encode("content", n)), keccak256("meta"), topics, FEE);
    }

    /// @dev Reads the REAL index for a case's first topic. Asserting on observable
    ///      state is strictly stronger than counting calls into a stub: it checks
    ///      what a reader would actually see, and "written at the terminal" becomes
    ///      "already visible in that transaction" rather than "the stub was called".
    function _idxStatus(uint256 caseId) internal view returns (uint8) {
        return idx.statusOf(mod.caseInfo(caseId).claimKey, topics[0]);
    }

    function _idxPlurality(uint256 caseId) internal view returns (uint8) {
        return idx.entryOf(mod.caseInfo(caseId).claimKey, topics[0]).plurality;
    }

    function _idxQuestions(uint256 caseId) internal view returns (uint32) {
        return idx.entryOf(mod.caseInfo(caseId).claimKey, topics[0]).openQuestions;
    }

    function _salt(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", a));
    }

    function _commit(uint256 caseId, address a, uint8 v) internal {
        Moderation.Case memory c = mod.caseInfo(caseId);
        bytes32 h = mod.commitHash(caseId, c.round, c.paramsVersion, a, v, _salt(a));
        vm.prank(a);
        mod.commit(caseId, h);
    }

    function _reveal(uint256 caseId, address a, uint8 v) internal {
        vm.prank(a);
        mod.reveal(caseId, v, _salt(a));
    }

    /// @dev Drives a case to `TALLY` with `nApprove` Approve and `nReject` Reject
    ///      reveals, returning the moderator set in commit order.
    function _toTally(uint256 caseId, uint256 nApprove, uint256 nReject)
        internal
        returns (address[] memory who)
    {
        uint256 n = nApprove + nReject;
        who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = _moderator(i);
        }
        _matureAll();

        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < n; ++i) {
            _commit(caseId, who[i], i < nApprove ? APPROVE : REJECT);
        }

        vm.roll(mod.caseInfo(caseId).phaseDeadline);
        mod.closeCommit(caseId);
        for (uint256 i; i < n; ++i) {
            _reveal(caseId, who[i], i < nApprove ? APPROVE : REJECT);
        }
        vm.roll(mod.caseInfo(caseId).phaseDeadline);
        mod.closeReveal(caseId);
    }

    function _rollToDraw(uint256 caseId) internal {
        Moderation.Case memory c = mod.caseInfo(caseId);
        if (c.phase == uint8(Moderation.Phase.TALLY)) {
            vm.roll(c.phaseDeadline);
            mod.closeTally(caseId);
            c = mod.caseInfo(caseId);
        }
        vm.roll(uint256(c.outcomeSeedBlock) + 1);
    }

    // =========================================================================
    // §4.8b — there is no quorum gate
    // =========================================================================

    /// MUTATION: require `commitsThisRound >= 16` (or any constant > 1) in
    ///           `closeCommit`.
    /// @dev `MIN_COMMITS` was removed as a parameter, not lowered. A single commit
    ///      carries the round.
    function test_s4_8b_oneCommitCarriesTheRound() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL), "one commit is enough");
    }

    /// MUTATION: route a thin round to NO_TURNOUT.
    /// @dev `NO_TURNOUT` means an EMPTY round, not a thin one.
    function test_s4_8b_noTurnoutRequiresAnEmptyRound() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.terminal, uint8(Moderation.Terminal.UNRESOLVED));
        assertEq(c.unresolvedReason, uint8(Moderation.Reason.NO_TURNOUT));
    }

    /// @dev A single revealed vote reaches a verdict. Since §4.8b this is
    ///      reachable and not hypothetical — `â` discounts it by 25.9% rather than
    ///      a gate excluding it.
    function test_s4_8b_oneRevealReachesAVerdict() public {
        uint256 id = _submit();
        _toTally(id, 1, 0);
        _rollToDraw(id);
        mod.draw(id);
        Moderation.Case memory c = mod.caseInfo(id);
        assertTrue(c.terminal == uint8(Moderation.Terminal.APPROVED) || c.terminal == uint8(Moderation.Terminal.REJECTED));
    }

    /// MUTATION: add a quorum gate to `closeCommit` when `round == 1`.
    /// @dev §4.9 — round 1 has no gate and needs none: an empty round 1 leaves the
    ///      pooled tally identical, so the draw sees what it would have seen.
    ///      A gate here recreates F8: a rejected submitter challenges, stays quiet,
    ///      and takes the free retry.
    function test_s4_9_emptyRound1ProceedsAndLeavesTheTallyIdentical() public {
        uint256 id = _submit();
        _toTally(id, 3, 1);
        address ch = _moderator(900);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        assertEq(mod.caseInfo(id).round, 1);

        // Nobody commits in round 1.
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL), "empty round 1 proceeds");

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.phase, uint8(Moderation.Phase.DRAW));
        assertEq(c.pooledApprove, 3);
        assertEq(c.pooledReject, 1);
    }

    // =========================================================================
    // §4.5 — the draw
    // =========================================================================

    /// MUTATION: add `if (N == 0) revert;` to `draw`.
    /// @dev The spec previously asked for exactly this guard and it was wrong. The
    ///      draw does not divide, and a revert inside `DRAW` strands the case
    ///      forever — the guard converts an impossible state into a permanent one.
    ///      At `A = N = 0` the arithmetic is well defined and gives `f(0.5)`.
    function test_s4_5_drawIsWellDefinedOnAnEmptyTally() public {
        uint256 id = _submit();
        (uint8 verdict, uint8 tickets) = mod.decideAt(id, keccak256("any"));
        assertTrue(verdict == APPROVE || verdict == REJECT, "total on the empty tally");
        assertLe(tickets, 3);
    }

    /// MUTATION: use `A/N` in place of `â = (A+1)/(N+2)`.
    /// @dev I12. At a unanimous tally `A/N == 1`, so every ticket is Approve and the
    ///      outcome is CERTAIN — which is exactly the configuration a party who
    ///      controls every reveal can produce. Under `â` a unanimous tally of 3
    ///      still yields Reject on 10.4% of entropies.
    function test_I12_unanimousTallyStillAdmitsBothOutcomes() public {
        uint256 id = _submit();
        _toTally(id, 3, 0);

        uint256 approves;
        uint256 rejects;
        for (uint256 i; i < 400; ++i) {
            (uint8 v,) = mod.decideAt(id, keccak256(abi.encode("e", i)));
            if (v == APPROVE) approves++;
            else rejects++;
        }
        assertGt(approves, 0, "Approve reachable");
        assertGt(rejects, 0, "Reject reachable at a UNANIMOUS tally - this is I12");
        // f(â) at â = 4/5 is 3(0.64) - 2(0.512) = 0.896
        assertApproxEqAbs(approves, 358, 45, "empirical rate tracks f(4/5) = 0.896");
    }

    /// MUTATION: give the three uniforms a shared index, so they are identical.
    /// @dev §4.5 — "with replacement is still required, and now trivially:
    ///      `u[0..2]` are independent, so a side holding one revealed vote keeps
    ///      `f(â) = 0.997%` at `â = 2/34`." Without independence the three tickets
    ///      collapse to one and `P(Approve)` becomes `â` rather than `f(â)`.
    ///
    ///      Tested STRUCTURALLY rather than by rate: a split draw (1 or 2 tickets
    ///      of 3) is impossible when the tickets are identical, and a rate
    ///      assertion wide enough to be stable is also wide enough to miss the
    ///      difference between `â` and `f(â)`.
    function test_s4_5_theThreeTicketsAreIndependent() public {
        uint256 id = _submit();
        _toTally(id, 3, 3); // â = 1/2, where a split draw is most likely

        uint256 split;
        uint256 unanimous;
        for (uint256 i; i < 200; ++i) {
            (, uint8 tickets) = mod.decideAt(id, keccak256(abi.encode("ind", i)));
            if (tickets == 1 || tickets == 2) split++;
            else unanimous++;
        }
        assertGt(split, 0, "a split draw must be reachable - the tickets are three, not one");
        assertGt(unanimous, 0, "and so must a unanimous one");
        // Three iid Bernoulli(1/2): P(split) = 6/8.
        assertApproxEqAbs(split, 150, 25, "the split rate is that of three independent tickets");
    }

    /// @dev I11 — no verdict is more confident than the tally it was drawn from.
    ///      Neither outcome exceeds `f((N+1)/(N+2))` at any `N`.
    function test_I11_confidenceIsBoundedByTheTally() public {
        uint256 id = _submit();
        _toTally(id, 1, 0); // N = 1, â = 2/3, f(â) = 0.7407
        uint256 approves;
        for (uint256 i; i < 400; ++i) {
            (uint8 v,) = mod.decideAt(id, keccak256(abi.encode("e", i)));
            if (v == APPROVE) approves++;
        }
        assertApproxEqAbs(approves, 296, 45, "N=1 unanimous is 74.1%, not certainty");
        assertLt(approves, 400, "never certain");
    }

    /// MUTATION: `u mod (N+2) < A+1` in place of the cross-multiplied comparison.
    /// @dev I22. Both forms are uniform and both give `f(â)`; only the
    ///      cross-multiplied one is MONOTONE in `â`. The modulo form reshuffles on
    ///      every change of `N`, so one added vote acts as a fresh draw — and
    ///      monotonicity is the entire reason a challenge cannot buy a re-roll.
    ///
    ///      Votes are added ONE AT A TIME to a live case with the entropy held
    ///      fixed, which is the shape the invariant is actually about.
    function test_I22_verdictIsMonotoneInTheTallyForFixedEntropy() public {
        uint256 id = _submit();
        uint256 n = 24;
        address[] memory who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = _moderator(i);
        }
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < n; ++i) {
            _commit(id, who[i], APPROVE);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);

        bytes32[8] memory entropies = [
            keccak256("e0"), keccak256("e1"), keccak256("e2"), keccak256("e3"),
            keccak256("e4"), keccak256("e5"), keccak256("e6"), keccak256("e7")
        ];
        uint8[8] memory seen;
        for (uint256 e; e < 8; ++e) {
            (seen[e],) = mod.decideAt(id, entropies[e]);
        }

        // Every added vote is Approve, so no verdict may move from Approve back to
        // Reject at any point in the sweep.
        for (uint256 i; i < n; ++i) {
            _reveal(id, who[i], APPROVE);
            for (uint256 e; e < 8; ++e) {
                (uint8 v,) = mod.decideAt(id, entropies[e]);
                if (seen[e] == APPROVE) {
                    assertEq(v, APPROVE, "Approve never reverts to Reject as Approve votes are added");
                }
                seen[e] = v;
            }
        }
    }

    /// @dev The one-line I22 proof, at the boundary: adding an Approve vote takes
    ///      `â` from `(A+1)/(N+2)` to `(A+2)/(N+3)`, and `(A+2)(N+2) - (A+1)(N+3)
    ///      = N + 1 - A > 0`.
    function test_I22_addingARejectVoteNeverHelpsApprove() public {
        uint256 id = _submit();
        uint256 n = 12;
        address[] memory who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = _moderator(i);
        }
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < n; ++i) {
            _commit(id, who[i], i < 6 ? APPROVE : REJECT);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 6; ++i) {
            _reveal(id, who[i], APPROVE);
        }

        bytes32 e = keccak256("fixed");
        (uint8 before_,) = mod.decideAt(id, e);
        for (uint256 i = 6; i < n; ++i) {
            _reveal(id, who[i], REJECT);
            (uint8 v,) = mod.decideAt(id, e);
            if (before_ == REJECT) assertEq(v, REJECT, "Reject never flips to Approve on Reject votes");
            before_ = v;
        }
    }

    /// MUTATION: re-read `blockhash` in `_decide` instead of the stored word.
    /// @dev §4.5 — one randomness per claim, for the LIFE of the claim. `blockhash`
    ///      expires; the stored entropy does not, and a re-review must not re-roll.
    function test_s4_5_verdictReDerivesFromStoredEntropyAfterBlockhashExpires() public {
        uint256 id = _submit();
        _toTally(id, 5, 2);
        _rollToDraw(id);
        vm.prank(poker);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertTrue(c.outcomeEntropy != bytes32(0), "entropy stored");

        // Walk far past the blockhash horizon; the stored word still decides.
        vm.roll(block.number + 5000);
        (uint8 v,) = mod.decideAt(id, c.outcomeEntropy);
        assertEq(v, c.verdict, "identical verdict after the hash is unreadable");
    }

    // =========================================================================
    // §7.2 / I29 — seeds and their guards
    // =========================================================================

    /// MUTATION: replace either height guard in `_eligible` with
    ///           `blockhash(sb) == 0`.
    /// @dev I29 — `blockhash` returns zero for a block that has EXPIRED and for one
    ///      that has NOT HAPPENED YET, so a guard phrased as "the seed is
    ///      unavailable" is true in two states and distinguishes neither. The head
    ///      gap is the serious one: it is the first `SEED_LAG + 1` blocks of EVERY
    ///      commit phase, and unguarded, every moderator is evaluated against
    ///      `roundSeed = 0` — a set computable from `caseId` at submission.
    function test_I29_eligibilityRevertsInTheHeadGapRatherThanUsingAZeroSeed() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();

        // The seed block has not been produced yet.
        vm.expectRevert(Moderation.SeedNotYet.selector);
        mod.isEligible(id, m);

        vm.roll(block.number + SEED_LAG + 1);
        assertTrue(mod.isEligible(id, m), "readable once the seed exists");
    }

    /// MUTATION: drop the tail guard.
    /// @dev When the tail guard fires the failure is graceful: commits revert for
    ///      the remainder of the phase and turnout is whatever arrived before it.
    function test_I29_eligibilityRevertsPastTheSeedHorizon() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        Moderation.Case memory c = mod.caseInfo(id);
        vm.roll(uint256(c.eligSeedBlock) + HORIZON + 1);
        vm.expectRevert(Moderation.SeedExpired.selector);
        mod.isEligible(id, m);
    }

    /// MUTATION: test `blockhash(outcomeSeedBlock) == 0` in `draw`.
    /// @dev `DRAW` is entered ~40 minutes before `outcomeSeedBlock` on the
    ///      unchallenged path, because §7.2 puts the round-1 windows in the formula
    ///      whether or not round 1 runs. An implementation testing the hash would
    ///      let any party terminate a LIVE case in that window while collecting
    ///      `DRAW_BOUNTY`.
    function test_I29_drawCannotBeForcedEarlyInTheWaitingWindow() public {
        uint256 id = _submit();
        _toTally(id, 4, 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.phase, uint8(Moderation.Phase.DRAW));
        assertLt(block.number, uint256(c.outcomeSeedBlock), "the waiting state is real");

        vm.prank(poker);
        vm.expectRevert(Moderation.SeedNotYet.selector);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.NONE), "case still live");
    }

    /// MUTATION: derive `outcomeSeedBlock` without the round-1 windows.
    /// @dev I7 / §7.2 — the outcome block does not depend on whether the case was
    ///      challenged, when it was challenged, or who called the transition. That
    ///      is what makes the observable timing of a case leak nothing about
    ///      whether it was contested.
    function test_I7_outcomeBlockIsIdenticalOnBothPaths() public {
        uint256 a = _submit();
        vm.prank(submitter);
        uint256 b = mod.submit(keccak256("content2"), keccak256("meta2"), topics, FEE);

        uint256 expected = uint256(mod.caseInfo(a).outcomeSeedBlock);
        assertEq(
            expected,
            1000 + uint256(COMMIT_BLOCKS) + REVEAL_BLOCKS + CHALLENGE_BLOCKS + COMMIT_BLOCKS + REVEAL_BLOCKS + SEED_LAG,
            "submission height plus ALL FOUR windows plus SEED_LAG"
        );

        // Case b is challenged; its outcome block is unchanged by that.
        _toTally(b, 3, 1);
        address ch = _moderator(901);
        _matureAll();
        vm.prank(ch);
        mod.challenge(b);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeTally(b);
        assertEq(uint256(mod.caseInfo(b).outcomeSeedBlock), expected, "challenge moved no seed");
    }

    /// MUTATION: arm the round-1 eligibility seed in `challenge()`.
    /// @dev §3.5b — round 1 opens on the SCHEDULE, not on the challenge. Otherwise
    ///      the challenger has twelve hours of discretion over which cohort is
    ///      drawn, after seeing the round-0 result.
    function test_s3_5b_challengeArmsNoSeedAndMovesNoDeadline() public {
        uint256 id = _submit();
        _toTally(id, 3, 1);
        Moderation.Case memory before_ = mod.caseInfo(id);

        address ch = _moderator(902);
        _matureAll();
        vm.roll(block.number + 500); // the challenger picks a late block
        vm.prank(ch);
        mod.challenge(id);

        Moderation.Case memory after_ = mod.caseInfo(id);
        assertEq(after_.eligSeedBlock, before_.eligSeedBlock, "no seed armed");
        assertEq(after_.phaseDeadline, before_.phaseDeadline, "no deadline moved");
        assertEq(after_.phase, before_.phase, "no phase change");
        assertEq(after_.challengeReserve, before_.challengeReserve, "nothing transferred");
        assertEq(after_.challenger, ch);
    }

    /// @dev I17 — one challenge per opening. The first valid registration wins;
    ///      later ones revert rather than queue.
    function test_I17_secondChallengeReverts() public {
        uint256 id = _submit();
        _toTally(id, 3, 1);
        address c1 = _moderator(903);
        address c2 = _moderator(904);
        _matureAll();
        vm.prank(c1);
        mod.challenge(id);
        vm.prank(c2);
        vm.expectRevert(Moderation.AlreadyChallenged.selector);
        mod.challenge(id);
    }

    // =========================================================================
    // §3.4 / I3 — one vote per claim
    // =========================================================================

    /// MUTATION: key the allowance on `revealedVote` instead of `commitments`.
    /// @dev Scoping it to reveals lets a moderator commit in round 0, abandon for
    ///      the price of `REVEAL_BOND`, and commit again in round 1 with the round-0
    ///      tally in hand. The ballot secrecy of §4.7 buys nothing against someone
    ///      who can wait and re-enter.
    function test_I3_aRound0CommitterCannotCommitAgainInRound1() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1);
        address abandoner = who[0];

        address ch = _moderator(905);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(block.number + SEED_LAG + 1);

        Moderation.Case memory c = mod.caseInfo(id);
        bytes32 h = mod.commitHash(id, c.round, c.paramsVersion, abandoner, REJECT, _salt(abandoner));
        vm.prank(abandoner);
        vm.expectRevert(Moderation.AlreadyCommitted.selector);
        mod.commit(id, h);
    }

    /// @dev The allowance is consumed by the COMMIT even when the moderator never
    ///      reveals — which is the case the mutation above would let through.
    function test_I3_anAbandonedCommitStillConsumesTheAllowance() public {
        uint256 id = _submit();
        address m = _moderator(1);
        address other = _moderator(2);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        _commit(id, other, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        _reveal(id, other, APPROVE); // m abandons

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);

        assertEq(mod.revealOf(id, m), 0, "never revealed");
        assertTrue(mod.commitmentOf(id, m) != bytes32(0), "but the allowance is spent");
    }

    /// @dev A round-0 commitment binds `round`, so it cannot be replayed into
    ///      round 1's reveal phase even if the allowance check were bypassed.
    function test_I3_commitmentBindsTheRound() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        bytes32 h0 = mod.commitHash(id, 0, 1, m, APPROVE, _salt(m));
        bytes32 h1 = mod.commitHash(id, 1, 1, m, APPROVE, _salt(m));
        assertTrue(h0 != h1, "the round is inside the preimage");
    }

    // =========================================================================
    // §4.4 — no phase closes early
    // =========================================================================

    /// MUTATION: close the reveal phase once `revealsThisRound == commitsThisRound`.
    /// @dev Early closure on "everyone revealed" hands the last actor a free binary
    ///      choice over outcome seeds. At a hostile 30% of reveals over `N = 34`
    ///      that raises their odds from 22.3% to 39.6% with no stake, no identities
    ///      and no extra votes.
    function test_s4_4_revealDoesNotCloseWhenEveryoneHasRevealed() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        _reveal(id, m, APPROVE);

        assertEq(mod.caseInfo(id).revealsThisRound, mod.caseInfo(id).commitsThisRound);
        vm.expectRevert(Moderation.DeadlineNotReached.selector);
        mod.closeReveal(id);
    }

    /// @dev And the challenge window does not close early when it is quiet.
    function test_s4_4_tallyDoesNotCloseEarlyWhenUnchallenged() public {
        uint256 id = _submit();
        _toTally(id, 2, 1);
        vm.expectRevert(Moderation.DeadlineNotReached.selector);
        mod.closeTally(id);
    }

    /// @dev What IS permitted, and is implemented: permissionless immediate
    ///      finalization once the outcome block exists. No grace period.
    function test_s4_4_finalizationIsPermissionlessAndImmediate() public {
        uint256 id = _submit();
        _toTally(id, 3, 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + 1);

        vm.prank(poker); // a stranger, in the very first eligible block
        mod.draw(id);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
    }

    // =========================================================================
    // I18 — the §4.3 guards are pairwise disjoint
    // =========================================================================

    /// @dev Tries every phase-transition entrypoint from a given state and returns
    ///      how many succeed. Each attempt runs against a fresh snapshot, so the
    ///      count is of ENABLED rows and not of a sequence.
    function _enabledTransitions(uint256 id) internal returns (uint256 n) {
        function(uint256) external[4] memory fns =
            [mod.closeCommit, mod.closeReveal, mod.closeTally, mod.draw];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            try fns[i](id) {
                n++;
            } catch {}
            vm.revertToState(snap);
        }
    }

    /// MUTATION: drop the `c.round == 0` qualifier from the NO_TURNOUT branch, or
    ///           the `challenger == 0` qualifier from `closeTally`.
    /// @dev I18 says AT MOST one, not exactly one: no row is enabled before the
    ///      relevant deadline, including the interval between reveal close and
    ///      `outcomeSeedBlock`.
    function test_I18_atMostOneTransitionIsEnabledInEveryReachableState() public {
        uint256 id = _submit();

        assertEq(_enabledTransitions(id), 0, "COMMIT, before the deadline");
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        address m1 = _moderator(1);
        address m2 = _moderator(2);
        _matureAll();
        _commit(id, m1, APPROVE);
        _commit(id, m2, REJECT);

        assertEq(_enabledTransitions(id), 0, "COMMIT, still before the deadline");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        assertEq(_enabledTransitions(id), 1, "COMMIT close");
        mod.closeCommit(id);

        assertEq(_enabledTransitions(id), 0, "REVEAL, before the deadline");
        _reveal(id, m1, APPROVE);
        _reveal(id, m2, REJECT);
        assertEq(_enabledTransitions(id), 0, "REVEAL, everyone revealed but not due");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        assertEq(_enabledTransitions(id), 1, "REVEAL close");
        mod.closeReveal(id);

        assertEq(_enabledTransitions(id), 0, "TALLY, challenge window open");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        assertEq(_enabledTransitions(id), 1, "TALLY close");
        mod.closeTally(id);

        // The waiting state §7.2 creates: DRAW is entered, nothing is enabled.
        assertEq(_enabledTransitions(id), 0, "DRAW, before outcomeSeedBlock");
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + 1);
        assertEq(_enabledTransitions(id), 1, "DRAW enabled");
        mod.draw(id);

        assertEq(_enabledTransitions(id), 0, "FINALIZED is a LEAF");
    }

    /// @dev The challenged branch, and the two `UNRESOLVED` leaves.
    function test_I18_atMostOneTransitionOnTheChallengedPathAndAtLeaves() public {
        uint256 id = _submitFresh(11);
        _toTally(id, 2, 1);
        address ch = _moderator(906);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        assertEq(_enabledTransitions(id), 0, "TALLY, challenged, window open");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        assertEq(_enabledTransitions(id), 1, "TALLY close, challenged");
        mod.closeTally(id);
        assertEq(mod.caseInfo(id).round, 1);
        assertEq(_enabledTransitions(id), 0, "COMMIT r1, before the deadline");

        uint256 empty = _submitFresh(12);
        _matureAll();
        vm.roll(mod.caseInfo(empty).phaseDeadline);
        mod.closeCommit(empty);
        assertEq(_enabledTransitions(empty), 0, "UNRESOLVED is a LEAF");
    }

    // =========================================================================
    // I19 — every §4.1 field is written or provably preserved
    // =========================================================================

    /// @dev Hashes the whole `Case` field-by-field so a diff is exact. A test that
    ///      spot-checks a few fields cannot catch an implicit carry across a round
    ///      boundary, which is the failure this invariant exists for.
    function _fingerprint(uint256 id) internal view returns (bytes memory) {
        Moderation.Case memory c = mod.caseInfo(id);
        return abi.encode(c);
    }

    /// MUTATION: delete `c.revealsThisRound = 0;` from `closeTally`.
    /// @dev §4.3 names `revealsThisRound` as the field this rule exists for:
    ///      without the reset the round-1 threshold reads round 0's count. It is
    ///      also what makes §5.3's `reveals1` derivation load-bearing.
    function test_I19_tallyToCommitResetsBothPerRoundCounters() public {
        uint256 id = _submit();
        _toTally(id, 3, 2);
        assertEq(mod.caseInfo(id).revealsThisRound, 5);
        assertEq(mod.caseInfo(id).commitsThisRound, 5);

        address ch = _moderator(907);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        Moderation.Case memory c = mod.caseInfo(id);
        assertEq(c.commitsThisRound, 0, "reset");
        assertEq(c.revealsThisRound, 0, "reset - I19's named field");
        assertEq(c.pooledApprove, 3, "pooled is NOT reset");
        assertEq(c.pooledReject, 2, "pooled is NOT reset");
        assertEq(c.reveals0, 5, "round-0 count is preserved for 5.3");
    }

    /// MUTATION: reset `pooledApprove`/`pooledReject` at `TALLY -> COMMIT`.
    /// @dev `TALLY -> DRAW` must NOT reset `revealsThisRound` — §4.3 qualifies the
    ///      reset by the row, and §5.3's `reveals1` is zero on the unchallenged
    ///      path by ARITHMETIC rather than by that reset.
    function test_I19_tallyToDrawPreservesEveryCountAndTouchesNothingElse() public {
        uint256 id = _submit();
        _toTally(id, 4, 1);
        bytes memory before_ = _fingerprint(id);

        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        Moderation.Case memory a = mod.caseInfo(id);
        Moderation.Case memory b = abi.decode(before_, (Moderation.Case));
        assertEq(a.phase, uint8(Moderation.Phase.DRAW));
        assertEq(b.phase, uint8(Moderation.Phase.TALLY));
        // Everything except `phase` is preserved by this row.
        assertEq(a.round, b.round);
        assertEq(a.terminal, b.terminal);
        assertEq(a.unresolvedReason, b.unresolvedReason);
        assertEq(a.paramsVersion, b.paramsVersion);
        assertEq(a.phaseDeadline, b.phaseDeadline);
        assertEq(a.eligSeedBlock, b.eligSeedBlock);
        assertEq(a.outcomeSeedBlock, b.outcomeSeedBlock);
        assertEq(a.plurality, b.plurality);
        assertEq(a.verdict, b.verdict);
        assertEq(a.pot, b.pot);
        assertEq(a.challengeReserve, b.challengeReserve);
        assertEq(a.commitsThisRound, b.commitsThisRound);
        assertEq(a.revealsThisRound, b.revealsThisRound, "NOT reset on this row");
        assertEq(a.reveals0, b.reveals0);
        assertEq(a.pooledApprove, b.pooledApprove);
        assertEq(a.pooledReject, b.pooledReject);
        assertEq(a.challenger, b.challenger);
        assertEq(a.outcomeEntropy, b.outcomeEntropy);
        assertEq(a.finalizedAt, b.finalizedAt);
    }

    /// MUTATION: leave `terminal` unwritten on any terminal row.
    /// @dev §4.3 — `terminal` is written by every row reaching a terminal state and
    ///      by no other. §8.2 and §8.4 both key on it, and an earlier revision left
    ///      it unwritten by the whole table.
    function test_I19_terminalIsWrittenByEveryTerminalRowAndNoOther() public {
        // NO_TURNOUT
        uint256 a = _submitFresh(21);
        _matureAll();
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        assertEq(mod.caseInfo(a).terminal, uint8(Moderation.Terminal.UNRESOLVED));

        // NO_REVEALS
        uint256 b = _submitFresh(22);
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(b, m, APPROVE);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeCommit(b);
        assertEq(mod.caseInfo(b).terminal, uint8(Moderation.Terminal.NONE), "not terminal yet");
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeReveal(b);
        assertEq(mod.caseInfo(b).terminal, uint8(Moderation.Terminal.UNRESOLVED));
        assertEq(mod.caseInfo(b).unresolvedReason, uint8(Moderation.Reason.NO_REVEALS));

        // FINALIZED
        uint256 d = _submitFresh(23);
        _toTally(d, 3, 0);
        assertEq(mod.caseInfo(d).terminal, uint8(Moderation.Terminal.NONE), "TALLY is not terminal");
        _rollToDraw(d);
        mod.draw(d);
        assertTrue(mod.caseInfo(d).terminal != uint8(Moderation.Terminal.NONE));
    }

    /// @dev NO_RANDOMNESS — the fourth terminal row.
    function test_I19_noRandomnessIsATerminalAndKeepsThePooledTally() public {
        uint256 id = _submit();
        _toTally(id, 5, 3);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        Moderation.Case memory c = mod.caseInfo(id);
        vm.roll(uint256(c.outcomeSeedBlock) + HORIZON + 1);

        vm.prank(poker);
        mod.draw(id);

        c = mod.caseInfo(id);
        assertEq(c.terminal, uint8(Moderation.Terminal.UNRESOLVED));
        assertEq(c.unresolvedReason, uint8(Moderation.Reason.NO_RANDOMNESS));
        assertEq(c.pooledApprove, 5, "the pooled tally SURVIVES into settlement");
        assertEq(c.pooledReject, 3);
        assertEq(c.plurality, APPROVE, "and the plurality with it");
        assertEq(c.verdict, uint8(Moderation.Outcome.NONE), "no verdict was drawn");
    }

    // =========================================================================
    // §8.1 / I15 — the index
    // =========================================================================

    /// MUTATION: move the `_writeIndex` call from `_toUnresolved` into `claim`.
    /// @dev §8.1 — there are FOUR transitions that establish a terminal, not one.
    ///      §5.5 makes an index write bundled into settlement worse than it was:
    ///      settlement is pulled per moderator and may NEVER complete, so the entry
    ///      would sit behind an unbounded number of calls nobody is obliged to make.
    function test_I15_indexIsWrittenAtAllFourTerminalTransitions() public {
        uint8 UNRES = uint8(Moderation.IndexStatus.UNRESOLVED);

        // NO_TURNOUT
        uint256 a = _submitFresh(1);
        _matureAll();
        assertEq(_idxStatus(a), uint8(Moderation.IndexStatus.NONE), "invisible before the terminal");
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        assertEq(_idxStatus(a), UNRES, "NO_TURNOUT is visible in that transaction");

        // NO_REVEALS
        uint256 b = _submitFresh(2);
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(b, m, APPROVE);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeCommit(b);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeReveal(b);
        assertEq(_idxStatus(b), UNRES, "NO_REVEALS is visible");

        // NO_RANDOMNESS — and it RETAINS the published plurality beside the status.
        uint256 c = _submitFresh(3);
        _toTally(c, 2, 1);
        vm.roll(mod.caseInfo(c).phaseDeadline);
        mod.closeTally(c);
        vm.roll(uint256(mod.caseInfo(c).outcomeSeedBlock) + HORIZON + 1);
        mod.draw(c);
        assertEq(_idxStatus(c), UNRES, "NO_RANDOMNESS is visible");
        assertEq(_idxPlurality(c), APPROVE, "and RETAINS the published plurality");

        // FINALIZED
        uint256 d = _submitFresh(4);
        address[] memory who = _toTally(d, 3, 0);
        _rollToDraw(d);
        mod.draw(d);
        uint8 finalStatus = _idxStatus(d);
        assertTrue(
            finalStatus == uint8(Moderation.IndexStatus.APPROVED)
                || finalStatus == uint8(Moderation.IndexStatus.REJECTED),
            "FINALIZED is visible"
        );

        // ...and settlement changes NOTHING a reader sees (§8.1, I15).
        mod.claim(d, who[0]);
        assertEq(_idxStatus(d), finalStatus, "settlement NEVER touches the index");
        assertEq(_idxStatus(a), UNRES);
        assertEq(_idxStatus(b), UNRES);
        assertEq(_idxStatus(c), UNRES);
    }

    /// @dev §8.2 — the interim status is a VALUE, and `NONE = 0` is what makes the
    ///      other five mean anything.
    function test_s8_2_pluralityIsPublishedAtTallyAsAnInterimStatus() public {
        uint256 id = _submit();
        assertEq(_idxStatus(id), uint8(Moderation.IndexStatus.NONE), "nothing before TALLY");
        _toTally(id, 1, 4);
        assertEq(_idxStatus(id), uint8(Moderation.IndexStatus.PLURALITY_REJECT), "TALLY publishes it");
        assertEq(uint8(Moderation.IndexStatus.NONE), 0, "an unwritten slot is distinguishable");
    }

    /// @dev §4.2 — the plurality is a TOTAL function of a tally, ties included.
    ///      A tie is a Reject plurality: a bounded failure is correct, an unsafe
    ///      success is not.
    function test_s4_2_pluralityIsTotalAndATieIsReject() public {
        uint256 id = _submit();
        _toTally(id, 2, 2);
        assertEq(mod.caseInfo(id).plurality, REJECT, "a tie is a Reject plurality");
    }

    /// @dev ...and it decides who OWES, never who wins. At `A == R` the draw is
    ///      `f(0.5) = 0.5` and both outcomes remain reachable.
    function test_s4_2_pluralityIsNotATieBreakInTheVerdict() public {
        uint256 id = _submit();
        _toTally(id, 2, 2);
        uint256 approves;
        for (uint256 i; i < 200; ++i) {
            (uint8 v,) = mod.decideAt(id, keccak256(abi.encode("t", i)));
            if (v == APPROVE) approves++;
        }
        assertApproxEqAbs(approves, 100, 30, "f(0.5) = 0.5 despite a Reject plurality");
    }

    // =========================================================================
    // §5.3 — payment
    // =========================================================================

    /// MUTATION: bind `reveals1` to `revealsThisRound`.
    /// @dev §5.3's whole point. On the unchallenged path `revealsThisRound` still
    ///      holds round 0's count, so that binding makes `activated` the ENTIRE
    ///      reserve on a case nobody challenged and the submitter's refund zero.
    ///      Written as `(pooledApprove + pooledReject) - reveals0` it is zero on
    ///      that path by ARITHMETIC.
    function test_s5_3_reserveDoesNotActivateOnTheUnchallengedPath() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 0);
        uint128 reserve = mod.caseInfo(id).challengeReserve;
        assertGt(reserve, 0);

        _rollToDraw(id);
        mod.draw(id);

        // share is pot/W with NO activation.
        uint256 pot = mod.caseInfo(id).pot;
        assertEq(mod.shareOf(id), pot / 3, "the reserve did not activate");
        assertEq(mod.refundOwed(id), reserve, "the whole reserve returns to the submitter");
        who;
    }

    /// @dev And it DOES activate, in proportion, when round 1 brings reveals.
    function test_s5_3_reserveActivatesInProportionToRound1Turnout() public {
        uint256 id = _submit();
        _toTally(id, 4, 0); // reveals0 = 4
        address ch = _moderator(908);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        // Two round-1 voters.
        address r1 = _moderator(500);
        address r2 = _moderator(501);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, r1, APPROVE);
        _commit(id, r2, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        _reveal(id, r1, APPROVE);
        _reveal(id, r2, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + 1);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        uint256 expectedActivated = (uint256(c.pot) * 2) / 4; // reveals1 / reveals0
        if (expectedActivated > c.challengeReserve) expectedActivated = c.challengeReserve;
        assertEq(mod.refundOwed(id), uint256(c.challengeReserve) - expectedActivated, "unspent reserve refunds");
        assertGt(expectedActivated, 0, "round-1 turnout activated some of it");
    }

    /// MUTATION: let `pot` grow by the reserve at `challenge()` or at `closeTally`.
    /// @dev §4.1 — `pot` NEVER grows. The reserve is added at SETTLEMENT.
    function test_s4_1_potNeverGrows() public {
        uint256 id = _submit();
        uint128 pot0 = mod.caseInfo(id).pot;
        _toTally(id, 3, 1);
        assertEq(mod.caseInfo(id).pot, pot0, "unchanged through the tally");
        address ch = _moderator(909);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        assertEq(mod.caseInfo(id).pot, pot0, "unchanged by a challenge");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        assertEq(mod.caseInfo(id).pot, pot0, "unchanged by opening round 1");
    }

    /// @dev §5.3 — the remainder of an integer division goes to maintenance, never
    ///      to a moderator (I21).
    function test_s5_3_remainderGoesToMaintenanceNotToAModerator() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 0);
        _rollToDraw(id);
        mod.draw(id);

        uint256 share = mod.shareOf(id);
        uint256 P = mod.caseInfo(id).pot;
        assertGt(P - share * 3, 0, "this fixture leaves a remainder");
        for (uint256 i; i < 3; ++i) {
            uint256 b0 = reg.bondOf(who[i]);
            mod.claim(id, who[i]);
            assertEq(reg.bondOf(who[i]) - b0, share, "each coherent voter gets exactly `share`");
        }
    }

    // =========================================================================
    // §4.8 / I30 — a terminal fires exactly the obligations it meets
    // =========================================================================

    /// MUTATION: fire the non-reveal debit on every terminal (quantify over
    ///           terminals rather than over "a reveal phase opened").
    /// @dev I25. In `NO_TURNOUT` the reveal phase never opened, so every committer
    ///      is vacuously a non-revealer — and debiting them prices a market failure
    ///      to the people who showed up for it, in the one row the same table calls
    ///      unsteerable and refunds in full.
    ///
    ///      `NO_TURNOUT` requires an EMPTY round, so no claim exists to settle; the
    ///      condition is asserted at the reason that CAN carry committers.
    function test_I25_nonRevealDebitFiresInNoRevealsAndNotInNoTurnout() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id); // the reveal phase OPENS
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id); // ...and nobody revealed
        assertEq(mod.caseInfo(id).unresolvedReason, uint8(Moderation.Reason.NO_REVEALS));

        uint256 b0 = reg.bondOf(m);
        mod.claim(id, m);
        assertEq(b0 - reg.bondOf(m), REVEAL_BOND, "debited: a reveal phase opened");
        assertEq(reg.liabilitiesOf(m), 0, "and the claim is discharged");
    }

    /// MUTATION: fire the incoherence debit in `NO_REVEALS`.
    /// @dev Its condition is "a settled side exists", which is `NO_RANDOMNESS` and
    ///      the drawn terminals alone. There is no tally to be incoherent with.
    function test_I30_incoherenceDebitFiresOnNoRandomnessAgainstThePlurality() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1); // plurality Approve
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON + 1);
        mod.draw(id);
        assertEq(mod.caseInfo(id).unresolvedReason, uint8(Moderation.Reason.NO_RANDOMNESS));

        // The lone Reject revealer is on the losing side of the POOLED plurality.
        address loser = who[3];
        uint256 b0 = reg.bondOf(loser);
        mod.claim(id, loser);
        assertEq(b0 - reg.bondOf(loser), PENALTY_D, "debited d against the settled side");

        // An Approve revealer is on the winning side: no debit, and NO payment,
        // because payment requires a verdict.
        address winner = who[0];
        uint256 w0 = reg.bondOf(winner);
        mod.claim(id, winner);
        assertEq(reg.bondOf(winner), w0, "no debit and no payment in NO_RANDOMNESS");
    }

    /// MUTATION: pay `share` or credit reputation in an `UNRESOLVED` terminal.
    /// @dev Payment, reputation, the listing and the reserve activation all require
    ///      A VERDICT WAS DRAWN. None of the three `UNRESOLVED` rows draws one.
    function test_I30_noVerdictMeansNoPaymentNoReputationNoActivation() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON + 1);
        mod.draw(id);

        uint256 t0 = reg.trackOf(who[0]);
        mod.claim(id, who[0]);
        assertEq(reg.trackOf(who[0]), t0, "no reputation credited");
        assertEq(mod.shareOf(id), 0, "no share exists");
        assertEq(mod.refundOwed(id), uint256(mod.caseInfo(id).pot) + mod.caseInfo(id).challengeReserve,
            "pot AND reserve refund in full - the reserve never activated");
    }

    /// MUTATION: make the `CHALLENGE_BOND` debit conditional on anything.
    /// @dev §4.6 — debited UNCONDITIONALLY. There is no branch, so there is no
    ///      test, so there is nothing for a challenger to steer.
    function test_s4_6_challengeBondIsDebitedUnconditionally() public {
        // The plurality is upheld.
        uint256 a = _submit();
        _toTally(a, 4, 0);
        address ch1 = _moderator(910);
        _matureAll();
        vm.prank(ch1);
        mod.challenge(a);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeTally(a);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeReveal(a);
        vm.roll(uint256(mod.caseInfo(a).outcomeSeedBlock) + 1);
        mod.draw(a);

        uint256 b0 = reg.bondOf(ch1);
        mod.claimChallenge(a);
        assertEq(b0 - reg.bondOf(ch1), CHALLENGE_BOND, "debited on the drawn path");
        assertEq(reg.liabilitiesOf(ch1), 0, "and discharged");
    }

    /// @dev ...including in `NO_RANDOMNESS`, which is a terminal past `TALLY`.
    function test_s4_6_challengeBondIsDebitedInNoRandomnessToo() public {
        uint256 id = _submit();
        _toTally(id, 2, 1);
        address ch = _moderator(911);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON + 1);
        mod.draw(id);

        uint256 b0 = reg.bondOf(ch);
        mod.claimChallenge(id);
        assertEq(b0 - reg.bondOf(ch), CHALLENGE_BOND);
    }

    /// MUTATION: skip `discharge` on any settlement branch.
    /// @dev I20/I32 — `Moderation` must discharge EVERY claim it creates on EVERY
    ///      terminal, including the `UNRESOLVED` rows. A claim left open is a
    ///      moderator's liability standing forever, and `withdraw` requires
    ///      `liabilities == 0`.
    function test_I20_everyTerminalDischargesEveryClaimItCreated() public {
        // NO_REVEALS: a committer who never revealed.
        uint256 a = _submitFresh(31);
        address m1 = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(a, m1, APPROVE);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeReveal(a);
        assertEq(reg.liabilitiesOf(m1), LAMBDA);
        mod.claim(a, m1);
        assertEq(reg.liabilitiesOf(m1), 0, "NO_REVEALS discharges");

        // FINALIZED: coherent and incoherent alike.
        uint256 b = _submitFresh(32);
        address[] memory who = _toTally(b, 2, 2);
        _rollToDraw(b);
        mod.draw(b);
        for (uint256 i; i < who.length; ++i) {
            mod.claim(b, who[i]);
            assertEq(reg.liabilitiesOf(who[i]), 0, "FINALIZED discharges every participant");
        }
    }

    /// @dev And the discharge is what lets a moderator actually leave (I13).
    function test_I20_aSettledModeratorCanWithdraw() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 1, 0);
        _rollToDraw(id);
        mod.draw(id);
        mod.claim(id, who[0]);

        vm.prank(who[0]);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(who[0]);
        reg.withdraw();
        assertTrue(reg.stateOf(who[0]) == StakeRegistry.State.NONE);
    }

    // =========================================================================
    // §5.5 — settlement is pulled per moderator
    // =========================================================================

    /// @dev Permissionless, order-independent, and it may never complete. There is
    ///      no case-level `SETTLED` state to reach.
    function test_s5_5_settlementIsPermissionlessAndOrderIndependent() public {
        uint256 a = _submit();
        address[] memory who = _toTally(a, 3, 1);
        _rollToDraw(a);
        mod.draw(a);

        // A stranger settles someone else's claim, in an arbitrary order.
        vm.prank(poker);
        mod.claim(a, who[2]);
        vm.prank(poker);
        mod.claim(a, who[0]);
        assertTrue(mod.isVoteSettled(a, who[2]));
        assertTrue(mod.isVoteSettled(a, who[0]));
        assertFalse(mod.isVoteSettled(a, who[1]), "and it may simply never complete");

        vm.prank(poker);
        vm.expectRevert(Moderation.AlreadySettled.selector);
        mod.claim(a, who[0]);
    }

    /// @dev A case reaching a terminal is what a reader waits for, never settlement.
    function test_s8_1_theIndexIsReadableBeforeAnyoneHasSettled() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 0);
        _rollToDraw(id);
        mod.draw(id);
        uint8 s = _idxStatus(id);
        assertTrue(s == uint8(Moderation.IndexStatus.APPROVED) || s == uint8(Moderation.IndexStatus.REJECTED));
        assertFalse(mod.isVoteSettled(id, who[0]), "nobody has settled");
    }

    // =========================================================================
    // §8.4 — claim keys and retry
    // =========================================================================

    /// MUTATION: reserve the key on `NO_TURNOUT`.
    /// @dev No draw occurred and nobody could have caused it, so the retry is free.
    function test_s8_4_noTurnoutReleasesTheKey() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        assertEq(uint8(mod.reservationOf(mod.caseInfo(id).claimKey)), uint8(Moderation.Reservation.FREE));

        vm.prank(submitter);
        uint256 again = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
        assertGt(again, 0, "freely resubmittable");
    }

    /// MUTATION: release the key on `NO_RANDOMNESS`, or reserve it for a cooldown.
    /// @dev I26 — once a claim has been TALLIED, no reachable terminal releases its
    ///      key. `NO_RANDOMNESS` is tallied by definition, which is the whole
    ///      content of §4.8's distinction between it and the other two reasons.
    ///      §8.4's row contradicted the invariant written to prevent exactly this.
    function test_I26_noRandomnessReservesTheKeyPermanently() public {
        uint256 id = _submit();
        _toTally(id, 3, 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON + 1);
        mod.draw(id);

        assertEq(uint8(mod.reservationOf(mod.caseInfo(id).claimKey)), uint8(Moderation.Reservation.PERMANENT));
        vm.warp(block.timestamp + 3650 days);
        vm.prank(submitter);
        vm.expectRevert(Moderation.KeyReserved.selector);
        mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    /// @dev `REJECTED` is permanently reserved; only an explicit re-review reaches
    ///      it.
    function test_s8_4_rejectedIsPermanentlyReserved() public {
        uint256 id = _submit();
        _toTally(id, 0, 6); // overwhelming Reject
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.REJECTED), "fixture: this tally draws REJECTED");

        vm.warp(block.timestamp + 3650 days);
        vm.prank(submitter);
        vm.expectRevert(Moderation.KeyReserved.selector);
        mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    /// MUTATION: refund the pot on `NO_REVEALS` instead of carrying it.
    /// @dev §8.4 — reserved for `RETRY_COOLDOWN`, then the pot carries forward with
    ///      NO FRESH FEE. (§4.8's value-flow block says every reason refunds the pot
    ///      in full; the two contradict, and this follows §8.4 — see the report.)
    function test_s8_4_noRevealsReservesForCooldownAndCarriesThePot() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);

        bytes32 key = mod.caseInfo(id).claimKey;
        uint256 carried = mod.carriedPot(key);
        assertEq(carried, mod.caseInfo(id).pot, "the pot carries, it is not refunded");
        assertEq(uint8(mod.reservationOf(key)), uint8(Moderation.Reservation.COOLDOWN));

        vm.prank(submitter);
        vm.expectRevert(Moderation.KeyReserved.selector);
        mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(submitter);
        uint256 retry = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
        assertGt(mod.caseInfo(retry).pot, carried, "the carried pot is added to the new one");
    }

    /// MUTATION: drop the `tallied` branch from `_toUnresolved`.
    /// @dev I26 — once a claim has been TALLIED, no reachable terminal releases its
    ///      key. §8.4's table is written for a FIRST opening: §8.5 introduced a
    ///      second one and the table was not revisited for it, so `NO_TURNOUT`'s
    ///      "not reserved, free retry" row would release the key of a claim a
    ///      previous opening had tallied and permanently reserved. Reachable in
    ///      three transactions: reject a claim, reopen it, let the re-review draw
    ///      no commits.
    function test_I26_aReReviewCannotReleaseAPreviouslyTalliedKey() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.REJECTED));
        bytes32 key = mod.caseInfo(id).claimKey;
        assertEq(uint8(mod.reservationOf(key)), uint8(Moderation.Reservation.PERMANENT));

        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }
        vm.prank(submitter);
        mod.reopen(id, FEE);

        // The re-review attracts nobody, so it ends NO_TURNOUT.
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        assertEq(mod.caseInfo(id).unresolvedReason, uint8(Moderation.Reason.NO_TURNOUT));

        assertEq(uint8(mod.reservationOf(key)), uint8(Moderation.Reservation.PERMANENT),
            "a tallied claim's key is never released");
        vm.prank(submitter);
        vm.expectRevert(Moderation.KeyReserved.selector);
        mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }

    /// @dev The same guard must not over-fire: a FIRST opening that reaches
    ///      `NO_TURNOUT` has an empty pooled tally, is not tallied, and retries
    ///      freely — which is the row's whole point.
    function test_I26_aFirstOpeningNoTurnoutStillRetriesFreely() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        assertEq(mod.caseInfo(id).pooledApprove + mod.caseInfo(id).pooledReject, 0, "never tallied");
        assertEq(uint8(mod.reservationOf(mod.caseInfo(id).claimKey)), uint8(Moderation.Reservation.FREE));
    }

    /// @dev `policyVersion` is deliberately absent from the key, so a ruleset change
    ///      is not a scheduled amnesty an attacker can wait for.
    function test_s8_4_keyIsInvariantUnderAParameterChange() public {
        uint256 id = _submit();
        bytes32 k0 = mod.caseInfo(id).claimKey;
        vm.prank(gov);
        idx.proposeWriter(address(mod), true);
        (,, uint256 wEta,) = idx.pendingWriterProposal();
        vm.warp(wEta);
        vm.prank(gov);
        idx.executeWriter();

        vm.prank(gov);
        mod.applyParams(_params()); // a new version
        assertEq(mod.claimKeyOf(keccak256("content"), keccak256("meta"), topics), k0, "key unmoved");
    }

    // =========================================================================
    // I27 — parameters are pinned at submission
    // =========================================================================

    /// MUTATION: read `paramBlocks[paramsVersion]` (the live block) at settlement.
    /// @dev Every debit is computed from the block in force at SUBMISSION. A case
    ///      pinned at `LAMBDA = 100` whose settlement debits a governance-raised 150
    ///      drives `bond` negative, and §5.4 mandates revert-not-clamp — so that one
    ///      moderator's presence would revert settlement for every other voter.
    function test_I27_debitsUseThePinnedParametersNotTheLiveOnes() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id); // NO_REVEALS

        // Governance raises the reveal bond tenfold AFTER the case was submitted.
        Moderation.Params memory p2 = _params();
        p2.revealBond = REVEAL_BOND * 10;
        vm.prank(gov);
        mod.applyParams(p2);

        uint256 b0 = reg.bondOf(m);
        mod.claim(id, m);
        assertEq(b0 - reg.bondOf(m), REVEAL_BOND, "the PINNED bond, not the live one");
        assertEq(mod.caseInfo(id).paramsVersion, 1);
    }

    // =========================================================================
    // §10 / I31 — the one hard bound on BLOCK_TIME
    // =========================================================================

    /// MUTATION: drop the `commitBlocks <= seedLag + blockhashHorizon` check.
    /// @dev §3.1 — a governance change below the bound does not fail loudly; it
    ///      re-points the tail of every commit window at a seed block that has
    ///      expired. `1200 / 258 = 4.651 s`, 18 blocks of margin at 5 s.
    function test_I31_commitWindowMayNotOutrunTheSeedHorizon() public {
        Moderation.Params memory p = _params();
        p.blockTime = 4; // 1200/4 = 300 blocks > 258
        vm.prank(gov);
        vm.expectRevert(Moderation.CommitWindowExceedsSeedHorizon.selector);
        mod.applyParams(p);

        p.blockTime = 5; // 240 blocks <= 258
        vm.prank(gov);
        mod.applyParams(p);
    }

    /// @dev The bound is enforced; the VALUE is not. 4.651 s is the floor and the
    ///      contract accepts anything at or above it.
    function test_I31_theBoundIsEnforcedAndTheValueIsNot() public {
        Moderation.Params memory p = _params();
        p.blockTime = 5;
        vm.prank(gov);
        mod.applyParams(p);
        p.blockTime = 12;
        vm.prank(gov);
        mod.applyParams(p);
    }

    // =========================================================================
    // §8.5 — re-review
    // =========================================================================

    /// MUTATION: draw fresh entropy on a reopened case.
    /// @dev There is no re-roll, EVER, for the life of a claim. A re-review that
    ///      attracts no votes returns the identical verdict — which is the property
    ///      §4.5 spent the whole architecture on and which a fresh-cohort retry
    ///      would have handed back.
    function test_s8_5_reopenReusesTheStoredEntropyAndCannotReRoll() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        Moderation.Case memory c0 = mod.caseInfo(id);
        assertEq(c0.terminal, uint8(Moderation.Terminal.REJECTED), "fixture: this tally draws REJECTED");

        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }

        vm.prank(submitter);
        mod.reopen(id, FEE);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT));
        assertEq(mod.caseInfo(id).outcomeEntropy, c0.outcomeEntropy, "same u");
        assertEq(mod.caseInfo(id).pooledReject, 5, "the pooled tally CARRIES");

        // Nobody votes. The verdict must be identical.
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id); // NO_TURNOUT: an empty reopening
        assertEq(mod.caseInfo(id).unresolvedReason, uint8(Moderation.Reason.NO_TURNOUT));

        (uint8 v,) = mod.decideAt(id, c0.outcomeEntropy);
        assertEq(v, c0.verdict, "an unchanged tally yields an identical verdict");
    }

    /// MUTATION: allow `reopen` while a vote claim is still open.
    /// @dev §8.5 says prior voters "are already settled". Settlement is pull-based
    ///      and may never complete, so this REQUIRES what §8.5 assumes — otherwise a
    ///      prior voter is stranded between two terminals with no rule saying which
    ///      one judges them. See the report.
    function test_s8_5_reopenRequiresPriorVotersToBeSettled() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.REJECTED), "fixture: this tally draws REJECTED");

        vm.prank(submitter);
        vm.expectRevert(Moderation.ClaimsOutstanding.selector);
        mod.reopen(id, FEE);

        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }
        vm.prank(submitter);
        mod.reopen(id, FEE); // now permitted
    }

    /// @dev A re-review is not an action type: it reopens the `LIST` claim under
    ///      the SAME key. A different key would make the permanent reservation
    ///      worth one byte.
    function test_s8_5_reopenKeepsTheSameClaimKey() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.REJECTED), "fixture: this tally draws REJECTED");
        bytes32 k = mod.caseInfo(id).claimKey;
        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }
        vm.prank(submitter);
        mod.reopen(id, FEE);
        assertEq(mod.caseInfo(id).claimKey, k);
    }

    /// @dev Only `REJECTED` and `NO_RANDOMNESS` are reopenable — the two terminals
    ///      §8.4 makes a re-review the sole recourse from.
    function test_s8_5_onlyPermanentlyReservedTerminalsReopen() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id); // NO_TURNOUT — retries freely, so no re-review
        vm.prank(submitter);
        vm.expectRevert(Moderation.NotReopenable.selector);
        mod.reopen(id, FEE);
    }

    // =========================================================================
    // Mutation-campaign gaps: tests added after survivors were reported
    // =========================================================================

    /// MUTATION M17: key the one-vote allowance on `revealedVote` instead of
    ///               `commitments`.
    /// @dev §3.4's attack verbatim, and trap 1 of the work order: commit in round 0,
    ///      ABANDON for the price of `REVEAL_BOND`, and commit again in round 1 with
    ///      the round-0 tally in hand. The earlier I3 test used a moderator who had
    ///      revealed, so the mutated check still blocked them and the mutation
    ///      survived. The allowance is consumed by the COMMIT.
    function test_I3_anAbandonedRound0CommitterCannotCommitInRound1() public {
        uint256 id = _submit();
        address abandoner = _moderator(1);
        address other = _moderator(2);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, abandoner, APPROVE);
        _commit(id, other, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        _reveal(id, other, APPROVE); // `abandoner` never reveals
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        assertEq(mod.revealOf(id, abandoner), 0, "fixture: they abandoned");

        address ch = _moderator(950);
        _matureAll();
        vm.prank(ch);
        mod.challenge(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(block.number + SEED_LAG + 1);

        Moderation.Case memory c = mod.caseInfo(id);
        bytes32 h = mod.commitHash(id, c.round, c.paramsVersion, abandoner, REJECT, _salt(abandoner));
        vm.prank(abandoner);
        vm.expectRevert(Moderation.AlreadyCommitted.selector);
        mod.commit(id, h);
    }

    /// MUTATION M16: drop `block.number >= phaseDeadline` from `commit`.
    /// @dev No phase closes itself. Between the deadline and whoever calls
    ///      `closeCommit` there is an open-ended window, and without this guard a
    ///      late committer can enter it — extending the commit phase for as long as
    ///      nobody pokes the transition.
    function test_s4_3_commitIsRefusedAtAndAfterTheDeadline() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);

        Moderation.Case memory c = mod.caseInfo(id);
        bytes32 h = mod.commitHash(id, c.round, c.paramsVersion, m, APPROVE, _salt(m));

        vm.roll(c.phaseDeadline); // exactly at the deadline
        vm.prank(m);
        vm.expectRevert(Moderation.DeadlinePassed.selector);
        mod.commit(id, h);

        vm.roll(uint256(c.phaseDeadline) + 50); // and well past it, still in COMMIT
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT), "nobody has poked the close");
        vm.prank(m);
        vm.expectRevert(Moderation.DeadlinePassed.selector);
        mod.commit(id, h);
    }

    /// MUTATION M8: set `unanimousDraw` on any 2-of-3 draw.
    /// @dev §8.3 reads this flag and nothing else reads `u` back. The entropy is
    ///      chosen with `vm.setBlockhash` so both a split and a unanimous draw are
    ///      exercised deterministically.
    function test_s8_3_unanimousDrawRecordsWhetherAllThreeTicketsAgreed() public {
        bool sawSplit;
        bool sawUnanimous;
        for (uint256 k; k < 12 && !(sawSplit && sawUnanimous); ++k) {
            uint256 id = _submitFresh(700 + k);
            _toTally(id, 3, 3); // â = 1/2: the split-likeliest tally
            vm.roll(mod.caseInfo(id).phaseDeadline);
            mod.closeTally(id);

            uint256 sb = mod.caseInfo(id).outcomeSeedBlock;
            vm.roll(sb + 1);
            vm.setBlockhash(sb, keccak256(abi.encode("draw", k)));
            mod.draw(id);

            Moderation.Case memory c = mod.caseInfo(id);
            (, uint8 tickets) = mod.decideAt(id, c.outcomeEntropy);
            assertEq(c.unanimousDraw, tickets == 0 || tickets == 3, "the flag is 3/3 or 0/3, not a majority");
            if (tickets == 1 || tickets == 2) sawSplit = true;
            else sawUnanimous = true;
        }
        assertTrue(sawSplit, "a split draw was exercised");
        assertTrue(sawUnanimous, "and a unanimous one");
    }

    /// MUTATION M6: delete the stored-entropy shortcut from `draw`.
    /// @dev The earlier test called `decideAt` with the entropy passed in, which
    ///      proves `_decide` is pure but never drives `draw` down the stored-entropy
    ///      path — and the reopen test ended at `NO_TURNOUT` before reaching a
    ///      second draw. A re-opened case's `outcomeSeedBlock` is long past, so
    ///      re-reading `blockhash` sends it to `NO_RANDOMNESS` instead.
    function test_s8_5_aReopenedCaseDrawsFromStoredEntropyWithNoLiveBlockhash() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        Moderation.Case memory c0 = mod.caseInfo(id);
        assertEq(c0.terminal, uint8(Moderation.Terminal.REJECTED));
        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }

        vm.prank(submitter);
        mod.reopen(id, FEE);

        // A new cohort turns up and votes the other way.
        address[] memory fresh = new address[](9);
        for (uint256 i; i < 9; ++i) {
            fresh[i] = _moderator(600 + i);
        }
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < 9; ++i) {
            _commit(id, fresh[i], APPROVE);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 9; ++i) {
            _reveal(id, fresh[i], APPROVE);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        // The outcome seed block is far behind us and unreadable.
        assertGt(block.number, uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON, "the hash is long gone");

        mod.draw(id);
        Moderation.Case memory c1 = mod.caseInfo(id);
        assertTrue(
            c1.terminal == uint8(Moderation.Terminal.APPROVED) || c1.terminal == uint8(Moderation.Terminal.REJECTED),
            "the re-review DRAWS - it does not expire"
        );
        assertEq(c1.outcomeEntropy, c0.outcomeEntropy, "and on the same word as the first draw");
        assertEq(c1.pooledApprove, 9, "the new votes pooled with the old");
        assertEq(c1.pooledReject, 5);
    }

    /// @dev M7 is an EQUIVALENT mutant, and this is the property that makes it one.
    ///      §4.5 says `DRAW` is unreachable with an empty tally, so an `N > 0` guard
    ///      inside `draw` can never fire — which is why adding it changes no
    ///      observable behaviour and why no test can catch it. The guard is
    ///      nonetheless wrong to add: a revert in `DRAW` is unrecoverable, so it
    ///      would be a latent trap the day a new row routes an empty tally there.
    ///      What is testable is the reachability claim itself.
    function test_s4_5_drawIsUnreachableWithAnEmptyTally() public {
        // Round 0 with no reveals goes to NO_REVEALS, never to DRAW.
        uint256 a = _submitFresh(801);
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(a, m, APPROVE);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeReveal(a);
        assertEq(mod.caseInfo(a).phase, uint8(Moderation.Phase.UNRESOLVED));
        assertEq(mod.caseInfo(a).unresolvedReason, uint8(Moderation.Reason.NO_REVEALS));

        // The only two rows entering DRAW both require a non-empty pooled tally:
        // TALLY -> DRAW is downstream of the `pooled >= 1` guard, and
        // REVEAL(r=1) -> DRAW is downstream of TALLY.
        uint256 b = _submitFresh(802);
        _toTally(b, 1, 0);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeTally(b);
        assertEq(mod.caseInfo(b).phase, uint8(Moderation.Phase.DRAW));
        assertGe(uint256(mod.caseInfo(b).pooledApprove) + mod.caseInfo(b).pooledReject, 1, "DRAW always has a tally");
    }

    /// @dev M22 and M24 are EQUIVALENT mutants for the same reason: the terminals
    ///      their conditions would newly admit cannot produce a settleable claim.
    ///      `NO_TURNOUT` requires an empty round, so no claim exists to settle;
    ///      `NO_REVEALS` requires `pooled == 0`, so no settler has a revealed vote
    ///      and the incoherence branch is unreachable there. Asserted rather than
    ///      argued.
    function test_I30_theUnreachableSettlementBranchesAreUnreachable() public {
        // NO_TURNOUT: nobody committed, so `claim` has nothing to settle.
        uint256 a = _submitFresh(811);
        _matureAll();
        vm.roll(mod.caseInfo(a).phaseDeadline);
        mod.closeCommit(a);
        assertEq(mod.caseInfo(a).commitsThisRound, 0, "an EMPTY round");
        address nobody = _moderator(1);
        vm.expectRevert(Moderation.NotCommitted.selector);
        mod.claim(a, nobody);

        // NO_REVEALS: every committer is a non-revealer, so no settler reaches the
        // incoherence branch.
        uint256 b = _submitFresh(812);
        address m = nobody;
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(b, m, APPROVE);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeCommit(b);
        vm.roll(mod.caseInfo(b).phaseDeadline);
        mod.closeReveal(b);
        assertEq(uint256(mod.caseInfo(b).pooledApprove) + mod.caseInfo(b).pooledReject, 0);
        assertEq(mod.revealOf(b, m), 0, "no revealed vote exists to be judged incoherent");
    }

    // =========================================================================
    // Value conservation
    // =========================================================================

    /// @dev Every unit the contract takes in leaves by a named route: shares to
    ///      moderators through the registry, bounties to pokers, refunds to the
    ///      submitter, and maintenance retained. Nothing is stranded and nothing
    ///      reaches a moderator who is not owed it (I14, I21).
    function test_valueConservation_acrossAFullFinalizedCase() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1);
        uint256 held = token.balanceOf(address(mod));
        assertEq(held, FEE, "the whole fee is held");

        _rollToDraw(id);
        vm.prank(poker);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        // §4.8's rule: paid where the transition was PERFORMED. The draw happened,
        // and finalization with it, so both bounties go to whoever poked it.
        assertEq(
            token.balanceOf(poker),
            (FEE * 50) / 10_000 + (FEE * 100) / 10_000,
            "DRAW_BOUNTY + CLAIM_BOUNTY, to the poker"
        );
        assertEq(c.drawBounty, 0, "and nothing is left owing on the case");
        assertEq(c.claimBounty, 0);
        // Unchallenged, so §5.3 activates none of the reserve: the refund is the
        // reserve alone, with no bounty folded into it.
        assertEq(mod.refundOwed(id), uint256(c.challengeReserve), "no bounty in the refund");

        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }
        mod.withdrawRefund(id);

        uint256 remaining = token.balanceOf(address(mod));
        assertEq(remaining, mod.maintenanceAccrued() + (uint256(c.pot) - mod.shareOf(id) * c.pooledApprove),
            "what is left is exactly maintenance plus the division remainder");
    }

    /// MUTATION: retain `DRAW_BOUNTY` on the pre-`TALLY` terminals instead of
    ///           refunding it.
    /// @dev §4.8, as corrected at `6489bfd`: a bounty is refunded where the
    ///      transition it pays for CANNOT OCCUR, and paid where that transition was
    ///      performed. `DRAW` is unreachable from `NO_TURNOUT` and `NO_REVEALS`, so
    ///      retaining the draw bounty charged the submitter for a transition that
    ///      cannot happen — on rows the same section calls unsteerable.
    function test_valueConservation_noTurnoutRefundsPotReserveAndDrawBounty() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);

        Moderation.Case memory c = mod.caseInfo(id);
        uint256 drawB = (FEE * 50) / 10_000;
        uint256 claimB = (FEE * 100) / 10_000;

        assertEq(
            mod.refundOwed(id),
            uint256(c.pot) + c.challengeReserve + drawB,
            "pot + reserve + DRAW_BOUNTY: the draw is unreachable from here"
        );
        assertEq(c.drawBounty, 0, "moved to the refund, not retained");
        assertEq(c.claimBounty, 0, "and CLAIM_BOUNTY was retained - open in s10");
        assertEq(mod.maintenanceAccrued(), (FEE * 1000) / 10_000 + claimB, "maintenance + the retained claim bounty");

        uint256 b0 = token.balanceOf(submitter);
        mod.withdrawRefund(id);
        assertEq(token.balanceOf(submitter) - b0, uint256(c.pot) + c.challengeReserve + drawB);
        assertEq(token.balanceOf(address(mod)), mod.maintenanceAccrued(), "nothing stranded");
    }

    /// @dev The same rule on `NO_REVEALS`, where the POT carries rather than
    ///      refunding (§8.4) but the draw bounty still returns.
    function test_valueConservation_noRevealsCarriesThePotAndRefundsTheDrawBounty() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);

        Moderation.Case memory c = mod.caseInfo(id);
        uint256 drawB = (FEE * 50) / 10_000;
        assertEq(mod.carriedPot(c.claimKey), c.pot, "the pot carries, per s8.4");
        assertEq(
            mod.refundOwed(id),
            uint256(c.challengeReserve) + drawB,
            "reserve + DRAW_BOUNTY, and NOT the pot"
        );
        assertEq(c.drawBounty, 0);
    }

    /// @dev And `NO_RANDOMNESS` PAYS it, to whoever poked the expiry — so nothing
    ///      remains to refund. This is the row that makes "refund whatever remains"
    ///      the whole rule rather than a per-reason branch.
    function test_valueConservation_noRandomnessPaysTheDrawBountyToThePoker() public {
        uint256 id = _submit();
        _toTally(id, 2, 1);
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);
        vm.roll(uint256(mod.caseInfo(id).outcomeSeedBlock) + HORIZON + 1);

        uint256 p0 = token.balanceOf(poker);
        vm.prank(poker);
        mod.draw(id);

        Moderation.Case memory c = mod.caseInfo(id);
        uint256 drawB = (FEE * 50) / 10_000;
        assertEq(token.balanceOf(poker) - p0, drawB, "paid, because the transition WAS performed");
        assertEq(c.drawBounty, 0);
        assertEq(
            mod.refundOwed(id),
            uint256(c.pot) + c.challengeReserve,
            "pot + reserve only: the draw bounty was earned, not refunded"
        );
    }

    // =========================================================================
    // §5.6 / §5.6.1 — the sweep into the one reserve
    // =========================================================================

    /// MUTATION: zero `maintenanceAccrued` without forwarding it.
    /// MUTATION: forward without zeroing (a second sweep would double-spend).
    /// @dev §5.6 makes the registry's reserve the ONE pool; this contract's
    ///      accumulator is a staging area, not a pool.
    function test_s5_6_sweepForwardsTheAccrualIntoTheOneReserve() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id); // NO_TURNOUT accrues maintenance + the claim bounty

        uint256 accrued = mod.maintenanceAccrued();
        assertGt(accrued, 0, "fixture: something accrued");
        uint256 reserve0 = reg.maintenanceReserve();
        uint256 modBal0 = token.balanceOf(address(mod));

        vm.prank(poker); // permissionless
        uint256 swept = mod.sweepMaintenance();

        assertEq(swept, accrued);
        assertEq(mod.maintenanceAccrued(), 0, "the accumulator is zeroed");
        assertEq(reg.maintenanceReserve(), reserve0 + accrued, "and the reserve grew by exactly that");
        assertEq(token.balanceOf(address(mod)), modBal0 - accrued, "value actually moved");
        assertTrue(reg.solvent(), "the registry stays solvent");
        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets(), "and exact");
    }

    /// @dev A sweep with nothing accrued is a NO-OP, not a revert — a permissionless
    ///      housekeeping call must not fail on the common case.
    function test_s5_6_sweepWithNothingAccruedIsANoOp() public {
        assertEq(mod.maintenanceAccrued(), 0);
        vm.prank(poker);
        assertEq(mod.sweepMaintenance(), 0);

        // ...and a second sweep straight after a real one is also a no-op.
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        vm.prank(poker);
        mod.sweepMaintenance();
        uint256 reserve = reg.maintenanceReserve();
        vm.prank(poker);
        assertEq(mod.sweepMaintenance(), 0, "nothing left to forward");
        assertEq(reg.maintenanceReserve(), reserve, "and nothing double-counted");
    }

    /// @dev End to end, and the point of the whole order: a FEE paid into
    ///      `Moderation` and a DEBIT taken in the registry both reach ONE reserve,
    ///      and both can leave it by the one exit.
    function test_s5_6_feeAndDebitReachOneReserveAndBothCanLeave() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1);
        _rollToDraw(id);
        mod.draw(id);

        // The incoherent voter's debit goes to the registry's reserve directly.
        uint8 verdict = mod.caseInfo(id).verdict;
        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }
        uint256 fromDebits = reg.maintenanceReserve();
        assertGt(fromDebits, 0, "a debit reached the reserve without a sweep");

        // The fee's maintenance component and the division remainder are staged in
        // Moderation until swept.
        uint256 fromFees = mod.maintenanceAccrued();
        assertGt(fromFees, 0, "and the fee side is staged");

        vm.prank(poker);
        mod.sweepMaintenance();
        assertEq(reg.maintenanceReserve(), fromDebits + fromFees, "ONE pool, both inflows");
        assertEq(mod.maintenanceAccrued(), 0);

        // Both leave by the one exit.
        uint256 total = reg.maintenanceReserve();
        uint256 stakeBond = reg.totalStake() + reg.totalBond();
        vm.prank(gov);
        reg.proposeMaintenanceWithdrawal(treasury, total);
        (,, uint256 eta,) = reg.pendingMaintenanceWithdrawal();
        vm.warp(eta);
        vm.prank(gov);
        reg.executeMaintenanceWithdrawal();

        assertEq(token.balanceOf(treasury), total, "fee revenue and debit revenue, together");
        assertEq(reg.maintenanceReserve(), 0);
        assertEq(reg.totalStake() + reg.totalBond(), stakeBond, "and no moderator paid for it");
        assertTrue(reg.solvent());
        verdict;
    }

    /// @dev The sweep needs no capability, and holds none it could misuse: it is the
    ///      same permissionless deposit anyone may make.
    function test_s5_6_sweepGrantsModerationNoNewPower() public {
        uint256 id = _submit();
        _matureAll();
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);

        uint256 stakeBond = reg.totalStake() + reg.totalBond();
        vm.prank(poker);
        mod.sweepMaintenance();
        assertEq(reg.totalStake() + reg.totalBond(), stakeBond, "a deposit moves no moderator's balance");
    }

    // =========================================================================
    // §8.3 — the openQuestions wiring (M2.9)
    // =========================================================================

    /// MUTATION: drop the `openQuestion` loop from `reopen`.
    /// MUTATION: drop the `closeQuestion` loop from `_writeIndex`.
    /// @dev §8.3's live half. A re-review is an open question against the entries
    ///      this claim already wrote, and `SUPER_SAFE` must stop reading true while
    ///      it stands — then resume at the re-review's terminal, not before.
    function test_s8_3_aReReviewOpensAQuestionAndItsTerminalClosesIt() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 0, 5);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.REJECTED));
        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }

        assertEq(_idxQuestions(id), 0, "no question stands yet");

        vm.prank(submitter);
        mod.reopen(id, FEE);
        assertEq(_idxQuestions(id), 1, "the re-review opened one against this entry");

        // A fresh cohort: I3 bars the first opening's voters from voting again.
        address[] memory fresh = new address[](3);
        for (uint256 i; i < 3; ++i) {
            fresh[i] = _moderator(770 + i);
        }
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        for (uint256 i; i < 3; ++i) {
            _commit(id, fresh[i], APPROVE);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeCommit(id);
        for (uint256 i; i < 3; ++i) {
            _reveal(id, fresh[i], APPROVE);
        }
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeReveal(id);

        // The interim TALLY write is NOT a terminal and must not close it.
        assertEq(_idxQuestions(id), 1, "TALLY is not a terminal - it stays open");
        vm.roll(mod.caseInfo(id).phaseDeadline);
        mod.closeTally(id);

        _rollToDraw(id);
        mod.draw(id);
        assertEq(_idxQuestions(id), 0, "the terminal closes it");
    }

    /// @dev Why mutation M53 is EQUIVALENT, and what keeps it that way. `strict`
    ///      can only be true when `verdict == APPROVE` (`_strict` requires it), and
    ///      no path writes a non-`APPROVED` status while that holds: an `APPROVED`
    ///      case is not reopenable at all — §8.4 makes re-review the recourse from
    ///      `REJECTED` and `NO_RANDOMNESS`, and a listed entry's recourse is a
    ///      REMOVAL case, which is a different claim key. So the `s == APPROVED`
    ///      guard is redundancy, not a rule, and this is the reachability fact it
    ///      rests on.
    function test_s8_4_anApprovedCaseIsNotReopenable() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 4, 0);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(mod.caseInfo(id).terminal, uint8(Moderation.Terminal.APPROVED));
        for (uint256 i; i < who.length; ++i) {
            mod.claim(id, who[i]);
        }

        vm.prank(submitter);
        vm.expectRevert(Moderation.NotReopenable.selector);
        mod.reopen(id, FEE);

        // And the two that ARE reopenable never held an Approve verdict: REJECTED
        // holds Reject, NO_RANDOMNESS holds none. So `strict` is false at every
        // non-APPROVED write by construction, not by the guard.
        assertEq(mod.caseInfo(id).verdict, APPROVE, "the one status that can be strict");
    }

    /// @dev A case that was never reopened closes no question it did not open.
    function test_s8_3_aFirstOpeningClosesNoQuestion() public {
        uint256 id = _submit();
        _toTally(id, 3, 0);
        _rollToDraw(id);
        mod.draw(id);
        assertEq(_idxQuestions(id), 0, "nothing was ever open, so nothing was closed");
    }

    // =========================================================================
    // Registry boundary
    // =========================================================================

    /// @dev `Moderation` never reads or writes a bond directly; the registry is the
    ///      authority on solvency and refuses a commit it cannot cover.
    function test_boundary_anInsolventModeratorCannotCommit() public {
        uint256 id = _submit();
        address m = makeAddr("thin");
        token.mint(m, MIN_STAKE + BOND_MIN);
        vm.startPrank(m);
        token.approve(address(reg), type(uint256).max);
        reg.stake(BOND_MIN); // exactly BOND_MIN: no room for LAMBDA
        vm.stopPrank();
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);

        assertFalse(reg.mayCommit(m, LAMBDA));
        Moderation.Case memory c = mod.caseInfo(id);
        bytes32 h = mod.commitHash(id, c.round, c.paramsVersion, m, APPROVE, _salt(m));
        vm.prank(m);
        vm.expectRevert(Moderation.CannotCommit.selector);
        mod.commit(id, h);
    }

    /// @dev I32 — the claim `Moderation` creates is keyed `(m, caseId, kind)` and
    ///      carries `Moderation` as its owner.
    function test_boundary_commitCreatesAClaimOwnedByModeration() public {
        uint256 id = _submit();
        address m = _moderator(1);
        _matureAll();
        vm.roll(block.number + SEED_LAG + 1);
        _commit(id, m, APPROVE);

        (uint256 amount, address logic) = reg.claimOf(m, id, 1);
        assertEq(amount, LAMBDA);
        assertEq(logic, address(mod), "owned by Moderation, and only it may act on it");
    }

    /// @dev A challenge opens a CHALLENGE-kind claim, distinct from a vote claim, so
    ///      a round-0 dissenter who challenges carries both.
    function test_boundary_aDissenterWhoChallengesCarriesTwoClaims() public {
        uint256 id = _submit();
        address[] memory who = _toTally(id, 3, 1);
        address dissenter = who[3];

        vm.prank(dissenter);
        mod.challenge(id);
        assertEq(reg.liabilitiesOf(dissenter), uint256(LAMBDA) + CHALLENGE_BOND, "both claims stand");
        assertEq(reg.openClaimsOf(dissenter), 2);
    }
}
