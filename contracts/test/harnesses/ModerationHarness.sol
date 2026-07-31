// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../../src/Moderation.sol";
import {SortitionTree} from "../../src/lib/SortitionTree.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {StakeRegistryHarness} from "./StakeRegistryHarness.sol";

/// @notice Test-only subclass exposing internal state and injectors for state
///         that later M2 items (freezing in M2-5, committing in M2-3) will
///         produce. The injectors mirror exactly what those items' real code
///         paths do, so tests exercise the contract's own accounting, not a
///         parallel model.
contract ModerationHarness is Moderation {
    using SortitionTree for SortitionTree.Tree;

    constructor(IERC20 _token, StakeRegistry _stakeReg, IndexRegistry _indexReg, address _governor)
        Moderation(_token, _stakeReg, _indexReg, _governor)
    {}

    // Stake transitions now go through the registry's real privileged API — this
    // harness IS the authorized logic contract, so these exercise the same code
    // path production does rather than a parallel model.

    /// committed -> frozen until `until`, the settlement freeze (§6.4, D6).
    function __freeze(address moderator, uint256 caseRef, uint256 amount, uint256 until) external {
        stakeReg.freeze(moderator, caseRef, amount, until);
    }

    /// free -> committed, the state a commitVote (§5.3, D5) creates.
    function __commit(address moderator, uint256 caseRef, uint256 amount) external {
        stakeReg.lock(moderator, caseRef, amount);
    }

    function eligibleWeightInternal(address moderator) external view returns (uint256) {
        return stakeReg.eligibleWeightOf(moderator);
    }

    // --- differential-vector injection (M2-8, D10) ---------------------------
    // Build a fully-specified FINALIZED case directly in storage so the exact
    // settlement arithmetic can be replayed against a Python integer reference.
    // The test funds the contract (pot + committed backing) before claim().

    function __injectFinalized(uint8 kind, Outcome finalOutcome, uint256 pot) external returns (uint256 caseId) {
        caseId = nextCaseId++;
        Case storage c = cases[caseId];
        c.id = caseId;
        c.kind = Kind(kind);
        c.finalOutcome = finalOutcome;
        c.phase = Phase.FINALIZED;
        c.pot = pot;
        money.openPotsTotal += pot;
    }

    function __injectRound(uint256 caseId) external {
        cases[caseId].rounds.push();
        // M2.6-P0-5: a real `_openRound` stamps the obligation reference; an
        // injected round must too, or settlement debits the wrong handle.
        uint256 depth = cases[caseId].rounds.length - 1;
        cases[caseId].rounds[depth].caseRef = (caseId << 8) | depth;
        // M2.6-item-2b(3a): a real round reaches settlement through `_armOutcome`,
        // which is where `adjudicated` is set — and settlement now reads it to
        // decide which tally feeds a payoff. An injected FINALIZED case is
        // simulating a round that adjudicated, so the injector must stamp it or it
        // stops mirroring the real path and the differential vectors settle with
        // `winnersSeats == 0`.
        cases[caseId].rounds[depth].adjudicated = true;
        // ...and the depth -> round map `_armOutcome` writes alongside it, which the
        // money paths resolve through. Injected vectors are one round per depth, so
        // round `d` is depth `d`'s adjudicating round. Offset by one: zero means
        // "never adjudicated".
        cases[caseId].adjRoundAt[depth] = depth + 1;
        // M2.6-item-10: the LAST injected round is the one whose tally drew the
        // outcome, matching a real case where the deepest adjudicating round decides.
        // The divisor is depth-dependent, so which round is the deciding one is now
        // load-bearing rather than cosmetic.
        cases[caseId].adjRound = depth;
    }

    /// revealCode: 0 = None (committed but failed to reveal), 1 = Approve, 2 = Reject.
    function __injectSeat(uint256 caseId, uint256 depth, address voter, uint256 seats, uint256 committedAmt, uint8 revealCode)
        external
    {
        Round storage r = cases[caseId].rounds[depth];
        if (r.seats[voter] == 0) r.seatHolders.push(voter);
        r.seats[voter] += seats;
        // M2.6-item-10: a real round records the capacity it SOUGHT at `_openRound`,
        // and item 10's allocation divides by the sum of those. An injected seat
        // models a seat that was sought and seated, so the injector must record it or
        // the vectors settle against a zero capacity and pay nothing.
        r.target += seats;
        if (committedAmt > 0) {
            r.committed[voter] = true;
            r.committedAmt[voter] = committedAmt;
            // Committed stake lives in the registry now; the caller mints the
            // matching tokens there so conservation holds from the first assert.
            StakeRegistryHarness(address(stakeReg)).__injectCommitted(voter, committedAmt);
            // M2.6-P0-5: settlement debits THIS round's obligation, so the
            // injected state must include one or the replay would revert.
            StakeRegistryHarness(address(stakeReg)).__injectObligation(
                address(this), voter, (caseId << 8) | depth, committedAmt
            );
            r.committedCount++;
        }
        Vote v = Vote(revealCode);
        r.reveals[voter] = v;
        uint256 trackContrib = seats * stakeReg.trackOf(voter); // set track before injecting for a nonzero mean
        if (v == Vote.Approve) {
            r.talliedSeats[voter] += seats; // F2: reveal-time count (no widen in injection)
            r.approveSeats += seats;
            r.approveTrackNum += trackContrib;
            r.revealedSeats += seats;
            r.revealedCount++;
        } else if (v == Vote.Reject) {
            r.talliedSeats[voter] += seats;
            r.rejectSeats += seats;
            r.rejectTrackNum += trackContrib;
            r.revealedSeats += seats;
            r.revealedCount++;
        }
    }

    function __injectBond(uint256 caseId, uint256 depth, Outcome appealFor, bool bondInPot) external {
        Round storage r = cases[caseId].rounds[depth];
        r.appealFor = appealFor;
        r.bondInPot = bondInPot;
    }

    function __injectBondContrib(uint256 caseId, uint256 depth, address contributor, uint256 amount) external {
        Round storage r = cases[caseId].rounds[depth];
        r.bondContribs[contributor] += amount;
        r.bond += amount;
    }

    function __setTrack(address voter, uint256 track) external {
        stakeReg.setTrack(voter, track);
    }

    function __injectTopic(uint256 caseId, bytes32 topicKey) external {
        cases[caseId].topicKeys.push(topicKey);
    }

    /// Draw a panel of `count` seats over the live tree (isolates the seat-draw
    /// cost of the realizeSeats poke for gas measurement).
    function __drawPanel(uint256 caseId, uint256 depth, uint256 count, bytes32 seed) external {
        _drawSeats(cases[caseId].rounds[depth], count, seed, 0);
    }

    /// Model a widen re-draw landing `extra` seats on an already-revealed voter:
    /// bumps r.seats (post-widen) without touching talliedSeats (reveal-time).
    /// Settlement must ignore the inflation (F2).
    function __injectWidenSeats(uint256 caseId, uint256 depth, address voter, uint256 extra) external {
        cases[caseId].rounds[depth].seats[voter] += extra;
    }

    /// Push an index entry so a large topic array can be built cheaply for the
    /// H-03 O(1)-deletion gas test. Goes through the registry's real write path
    /// (this harness is the authorized logic contract), so the position map it
    /// builds is the one deletion will read.
    /// @return globalId The registry-minted id — the ONLY valid deletion handle
    ///         (M2.6-P0-1). A local caseId is not usable for this.
    function __pushEntry(bytes32 topicKey, uint256 caseId) external returns (uint256 globalId) {
        globalId = indexReg.writeEntry(
            topicKey, caseId, bytes32(caseId), bytes32(caseId), true, true, 0, 0, _dedupKey(bytes32(caseId), bytes32(caseId), topicKey)
        );
    }

    function __deleteEntry(bytes32 topicKey, uint256 globalId) external {
        // M2.6: was `_deleteEntry`, which moved to `Settlement` with the index
        // effects. The registry call it wrapped is what this always exercised.
        indexReg.deleteEntry(topicKey, globalId);
    }

    /// The settlement cursor's money fields, so a test can assert the boundary
    /// `distributed <= distributable` BETWEEN batches. `_settleFinish` runs in the
    /// same call as the final `_disposeBatch`, so the overshoot that underflows it
    /// is not observable after a completed settlement — only before one, or as the
    /// revert itself (M2.6-item-2b(3a), hazard 1).
    function __settleMoney(uint256 caseId)
        external
        view
        returns (uint256 winnersSeats, uint256 distributable, uint256 distributed)
    {
        SettleState storage st = settleState[caseId];
        return (st.winnersSeats, st.distributable, st.distributed);
    }

    /// Did this round's tally produce the outcome (M2.6-item-2b(3a))?
    function __adjudicated(uint256 caseId, uint256 roundIndex) external view returns (bool) {
        return cases[caseId].rounds[roundIndex].adjudicated;
    }

    function __roundCount(uint256 caseId) external view returns (uint256) {
        return cases[caseId].rounds.length;
    }

    /// M2.6-item-2b: the shared per-depth attempt budget consumed so far.
    function __attemptsUsed(uint256 caseId) external view returns (uint256) {
        return cases[caseId].attemptsUsed;
    }

    function __adjRound(uint256 caseId) external view returns (uint256) {
        return cases[caseId].adjRound;
    }

    function __underQuorum(uint256 caseId, uint256 roundIndex) external view returns (bool) {
        return cases[caseId].rounds[roundIndex].underQuorum;
    }

    function __roundWidenCount(uint256 caseId, uint256 roundIndex) external view returns (uint256) {
        return cases[caseId].rounds[roundIndex].widenCount;
    }

    /// M2.6-item-10: the depth's allocation and the divisor its coherent seats
    /// share it by. Both are written once at `_settleInit`.
    function __rewardTerms(uint256 caseId, uint256 roundIndex)
        external
        view
        returns (uint256 pool, uint256 divisor, uint256 revealedSeats, uint256 target)
    {
        Round storage r = cases[caseId].rounds[roundIndex];
        return (r.rewardPool, r.rewardDivisor, r.revealedSeats, r.target);
    }

    function __distributable(uint256 caseId) external view returns (uint256) {
        return settleState[caseId].distributable;
    }

    /// M2.6-item-10: the case's FEE PAYER, who the unclaimed allocation is owed to.
    /// An injected case has none, and "who is owed" is the ambiguity item 10 names.
    function __setSubmitter(uint256 caseId, address who) external {
        cases[caseId].submitter = who;
    }

    function __setDepth(uint256 caseId, uint256 depth) external {
        cases[caseId].depth = depth;
    }

    function __setUnderQuorum(uint256 caseId, uint256 depth) external {
        cases[caseId].rounds[depth].underQuorum = true;
    }

    function __setBondRefundOnly(uint256 caseId, uint256 depth) external {
        cases[caseId].rounds[depth].bondRefundOnly = true;
    }

    /// Seats actually seated in a round — lets a gas bound assert it measured a
    /// FULL panel rather than passing cheaply on a short one.
    /// The per-transaction seat-draw unit (M2.6-P1-2), so gas bounds assert
    /// against the real batch size rather than a number copied into the test.
    function __drawBatchSize() external pure returns (uint256) {
        return DRAW_SEATS_PER_BATCH;
    }

    /// The per-poke epoch-drain budget (M2.6-P0-3b), so its gas bound is asserted
    /// against the real constant rather than a number copied into the test.
    function __epochDrainSteps() external pure returns (uint256) {
        return EPOCH_DRAIN_STEPS;
    }

    /// Open VOID disposal directly, to measure the transition in isolation
    /// (M2.6-P0-7) without driving a whole under-participation lifecycle.
    function __openVoid(uint256 caseId) external {
        _void(cases[caseId]);
    }

    function __seatCount(uint256 caseId, uint256 depth) external view returns (uint256) {
        return cases[caseId].rounds[depth].nSeats;
    }

    function __seatSeed(uint256 caseId, uint256 depth) external view returns (bytes32) {
        return cases[caseId].rounds[depth].seatSeed;
    }

    /// The eligibility epoch a round's seat seed was armed for (M2.6-P0-3), and the
    /// slack `_armSeed` guarantees after the snapshot block. Not on `roundInfo` —
    /// that tuple is already at ten fields and this is a test-only property.
    function __epochAtArm(uint256 caseId, uint256 depth) external view returns (uint256) {
        return cases[caseId].rounds[depth].epochAtArm;
    }

    function __realizeSlack() external pure returns (uint256) {
        return REALIZE_SLACK;
    }

    function __talliedSeats(uint256 caseId, uint256 depth, address voter) external view returns (uint256) {
        return cases[caseId].rounds[depth].talliedSeats[voter];
    }

    function __seats(uint256 caseId, uint256 depth, address voter) external view returns (uint256) {
        return cases[caseId].rounds[depth].seats[voter];
    }

    function __committedSeats(uint256 caseId, uint256 depth, address voter) external view returns (uint256) {
        return cases[caseId].rounds[depth].committedSeats[voter];
    }
}
