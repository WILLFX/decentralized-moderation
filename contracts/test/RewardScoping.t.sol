// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";

/// M2.6-item-10. Per-depth reward allocation with a depth-dependent divisor.
///
/// Injection rather than a driven lifecycle: these assertions are about exact
/// arithmetic over a specified round shape, and a driven case cannot fix `f_v` at
/// the values the divisor question turns on.
contract RewardScopingTest is ModerationTestBase {
    uint256 internal constant POT = 1000 * XBZZ + 12345; // odd -> dust
    uint256 internal constant CAMT = 20 * XBZZ;

    /// Addresses the injector actually used, in order. Naming them by
    /// `abi.encodePacked("A", i)` produced a 33-byte string rather than "A0", so the
    /// assertions queried moderators that were never injected and read zeroes —
    /// recorded because it is a fixture that would have passed vacuously on the
    /// balance assertions had they been `assertGe` rather than `assertEq`.
    address[] internal approvers;
    address[] internal rejecters;
    address[] internal silent;

    function _voter(string memory n) internal returns (address) {
        return makeAddr(n);
    }

    /// One round, `nApprove` seats revealing Approve and `nReject` revealing Reject,
    /// plus `nSilent` committers who never revealed. Returns the case id.
    function _inject(Moderation.Outcome fo, uint256 nApprove, uint256 nReject, uint256 nSilent)
        internal
        returns (uint256 caseId)
    {
        caseId = mod.__injectFinalized(0, fo, POT);
        bzz.mint(address(mod), POT);
        mod.__injectRound(caseId);
        uint256 seats;
        for (uint256 i; i < nApprove; ++i) {
            address a = _voter(string.concat("A", vm.toString(i)));
            approvers.push(a);
            mod.__injectSeat(caseId, 0, a, 1, CAMT, 1);
            seats++;
        }
        for (uint256 i; i < nReject; ++i) {
            address a = _voter(string.concat("R", vm.toString(i)));
            rejecters.push(a);
            mod.__injectSeat(caseId, 0, a, 1, CAMT, 2);
            seats++;
        }
        for (uint256 i; i < nSilent; ++i) {
            address a = _voter(string.concat("S", vm.toString(i)));
            silent.push(a);
            mod.__injectSeat(caseId, 0, a, 1, CAMT, 0);
            seats++;
        }
        bzz.mint(address(stakeReg), seats * CAMT);
    }

    // --- build condition (a): the two buckets move together ---------------------

    /// **The credit must be PULLED, or the fixture cannot see the defect.**
    ///
    /// `_settleInit` carves a submitter credit out of `distributable`, so
    /// `totalPendingPayout` and `totalSettling` both change. Update one and not the
    /// other and the buckets are wrong by exactly the credit — but the failure mode
    /// depends on which: under-crediting `totalPendingPayout` leaves
    /// `claimSubmitterRefund`'s `-=` to UNDERFLOW, which a fixture that settles and
    /// stops never reaches, and over-crediting `totalSettling` leaves it never
    /// draining to zero.
    ///
    /// So this settles, conserves, pulls, and conserves again.
    function test_the_unclaimed_allocation_is_pullable_by_the_fee_payer_and_conserves() public {
        // Two Approve revealers, one silent: turnout is short, so part of the
        // allocation is never earned.
        uint256 caseId = _inject(Moderation.Outcome.Approve, 2, 0, 1);
        address feePayer = makeAddr("feePayer");
        mod.__setSubmitter(caseId, feePayer);

        mod.claim(caseId);
        _assertConservation();

        uint256 owed = mod.submitterRefundOwed(caseId);
        assertGt(owed, 0, "a short-turnout case leaves an unclaimed allocation");

        uint256 before = bzz.balanceOf(feePayer);
        vm.prank(feePayer);
        uint256 paid = mod.claimSubmitterRefund(caseId);
        assertEq(paid, owed, "pulled exactly what was owed");
        assertEq(bzz.balanceOf(feePayer) - before, owed, "and it reached the fee payer");
        assertEq(mod.submitterRefundOwed(caseId), 0, "credit cleared");

        // The assertion the pull exists to reach.
        _assertConservation();

        // Nobody else can take it, and it cannot be taken twice.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Moderation.NothingToReclaim.selector);
        mod.claimSubmitterRefund(caseId);
    }

    // --- the keeper residue, pinned where the two readings differ most -----------

    /// **The empty-winning-side case.** Final outcome Reject, and every revealer
    /// voted Approve — so the winning side is empty and the whole allocation is
    /// unearned.
    ///
    /// Before item 10 this was the case where `s.distributable - s.distributed`
    /// handed the **entire** allocation to whoever sent the last settlement batch,
    /// and a voter is free to be that keeper. The property is now that the keeper's
    /// residue is bounded by ROUNDING — at most one wei per paid seat-holder,
    /// independent of the size of the pot — and here nobody is paid at all, so it is
    /// the bounty and nothing else.
    function test_keeper_residue_is_bounded_by_rounding_at_the_empty_winning_side() public {
        uint256 caseId = _inject(Moderation.Outcome.Reject, 3, 0, 0);
        address feePayer = makeAddr("feePayer");
        mod.__setSubmitter(caseId, feePayer);

        address keeper = makeAddr("keeper");
        uint256 keeperBefore = bzz.balanceOf(keeper);
        vm.prank(keeper);
        mod.claim(caseId);
        uint256 keeperGot = bzz.balanceOf(keeper) - keeperBefore;

        // The bounty is the keeper's legitimate pay; everything above it would be
        // swept allocation.
        uint256 bounty = ((POT) * mod.getParams().claimBountyFrac) / 1e18;
        assertEq(keeperGot, bounty, "keeper is paid the bounty and not one wei of the allocation");

        // And the allocation went to the fee payer instead.
        uint256 owed = mod.submitterRefundOwed(caseId);
        assertEq(owed, POT - bounty, "the whole unearned allocation refunds");
        assertGt(owed, keeperGot * 50, "which is the bulk of the pot, not a rounding crumb");

        vm.prank(feePayer);
        mod.claimSubmitterRefund(caseId);
        _assertConservation();
    }

    // --- the divisor, which is the whole of the design ---------------------------

    /// At the depth whose tally DRAWS the outcome, the divisor is the winning side.
    /// That is what cancels `P(final = v) = f_v / T` and leaves the expected payoff
    /// invariant in the vote.
    ///
    /// Asserted as the identity that produces the cancellation —
    /// `reward x w == pool x talliedSeats` — because the cancellation is the
    /// neutrality, and an identity is checkable where an expectation is not.
    function test_the_deciding_depth_divides_by_the_winning_side() public {
        uint256 caseId = _inject(Moderation.Outcome.Approve, 2, 3, 0);
        mod.claim(caseId);

        (uint256 pool, uint256 divisor, uint256 revealed,) = mod.__rewardTerms(caseId, 0);
        assertEq(divisor, 2, "divisor is the WINNING side (2 Approve), not the 5 revealed");
        assertEq(revealed, 5, "and the round did reveal five");

        // Each winner got pool/2; the losers got nothing.
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(approvers[0]);
        assertEq(free, CAMT + pool / 2, "winner paid pool / winning seats");
        (uint256 lost,,,,,,,,) = stakeReg.moderatorInfo(rejecters[0]);
        assertEq(lost, 0, "the losing side is frozen, not paid");
    }

    /// At a SUPERSEDED depth the divisor is revealed seats, not the winning side.
    ///
    /// **This is the assertion nothing else reaches.** A superseded voter cannot move
    /// `P(final = v)` — a later panel sets it — so a winning-side divisor leaves
    /// `f_v` in the denominator alone and pays MORE for the minority position: 5x on
    /// a five-seat panel, against 1.83x for the same shape before this change. It is
    /// invisible to conservation (it conserves), to payout neutrality at the deciding
    /// depth (which holds), and to the before/after tables (which agree at full
    /// turnout).
    function test_a_superseded_depth_divides_by_revealed_seats() public {
        // Two rounds. Round 1 decides Approve; round 0 is superseded and split.
        uint256 caseId = mod.__injectFinalized(0, Moderation.Outcome.Approve, POT);
        bzz.mint(address(mod), POT);
        mod.__injectRound(caseId); // round 0 — superseded
        mod.__injectSeat(caseId, 0, _voter("s0a"), 1, CAMT, 1); // Approve, coherent
        mod.__injectSeat(caseId, 0, _voter("s0b"), 1, CAMT, 2); // Reject, incoherent
        mod.__injectSeat(caseId, 0, _voter("s0c"), 1, CAMT, 2); // Reject, incoherent
        mod.__injectRound(caseId); // round 1 — decides
        mod.__injectSeat(caseId, 1, _voter("s1a"), 1, CAMT, 1);
        mod.__injectSeat(caseId, 1, _voter("s1b"), 1, CAMT, 1);
        mod.__setDepth(caseId, 1);
        bzz.mint(address(stakeReg), 5 * CAMT);

        mod.claim(caseId);

        (uint256 pool0, uint256 div0, uint256 rev0,) = mod.__rewardTerms(caseId, 0);
        (, uint256 div1,,) = mod.__rewardTerms(caseId, 1);

        assertEq(div0, rev0, "superseded depth divides by REVEALED seats");
        assertEq(div0, 3, "all three revealed, only one was coherent");
        assertEq(div1, 2, "the deciding depth divides by its winning side");

        // The lone coherent voter at the superseded depth is paid its share of THREE,
        // not of one. Under a winning-side divisor it would have taken the entire
        // pool of that depth — the 3x minority premium, on this fixture.
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(_voter("s0a"));
        assertEq(free, CAMT + pool0 / 3, "paid pool / revealed, not pool / winners");
        assertLt(pool0 / 3, pool0, "which is strictly less than the minority premium would be");
    }

    // --- build condition (b): the mean keeps its denominator --------------------

    /// `winnersSeats` is no longer the reward divisor, and is NOT dropped. It is the
    /// denominator of `meanTrackNum / winnersSeats`, which is a MEAN — `Settlement`
    /// already carries the comment saying that scoping one without the other leaves a
    /// ratio that is not a mean of anything and can exceed every individual track.
    ///
    /// A freeze of the shipped base duration is the observable consequence: at a zero
    /// mean track the curve returns `freezeBase` exactly, which it cannot do if the
    /// denominator went missing.
    function test_the_freeze_curve_still_has_its_denominator() public {
        uint256 caseId = _inject(Moderation.Outcome.Approve, 2, 1, 0);
        mod.claim(caseId);

        // The incoherent voter is frozen for `freezeBase x power`, and at a zero mean
        // track power is exactly 1. A dropped denominator would not land here.
        (,,,, uint256 frozenUntil,,,,) = stakeReg.moderatorInfo(rejecters[0]);
        assertEq(
            frozenUntil - vm.getBlockTimestamp(),
            mod.getParams().freezeBase,
            "mean-track denominator intact: power(0) == 1"
        );
    }

    // --- the named invariant, not a guard ---------------------------------------

    /// `adjudicated => revealedSeats > 0`. `_armOutcome`'s only two callers are the
    /// `reveals >= minReveals` branch and `_lastRevealingRoundAtDepth`, which returns
    /// only a round that revealed something — so both divisors are non-zero at any
    /// adjudicating round.
    ///
    /// Asserted as an invariant rather than guarded in the division: a guard on an
    /// unreachable zero is the `unbackedSeats` shape, and it reads as evidence that
    /// the zero is reachable.
    function test_an_adjudicating_round_always_revealed_something() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _finalize(caseId);

        uint256 n = mod.__roundCount(caseId);
        uint256 checked;
        for (uint256 i; i < n; ++i) {
            if (!mod.__adjudicated(caseId, i)) continue;
            (,,, uint256 revealedCount,,,,,,) = mod.roundInfo(caseId, i);
            assertGt(revealedCount, 0, "an adjudicating round revealed something");
            checked++;
        }
        assertGt(checked, 0, "the sweep visited an adjudicating round");
    }
}
