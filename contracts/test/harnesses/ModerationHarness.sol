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

    constructor(IERC20 _token, StakeRegistry _stakeReg, IndexRegistry _indexReg)
        Moderation(_token, _stakeReg, _indexReg)
    {}

    // Stake transitions now go through the registry's real privileged API — this
    // harness IS the authorized logic contract, so these exercise the same code
    // path production does rather than a parallel model.

    /// committed -> frozen until `until`, the settlement freeze (§6.4, D6).
    function __freeze(address moderator, uint256 amount, uint256 until) external {
        stakeReg.freeze(moderator, amount, until);
    }

    /// free -> committed, the state a commitVote (§5.3, D5) creates.
    function __commit(address moderator, uint256 amount) external {
        stakeReg.lock(moderator, amount);
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
        openPotsTotal += pot;
    }

    function __injectRound(uint256 caseId) external {
        cases[caseId].rounds.push();
    }

    /// revealCode: 0 = None (committed but failed to reveal), 1 = Approve, 2 = Reject.
    function __injectSeat(uint256 caseId, uint256 depth, address voter, uint256 seats, uint256 committedAmt, uint8 revealCode)
        external
    {
        Round storage r = cases[caseId].rounds[depth];
        if (r.seats[voter] == 0) r.seatHolders.push(voter);
        r.seats[voter] += seats;
        if (committedAmt > 0) {
            r.committed[voter] = true;
            r.committedAmt[voter] = committedAmt;
            // Committed stake lives in the registry now; the caller mints the
            // matching tokens there so conservation holds from the first assert.
            StakeRegistryHarness(address(stakeReg)).__injectCommitted(voter, committedAmt);
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
        _deleteEntry(topicKey, globalId);
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

    function __seatSeed(uint256 caseId, uint256 depth) external view returns (bytes32) {
        return cases[caseId].rounds[depth].seatSeed;
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
