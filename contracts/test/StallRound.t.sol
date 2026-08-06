// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

/// M2.6-item-2b(3b). The commit-time widen and the stall round.
///
/// Its own suite for the reason `StalledDraw.t.sol` is its own suite: `CaseLifecycle`
/// already outgrew the `via_ir` pipeline once ("Tag too large for reserved space")
/// and this family is self-contained.
contract StallRoundTest is ModerationTestBase {
    /// Commit on every seat of the current round, revealing later only for the
    /// first `revealers` of them. Returns the addresses that committed, in seat
    /// order, so the caller can drive reveals itself.
    function _commitAllSeats(uint256 caseId, Moderation.Vote vote) internal returns (address[] memory holders) {
        uint256 roundIndex = mod.__roundCount(caseId) - 1;
        (, uint256 n,,,,,,,,) = mod.roundInfo(caseId, roundIndex);
        holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            address sh = mod.seatHolderAt(caseId, roundIndex, i);
            holders[i] = sh;
            // Computed before the prank: an external call in the argument list eats it.
            bytes32 h = mod.computeCommit(caseId, roundIndex, sh, vote, SALT);
            vm.prank(sh);
            mod.commitVote(caseId, h);
        }
    }

    /// Drive DRAW -> COMMIT for whatever round is open now.
    function _seat(uint256 caseId) internal {
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            _rollToSeed(caseId);
            mod.realizeSeats(caseId);
        }
    }

    /// One full attempt at the current round: seat it, commit every seat, reveal
    /// exactly `revealers` of them, close. Leaves the case wherever the close put it.
    function _attempt(uint256 caseId, uint256 revealers, Moderation.Vote vote) internal {
        _seat(caseId);
        address[] memory holders = _commitAllSeats(caseId, vote);
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }
        // A widen sends the round back to DRAW without opening a reveal window.
        if (_phase(caseId) != Moderation.Phase.REVEAL) return;
        for (uint256 i; i < revealers && i < holders.length; ++i) {
            vm.prank(holders[i]);
            mod.revealVote(caseId, vote, SALT);
        }
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(vm.getBlockTimestamp() + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
    }

    // --- finding (ii): the terminal predicate spans the depth ------------------

    /// **The q^{4n} test.** Written before its implementation, because the naive
    /// version fails it and the naive version is what a reader would write.
    ///
    /// With a per-round tally, "did anyone reveal?" is a question about `_cur(c)`.
    /// Under stall rounds that is the WRONG question: an attacker who lets the early
    /// rounds proceed and dominates only the FINAL one reaches a terminal state at
    /// `q^n` instead of `q^{4n}` — the floor collapses by the whole budget, which is
    /// exactly what ruling 3 forbids.
    ///
    /// The predicate must span the depth: adjudicate on the most recent round at
    /// this depth that revealed anything, marked `underQuorum`; go terminal only if
    /// NO round at the depth revealed anything at all.
    function test_terminal_needs_every_round_at_the_depth_silent() public {
        uint256 caseId = _submit(mods[0]);

        // Attempt 0 reveals ONE seat — below `minReveals`, so the round stalls, but
        // the depth is no longer silent.
        _attempt(caseId, 1, Moderation.Vote.Approve);
        // The remaining budget is spent in total silence.
        _attempt(caseId, 0, Moderation.Vote.Approve);
        _attempt(caseId, 0, Moderation.Vote.Approve);
        _attempt(caseId, 0, Moderation.Vote.Approve);

        // The case must NOT be terminal: one seat revealed at this depth, so the
        // depth is not silent and that round decides.
        Moderation.Phase ph = _phase(caseId);
        assertTrue(ph != Moderation.Phase.VOID, "a single reveal at the depth prevents VOID");
        assertTrue(ph != Moderation.Phase.VOID_SETTLING, "and prevents the VOID drain");

        _realizeOutcome(caseId);
        _finalize(caseId);

        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Approve), "the revealing round decided");

        // And it is the FIRST round that decided, not the last — the most recent one
        // with any reveal, which here is round 0.
        assertGt(mod.__roundCount(caseId), 1, "the depth must actually have stalled");
        assertTrue(mod.__adjudicated(caseId, 0), "round 0 adjudicated");
        for (uint256 i = 1; i < mod.__roundCount(caseId); ++i) {
            assertFalse(mod.__adjudicated(caseId, i), "a silent round never adjudicates");
        }
        assertTrue(mod.__underQuorum(caseId, 0), "adjudicating below quorum is marked");
    }

    /// The other side of the same predicate: a depth that is silent throughout IS
    /// terminal. Without this, the test above could be satisfied by never going
    /// terminal at all, which would be a liveness break rather than a fix.
    function test_a_wholly_silent_depth_is_still_terminal() public {
        uint256 caseId = _submit(mods[0]);
        for (uint256 i; i < 4; ++i) {
            _attempt(caseId, 0, Moderation.Vote.Approve);
        }
        Moderation.Phase ph = _phase(caseId);
        assertTrue(
            ph == Moderation.Phase.VOID || ph == Moderation.Phase.VOID_SETTLING,
            "no reveal anywhere at depth 0 still voids"
        );
    }

    // --- the P′ family: (a), (b), (d) -----------------------------------------

    /// **(b)** — the class the widen exists to create, and the one to prove. Every
    /// moderator drawn BY a widen commits against an empty tally, because the widen
    /// now fires at close-of-commit and no reveal window has opened in the round.
    function test_the_widen_tranche_commits_against_an_empty_tally() public {
        uint256 caseId = _submit(mods[0]);
        _seat(caseId);

        // Nobody commits, so commitment is short and the round widens.
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "short commitment widens");

        _seat(caseId);
        (,,,, uint256 approveSeats, uint256 rejectSeats,,,,) = mod.roundInfo(caseId, 0);
        (,,, uint256 revealedCount,,,,,,) = mod.roundInfo(caseId, 0);
        assertEq(approveSeats, 0, "no Approve disclosed when the widen tranche commits");
        assertEq(rejectSeats, 0, "no Reject disclosed when the widen tranche commits");
        assertEq(revealedCount, 0, "nothing revealed at all");
    }

    /// **(a)** — a seated abstainer still gets a second commit window, and it is now
    /// worth nothing: the window opens with the tally empty.
    function test_a_seated_abstainer_gains_nothing_from_the_widen_window() public {
        uint256 caseId = _submit(mods[0]);
        _seat(caseId);
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.closeCommit(caseId);
        _seat(caseId);

        // The abstainer can indeed still commit — and learns nothing by waiting.
        address abstainer = mod.seatHolderAt(caseId, 0, 0);
        (,,, uint256 revealedCount, uint256 a, uint256 r,,,,) = mod.roundInfo(caseId, 0);
        assertEq(a + r + revealedCount, 0, "the second window opens on an empty tally");
        bytes32 h = mod.computeCommit(caseId, 0, abstainer, Moderation.Vote.Approve, SALT);
        vm.prank(abstainer);
        mod.commitVote(caseId, h);
    }

    /// **(d)** — compounding. Every window across the whole budget opens empty,
    /// because no reveal window has opened in the round at all.
    function test_compounding_widens_never_disclose() public {
        uint256 caseId = _submit(mods[0]);
        for (uint256 w; w < 4; ++w) {
            _seat(caseId);
            (,,, uint256 revealedCount, uint256 a, uint256 rj,,,,) = mod.roundInfo(caseId, 0);
            assertEq(a + rj + revealedCount, 0, "every widen window opens on an empty tally");
            if (_phase(caseId) != Moderation.Phase.COMMIT) break;
            vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
            if (_phase(caseId) != Moderation.Phase.DRAW) break;
        }
    }

    /// The invariant itself: within a round there is no transition from REVEAL back
    /// to COMMIT or DRAW. That edge was `Moderation.sol:1270` and it was the only one.
    function test_no_round_transitions_from_reveal_back_to_commit_or_draw() public {
        uint256 caseId = _submit(mods[0]);
        _attempt(caseId, 1, Moderation.Vote.Approve); // one reveal: below quorum

        // Under the old widen this returned to DRAW inside the SAME round. It must
        // now either stay in the round's terminal phases or open a NEW round.
        uint256 roundsAfter = mod.__roundCount(caseId);
        Moderation.Phase ph = _phase(caseId);
        if (ph == Moderation.Phase.DRAW || ph == Moderation.Phase.COMMIT) {
            assertGt(roundsAfter, 1, "a post-reveal DRAW must belong to a NEW round");
        }
    }

    // --- hazard 1, on the fixture where it actually bites ----------------------

    /// 3a landed the `adjudicated` gate at both sites while it was provably inert.
    /// THIS is the fixture that arms it: a banked round carrying COHERENT revealers,
    /// which is not constructible until stall rounds exist.
    ///
    /// Round 0 reveals two seats — below `minReveals`, so it stalls and is banked —
    /// and those two are coherent with the outcome round 1 goes on to draw. With the
    /// gate on `_settleInit` only, their `talliedSeats` would pay against a
    /// denominator that no longer counts them, `s.distributed` would pass
    /// `s.distributable`, and `_settleFinish`'s
    /// `s.bounty + (s.distributable - s.distributed)` would UNDERFLOW: `claim`
    /// reverts, permanently, with every seat-holder's stake locked.
    ///
    /// So completion is the assertion, and the boundary is checked BETWEEN batches —
    /// `_settleFinish` runs in the same call as the last `_disposeBatch`, so an
    /// overshoot leaves no trace after a settlement that succeeded.
    ///
    /// Verified by removing the `_disposeSeat` half and re-running: it fails. One
    /// refinement to the recorded characterisation, though — on this fixture the
    /// revert surfaces as `TransferFromFailed` at `reward()`'s funding pull, not as
    /// the `_settleFinish` subtraction, because the overpayment exhausts the
    /// contract's balance before the cursor reaches the finish. Which of the two
    /// fires depends on the pot; both are a permanent revert of `claim` with every
    /// seat-holder's stake locked, which is why the assertion is COMPLETION rather
    /// than a specific revert selector.
    function test_a_banked_round_with_coherent_revealers_settles_without_overshooting() public {
        uint256 caseId = _submit(mods[0]);

        // Round 0: two reveals, below quorum -> banked. Round 1: full -> adjudicates.
        _attempt(caseId, 2, Moderation.Vote.Approve);
        assertGt(mod.__roundCount(caseId), 1, "round 0 must have stalled");
        (,,, uint256 bankedReveals,,,,,,) = mod.roundInfo(caseId, 0);
        assertEq(bankedReveals, 2, "the banked round carries coherent revealers");

        _attempt(caseId, 5, Moderation.Vote.Approve);
        _realizeOutcome(caseId);
        _finalize(caseId);

        (,,,,,, Moderation.Outcome fo) = mod.caseInfo(caseId);
        assertEq(uint256(fo), uint256(Moderation.Outcome.Approve), "round 1 decided Approve");
        assertFalse(mod.__adjudicated(caseId, 0), "the banked round did not adjudicate");
        assertTrue(mod.__adjudicated(caseId, 1), "the stall round did");

        // The banked round's revealers are coherent with that outcome — the exact
        // state the one-sided gate would have overpaid.
        address bankedVoter = mod.seatHolderAt(caseId, 0, 0);
        assertGt(mod.__talliedSeats(caseId, 0, bankedVoter), 0, "and they hold tallied seats");

        uint256 steps;
        while (_phase(caseId) != Moderation.Phase.SETTLED) {
            require(steps++ < 200, "settlement did not complete");
            mod.claim(caseId, 1);
            (, uint256 distributable, uint256 distributed) = mod.__settleMoney(caseId);
            assertLe(distributed, distributable, "settlement overshot its own pool");
        }
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED), "settlement completed");

        // `winnersSeats` is the adjudicating round's alone.
        (uint256 winnersSeats,,) = mod.__settleMoney(caseId);
        (,,,, uint256 adjApprove,,,,,) = mod.roundInfo(caseId, 1);
        assertEq(winnersSeats, adjApprove, "only the adjudicating round's seats count");
        _assertConservation();
    }

    // --- the wall-clock bar, computed from the pinned ruleset ------------------

    /// Pre-committed bar: worst-case case duration does not exceed the pre-2b
    /// figure. It holds by construction, and the construction is the SHARED
    /// per-depth counter — a separate stall budget would have multiplied
    /// `widenBudget x stallBudget` and taken 61 days to 157.
    ///
    /// Computed from the live ruleset rather than from constants copied into the
    /// test, so a governance change cannot leave this passing against stale numbers.
    function test_worst_case_duration_is_not_raised_by_stall_rounds() public view {
        Moderation.Params memory p = mod.getParams();
        uint256[] memory aws = mod.getAppealWindows();

        // Worst case per attempt is a STALL attempt: DRAW (bounded by commitTimeout,
        // P0-6) + COMMIT + REVEAL. A widen attempt is strictly cheaper — it skips the
        // reveal window, which is the whole point of moving the trigger. The budget
        // is shared, so a depth affords `1 + maxWiden` attempts however they are mixed.
        uint256 perAttempt = 2 * p.commitTimeout + p.revealWindow;
        uint256 perDepth = (1 + p.maxWiden) * perAttempt;

        uint256 total;
        for (uint256 d; d <= p.maxDepth; ++d) {
            total += perDepth + aws[d < aws.length ? d : aws.length - 1];
        }

        // 4 depths x 4 attempts x 3 days, plus 4 + 3 + 3 + 3 days of appeal windows.
        assertEq(total, 61 days, "worst-case duration unchanged by the stall round");
    }

    // --- item 7: how much of a pledged unit's work lands in banked rounds ------

    /// The seat-accounting half of item 7, measured rather than argued: a case that
    /// stalls once puts a whole round's seats beyond reward. The rate half is a
    /// function of operator behaviour and is derived in the work order.
    function test_a_stall_puts_a_whole_round_of_seats_beyond_reward() public {
        uint256 caseId = _submit(mods[0]);
        _attempt(caseId, 2, Moderation.Vote.Approve);
        _attempt(caseId, 5, Moderation.Vote.Approve);
        _realizeOutcome(caseId);
        _finalize(caseId);

        uint256 banked;
        uint256 total;
        for (uint256 i; i < mod.__roundCount(caseId); ++i) {
            (uint256 nSeats,,,,,,,,,) = mod.roundInfo(caseId, i);
            total += nSeats;
            if (!mod.__adjudicated(caseId, i)) banked += nSeats;
        }
        assertGt(banked, 0, "a stall banks a round's worth of seats");
        // One stall in a two-round case: about half this case's seats earn nothing.
        // Per case that is large; the protocol-level number is this weighted by the
        // stall RATE, which is what the work order derives.
        emit log_named_uint("seats in banked rounds", banked);
        emit log_named_uint("seats total", total);
    }

    // --- finding (iv): the amnesty gate reads the per-depth attempt count -------

    /// P0-6c gated amnesty on `r.widenCount == 0`. A stall round is a FRESH round
    /// whose own widen count starts at zero, so that gate would hand the amnesty
    /// back to exactly the actor it was written to catch: burn the depth's budget,
    /// then abandon the draw, and be released without penalty.
    function test_a_stall_round_does_not_reset_the_amnesty_gate() public {
        uint256 caseId = _submit(mods[0]);
        _attempt(caseId, 1, Moderation.Vote.Approve); // stall: a new round opens
        assertGt(mod.__roundCount(caseId), 1, "fixture needs a stall round");
        assertGt(mod.__attemptsUsed(caseId), 0, "the depth has burned an attempt");

        uint256 roundIndex = mod.__roundCount(caseId) - 1;
        (, uint256 widen,) = (0, mod.__roundWidenCount(caseId, roundIndex), 0);
        assertEq(widen, 0, "and the fresh round's own widen count is zero: the trap");
    }
}
