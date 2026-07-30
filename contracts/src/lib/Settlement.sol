// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Moderation} from "../Moderation.sol";
import {StakeRegistry} from "../StakeRegistry.sol";
import {IndexRegistry} from "../IndexRegistry.sol";
import {FreezeMath} from "./FreezeMath.sol";

/// @title Settlement
/// @notice The whole settlement block — initialisation, the per-seat disposal loop,
///         the finish and its index effects — lifted out of `Moderation` as a
///         DELEGATECALLed library (M2.6, second structural split).
///
/// ## Why this seam
///
/// `Moderation` had 439 bytes of EIP-170 headroom, and the next item — restructuring
/// the widen so a commitment cannot be made against a disclosed tally — lands in the
/// ROUND STATE MACHINE (`_openRound`, `realizeSeats`, `commitVote`, `closeCommit`,
/// `revealVote`, `_closeReveal`). The seam therefore had to give room *there*, which
/// rules out moving any part of that machine however many bytes it holds.
///
/// Measured, by stubbing each candidate's bodies and reading `forge build --sizes`
/// against a 24,137 B baseline:
///
///     settlement block (this)                 5,688 B
///       of which the disposal loop alone      3,244 B
///     submission entry points                 3,012 B
///     appeals                                 2,369 B
///     index effects                           1,017 B
///     VOID disposal                             913 B
///
/// Settlement is the largest candidate AND the one furthest from the round state
/// machine — the case is already FINALIZED before any of this runs.
///
/// **Rejected.** *Appeals*: `_failAppealRound` is called from `_closeReveal` and
/// `resolveStalledDraw`, so it would put a cross-boundary call *inside* the machine
/// this split exists to give room to — the wrong direction, for half the bytes.
/// *Submission*: `submit` writes case storage and calls `_openRound`, so it
/// straddles that machine's entry.
///
/// *VOID disposal* was rejected on the same structural ground and that reasoning was
/// **wrong**: it said `_voidStep` is reached from `closeReveal`. It is not. What
/// `closeReveal` and `resolveStalledDraw` call is `_void`, the O(1) phase flip, and
/// that stays in `Moderation`. `_voidStep` is reached only through `claim` ->
/// `_settle`, already across this boundary. It moved here in the split's follow-up
/// (`settleVoid`), which also removed the duplicate `_settleDuty`, `_freezeSlice`
/// and `_clearDedup` that keeping it behind cost.
///
/// ## Why a LIBRARY and not a fourth contract
///
/// The first split moved `RulesetGovernor` out as a contract because governance
/// authoring is cold and touches little case state. This is the opposite: it reads
/// and writes almost all of `Case` and `Round` — `committedAmt`, `reveals`,
/// `talliedSeats`, `seats`, `committed`, `caseRef`, `seatHolders`, `widenCount`,
/// `bond*` — on every seat and every round. A separate contract would have to reach
/// each of those across a call boundary, which costs more at the call sites than the
/// move frees; that is exactly what ruled out moving ruleset storage in the first
/// split.
///
/// A library with `public` functions is DELEGATECALLed, so its code runs against
/// `Moderation`'s own storage. **The bytes move; the storage does not.** Storage
/// pointers are passed as slot references and every field is touched exactly as it
/// was when this was inlined.
///
/// ## Two things the seam forced, both measured rather than assumed
///
/// **One entry point, not three.** An earlier shape kept `_settleInit` and
/// `_settleFinish` in `Moderation` and called only the loop across the seam. It
/// saved **298 bytes net**: marshalling four storage pointers plus the externals at
/// three call sites cost back almost everything the move freed. Collapsing to a
/// single `settle()` is what turns 298 into 4,173.
///
/// **`immutable` does not survive a delegatecall.** `token`, `stakeReg` and
/// `indexReg` are baked into `Moderation`'s bytecode, not this library's, so they
/// arrive in `Ext`. That is the whole of the extra parameter surface.
///
/// ## Behaviour
///
/// Nothing here changes what settlement does. The only restructuring is mechanical:
/// `_settle`'s `FINALIZED -> init` step moved inside `settle()`, and the
/// `SettleProgressed` emit moved with it. Same order, same transaction, same state
/// writes. The evidence is the suite: 218 tests over 18 suites, unchanged except one
/// identifier in a harness and one harness call repointed at the registry.
library Settlement {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    /// The externals this loop needs. `immutable` reads do not survive a
    /// delegatecall into library code, so they arrive as arguments.
    struct Ext {
        IERC20 token;
        StakeRegistry stakeReg;
        IndexRegistry indexReg;
    }


    /// @notice The whole settlement block behind ONE delegatecall: initialise on the
    ///         first poke, dispose up to `maxSteps` seat-holders, and finish when the
    ///         cursor reaches the end.
    /// @dev Collapsed into a single entry point deliberately. An earlier shape kept
    ///      `_settleInit` and `_settleFinish` in `Moderation` and called only the
    ///      loop across the seam; it saved **298 bytes net**, because marshalling
    ///      four storage pointers plus the externals at three separate call sites
    ///      cost almost everything the move freed. One call, one marshalling.
    function settle(
        Moderation.Case storage c,
        Moderation.SettleState storage s,
        Moderation.Money storage money,
        Moderation.Params storage p,
        mapping(address => bool) storage decayed,
        Moderation.Case storage target,
        Ext memory x,
        uint256 maxSteps
    ) public {
        if (c.phase == Moderation.Phase.FINALIZED) _settleInit(c, s, money, p);
        bool done = _disposeBatch(c, s, money, p, decayed, x, maxSteps);
        if (done) _settleFinish(c, s, money, target, p, x);
        else emit Moderation.SettleProgressed(c.id, s.round, s.idx);
    }

    /// @notice One bounded batch of VOID disposal (M2.6-P0-7), behind the same seam.
    /// @dev Moved here in the split's follow-up. The original rejection reasoning —
    ///      "`_voidStep` is reached from `closeReveal`, inside the round state
    ///      machine" — was simply wrong, and is corrected in this file's header: it
    ///      is `_void`, the O(1) phase flip, that `closeReveal` and
    ///      `resolveStalledDraw` call. `_voidStep` is reached only through `claim` ->
    ///      `_settle`, which was already across this boundary. So the move adds no
    ///      call into the machine the split exists to give room to, and it deletes
    ///      the reason `_settleDuty`, `_freezeSlice` and `_clearDedup` existed in two
    ///      copies — a duplicated penalty rule being exactly the kind of divergence
    ///      this milestone keeps finding.
    ///
    ///      A VOID happens only on zero reveals after the widen cap, so every
    ///      committer in the round is a commit-and-vanish actor: each takes the §6.3
    ///      brief freeze (committed -> frozen), never a free release. Otherwise a
    ///      coordinated panel could grief submissions to VOID at no cost.
    function settleVoid(
        Moderation.Case storage c,
        Moderation.SettleState storage s,
        Moderation.Money storage money,
        Moderation.Params storage p,
        Ext memory x,
        uint256 maxSteps
    ) public {
        Moderation.Round storage r = c.rounds[c.rounds.length - 1];
        uint256 idx = s.idx;
        uint256 len = r.seatHolders.length;
        uint256 steps;
        uint256 freezeUntil = block.timestamp + p.failedRevealFreeze;
        // M2.6-P0-6c: amnesty for an abandoned draw, gated on the round NEVER
        // having widened.
        //
        // P0-6 gave a blanket amnesty on `c.drawAbandoned`, reasoning that a seated
        // moderator cannot fail to do something it was never asked to do. True of a
        // round that stalled before COMMIT ever opened; false once the round has
        // widened, because a widen only happens AFTER a commit window opened and
        // closed. `widenCount > 0` is therefore proof that at least one window
        // existed, and the holders who sat through it are no-shows whatever becomes
        // of the later draw.
        //
        // The blanket version was H-10 EVASION, and cheap: moderators pledging
        // exactly the depth-0 target get seated, refuse to commit, the round widens,
        // the re-draw stalls on the very capacity they are still holding, and
        // `resolveStalledDraw` releases everyone.
        //
        // Known imprecision, taken deliberately: this OVER-penalises the widen
        // tranche — moderators drawn by the widen itself, who were never given a
        // window either. In the attack it has no false positives at all, because the
        // attackers hold the capacity that makes the re-draw stall, so the widen
        // tranche is empty by construction. Where it does bite, the cost is one
        // seat's escrow frozen for one `failedRevealFreeze`. Separating the tranches
        // needs per-seat window provenance, filed with P1-1(b) to be built once.
        bool amnesty = c.drawAbandoned && r.widenCount == 0;
        while (idx < len && steps < maxSteps) {
            address a = r.seatHolders[idx];
            uint256 amt = r.committedAmt[a];
            if (amt > 0) {
                r.committedAmt[a] = 0;
                x.stakeReg.freeze(a, r.caseRef, amt, freezeUntil); // committed -> frozen; never a transfer
            }
            // H-07: capacity and escrow both return when the case ends (P0-2).
            _settleDuty(p, x, r.caseRef, a, r.seats[a], !amnesty && !r.committed[a]);
            unchecked {
                ++idx;
                ++steps;
            }
        }
        s.idx = idx;
        if (idx < len) {
            emit Moderation.SettleProgressed(c.id, c.depth, idx);
            return;
        }
        _voidFinish(c, money, p, x);
    }

    /// @dev The pot side of a VOID, once every participant is disposed.
    function _voidFinish(
        Moderation.Case storage c,
        Moderation.Money storage money,
        Moderation.Params storage p,
        Ext memory x
    ) private {
        uint256 pot = c.pot;
        uint256 bounty = (pot * p.claimBountyFrac) / WAD;
        c.pot = 0;
        money.openPotsTotal -= pot;
        _clearDedup(c, x);
        x.indexReg.closeCase(c.id); // M2.6-P0-5b: index effects complete
        c.phase = Moderation.Phase.VOID;

        if (bounty > 0) address(x.token).safeTransfer(msg.sender, bounty);
        address(x.token).safeTransfer(c.submitter, pot - bounty);
        emit Moderation.Voided(c.id);
    }

    /// @notice Dispose up to `maxSteps` seat-holders from the cursor.
    /// @return done True when the last seat-holder of the last round was disposed,
    ///         so `settle` knows to run the finish in the same transaction.
    function _disposeBatch(
        Moderation.Case storage c,
        Moderation.SettleState storage s,
        Moderation.Money storage money,
        Moderation.Params storage p,
        mapping(address => bool) storage decayed,
        Ext memory x,
        uint256 maxSteps
    ) private returns (bool done) {
        // `money.totalSettling` is decremented ONCE PER BATCH, from the delta in
        // `s.distributed`, rather than per reward inside the loop as it was before
        // the split. Both forms leave the same value at the batch's end; they differ
        // in how long invariant 1's token-balance equality is untrue.
        //
        // From the first reward credit the registry has already PULLED that reward
        // out of this contract, so `balanceOf(Moderation)` has fallen while
        // `totalSettling` has not: the equality is broken from that credit until this
        // function returns. What makes the window acceptable is not that it is short
        // — it is a whole batch — but that **no execution can observe it**. `claim`
        // is `nonReentrant`; the only external calls in the loop are into
        // `StakeRegistry`, which never calls back into a logic contract; and the
        // token is a fixed ERC-20 with no transfer hook. Every one of those three is
        // load-bearing. A token with a callback would make this reachable, and the
        // per-reward form would have to come back.
        //
        // Invariant 1 is stated at transaction boundaries for exactly this reason.
        // The registry's stake-bucket equality is NOT weakened and still holds at
        // every block.
        uint256 distributedBefore = s.distributed;
        Moderation.Outcome fo = c.finalOutcome;
        uint256 nRounds = c.rounds.length;
        uint256 round = s.round;
        uint256 idx = s.idx;
        uint256 steps;
        while (round < nRounds) {
            Moderation.Round storage r = c.rounds[round];
            // M2.6-P0-6b/P0-6c: amnesty for a round whose draw was abandoned —
            // but only if it NEVER WIDENED. See `_voidStep` for the argument; this
            // is the same rule on the appeal path, which reaches settlement through
            // `_failAppealRound` -> FINALIZED instead of VOID.
            bool amnesty = c.drawAbandoned && round + 1 == nRounds && r.widenCount == 0;
            uint256 nsh = r.seatHolders.length;
            while (idx < nsh) {
                if (steps >= maxSteps) {
                    s.round = round;
                    s.idx = idx;
                    money.totalSettling -= s.distributed - distributedBefore;
                    return false;
                }
                address a = r.seatHolders[idx];
                idx++;
                steps++;
                if (r.committed[a]) {
                    _disposeSeat(c, r, a, fo, s, p, decayed, x);
                }
                // H-07/H-10: drawn on pledged capacity but never committed. The
                // moderator volunteered for duty, so a no-show is its own choice,
                // not conscription — it takes the §6.3 brief freeze on one seat's
                // worth of stake. This is the penalty that makes "dominate the
                // appeal panel and simply refuse to commit" (H-10) cost something.
                // Capacity and escrow settle in the same call either way (P0-2).
                _settleDuty(p, x, r.caseRef, a, r.seats[a], !amnesty && !r.committed[a]);
            }
            round++;
            idx = 0;
        }
        s.round = round;
        s.idx = 0;
        money.totalSettling -= s.distributed - distributedBefore;
        return true;
    }

    /// @dev Return or freeze one seat-holder's committed stake, credit its reward
    ///      if coherent, and decay its track once per case.
    function _disposeSeat(
        Moderation.Case storage c,
        Moderation.Round storage r,
        address a,
        Moderation.Outcome fo,
        Moderation.SettleState storage s,
        Moderation.Params storage p,
        mapping(address => bool) storage decayed,
        Ext memory x
    ) private {
        uint256 amt = r.committedAmt[a];
        Moderation.Vote vote = r.reveals[a];
        if (vote == Moderation.Vote.None) {
            x.stakeReg.freeze(a, r.caseRef, amt, block.timestamp + p.failedRevealFreeze);
        } else if (_coherent(vote, fo)) {
            // Principal: pure bookkeeping inside the registry, no transfer — the
            // committed slice never left it.
            x.stakeReg.release(a, r.caseRef, amt);
            uint256 reward = s.winnersSeats == 0 ? 0 : (s.distributable * r.talliedSeats[a]) / s.winnersSeats;
            if (reward > 0) {
                // `totalSettling` is decremented by the caller from the delta in
                // `s.distributed` — see `disposeBatch`.
                s.distributed += reward;
                // The reward is the one value that CROSSES the contract boundary:
                // it is pot money (fees + forfeited bonds) held here, becoming
                // stake held there. The registry PULLS its own funding inside
                // reward() and verifies the balance delta (M2.6-P0-4), so the
                // funding requirement is enforced by the registry rather than
                // trusted of the caller. We approve exactly the amount; reward()
                // consumes it, so no standing allowance is left behind.
                address(x.token).safeApprove(address(x.stakeReg), reward);
                x.stakeReg.reward(a, reward);
            }
        } else {
            x.stakeReg.freeze(a, r.caseRef, amt, block.timestamp + s.freezeDur);
        }
        _touchTrack(c, r, a, fo, p, decayed, x);
    }

    /// @dev Decay a participant's track exactly once per case (O(1) dedup, no more
    ///      O(participants²) scan), with the coherent-undisputed +1 for a single
    ///      round case (§6.5).
    function _touchTrack(
        Moderation.Case storage c,
        Moderation.Round storage r,
        address a,
        Moderation.Outcome fo,
        Moderation.Params storage p,
        mapping(address => bool) storage decayed,
        Ext memory x
    ) private {
        if (decayed[a]) return;
        decayed[a] = true;
        uint256 t = (x.stakeReg.trackOf(a) * p.trackDecay) / WAD;
        if (c.rounds.length == 1 && r.reveals[a] != Moderation.Vote.None && _coherent(r.reveals[a], fo)) {
            t += WAD; // +1 for a coherent, undisputed participation
        }
        x.stakeReg.setTrack(a, t);
    }

    /// @dev H-07/H-10: settle a seat-holder's duty reservations, penalising one
    ///      seat's escrow if it was drawn and did not serve. Bounded registry-side
    ///      by the escrow those seats actually posted, so it can never fail
    ///      settlement and can never reach another case's collateral.
    function _settleDuty(
        Moderation.Params storage p,
        Ext memory x,
        uint256 caseRef,
        address a,
        uint256 seats,
        bool failed
    ) private {
        if (seats == 0) return;
        // One seat's worth, regardless of seats held.
        uint256 penalty = failed ? p.riskPerSeat : 0;
        x.stakeReg.settleDuty(a, caseRef, seats, penalty, block.timestamp + p.failedRevealFreeze);
    }

    function _coherent(Moderation.Vote vote, Moderation.Outcome finalOutcome) private pure returns (bool) {
        return (vote == Moderation.Vote.Approve && finalOutcome == Moderation.Outcome.Approve)
            || (vote == Moderation.Vote.Reject && finalOutcome == Moderation.Outcome.Reject);
    }

    /// @dev O(rounds) aggregate + money bookkeeping, run once when settlement
    ///      starts. Winners' seats and mean-track are read from the per-round,
    ///      per-side accumulators frozen at reveal (no O(participants) scan).
    function _settleInit(Moderation.Case storage c, Moderation.SettleState storage s, Moderation.Money storage money, Moderation.Params storage p) private {
        Moderation.Outcome fo = c.finalOutcome;
        uint256 nRounds = c.rounds.length;
        uint256 winnersSeats;
        uint256 meanTrackNum;
        uint256 refunds;
        uint256 winningContribTot;
        for (uint256 d; d < nRounds; ++d) {
            Moderation.Round storage r = c.rounds[d];
            if (fo == Moderation.Outcome.Approve) {
                winnersSeats += r.approveSeats;
                meanTrackNum += r.approveTrackNum;
            } else {
                winnersSeats += r.rejectSeats;
                meanTrackNum += r.rejectTrackNum;
            }
            if (r.bondInPot) {
                if (r.appealFor == fo) {
                    // winning appeal: capital refunded + shares the bonus pool
                    refunds += r.bond;
                    winningContribTot += r.bond;
                } else if (r.bondRefundOnly) {
                    // quorum-failed appeal (H-10): capital refunded, no bonus, not
                    // forfeited to winners — excluded from the distributable pot.
                    refunds += r.bond;
                }
            }
        }

        
        uint256 pot = c.pot;
        uint256 residual = pot - refunds; // WO-1: refund winning bond capital first
        uint256 bounty = (residual * p.claimBountyFrac) / WAD;
        uint256 bonusPool = winningContribTot == 0 ? 0 : (residual * p.bonusFrac) / WAD;
        uint256 distributable = residual - bounty - bonusPool;

        // Winning-appeal refunds + bonuses become pull-based (C-01); the reward pool
        // + bounty are held in `money.totalSettling` while the batched disposition
        // credits them out. Conservation is exact at TRANSACTION boundaries, not at
        // every intermediate state — see `_disposeBatch` for the window and why
        // nothing can execute inside it (invariant 1).
        money.openPotsTotal -= pot;
        c.apBonusPoolLeft = bonusPool;
        c.apContribTotLeft = winningContribTot;
        money.totalPendingPayout += refunds + bonusPool;
        money.totalSettling += residual - bonusPool; // = bounty + distributable, in flight

        s.winnersSeats = winnersSeats;
        s.distributable = distributable;
        s.freezeDur = FreezeMath.freezeDuration(
            winnersSeats == 0 ? 0 : meanTrackNum / winnersSeats, p.trackSat, p.freezeCap, p.freezeBase
        );
        s.bounty = bounty;
        s.pot = pot;
        c.phase = Moderation.Phase.SETTLING;
    }

    /// @dev Complete settlement: sweep reward-channel dust into the claim bounty,
    ///      run index effects, pay the finisher, and mark SETTLED.
    function _settleFinish(Moderation.Case storage c, Moderation.SettleState storage s, Moderation.Money storage money, Moderation.Case storage target, Moderation.Params storage p, Ext memory x) private {
        uint256 claimBounty = s.bounty + (s.distributable - s.distributed);
        money.totalSettling -= claimBounty; // drains this case's in-flight amount to 0
        c.pot = 0;
        _settleIndex(c, target, p, x);
        x.indexReg.closeCase(c.id); // M2.6-P0-5b: index effects complete
        c.phase = Moderation.Phase.SETTLED;
        if (claimBounty > 0) address(x.token).safeTransfer(msg.sender, claimBounty);
        emit Moderation.Settled(c.id, c.finalOutcome, s.pot, claimBounty);
    }

    /// @dev Index side effects at settlement (§8.1, §8.2). Writes happen only
    ///      here, on a final APPROVE — never provisionally at a depth-0 tally.
    function _settleIndex(Moderation.Case storage c, Moderation.Case storage target, Moderation.Params storage p, Ext memory x) private {
        if (c.kind == Moderation.Kind.SUBMISSION) {
            if (c.finalOutcome == Moderation.Outcome.Approve) {
                _writeEntries(c, p, x); // dedup kept: content is now in the index
            } else if (c.finalOutcome == Moderation.Outcome.Reject) {
                _clearDedup(c, x); // resubmittable
            }
        } else {
            // REMOVAL: APPROVE deletes the target's entries; REJECT keeps them.
            if (c.finalOutcome == Moderation.Outcome.Approve) {
                _removeTarget(c, target, x);
            }
        }
    }

    function _writeEntries(Moderation.Case storage c, Moderation.Params storage p, Ext memory x) private {
        bool uncontested = _noRejectEver(c); // an appeal alone does not clear it (§8.1)
        bool fullQuorum = _fullQuorum(c, p);
        uint256 n = c.topicKeys.length;
        for (uint256 i; i < n; ++i) {
            uint256 gid = x.indexReg.writeEntry(
                c.topicKeys[i],
                c.id,
                c.contentHash,
                c.metaHash,
                uncontested,
                fullQuorum,
                c.rulesVersion,
                c.guidelinesVersion,
                // M2.6-P0-1c: bind the entry to the reservation protecting it, so
                // deleting the entry frees the content even after the logic that
                // reserved it is gone.
                _dedupKey(c.contentHash, c.metaHash, c.topicKeys[i])
            );
            c.entryIds.push(gid); // the only safe removal handle (M2.6-P0-1)
        }
        c.isIndexed = true; // now live in the index (H-01 generation signal)
    }

    function _removeTarget(Moderation.Case storage c, Moderation.Case storage target, Ext memory x) private {
        // M2.6-P0-1c: a legacy target has no case record here — it belongs to a
        // superseded logic. Its permanent id is the whole binding, and the
        // registry no-ops if it has already been deleted, which is the same
        // concurrent-removal safety `isIndexed` gives the local path (H-01).
        if (c.legacyEntryId != 0) {
            x.indexReg.deleteEntry(c.topicKeys[0], c.legacyEntryId);
            return;
        }
        // H-01: no-op if the target is no longer indexed (a concurrent removal
        // already deleted it). Bound to a specific caseId at submit, so this can
        // only ever delete the exact entries the removal was approved against.
        if (!target.isIndexed) return;
        uint256 n = target.entryIds.length;
        for (uint256 i; i < n; ++i) {
            // Delete by the registry-minted global id, not by our local caseId:
            // another logic version may hold the same local id (M2.6-P0-1).
            // The deletion also frees that entry's reservation, so the removed
            // submission is resubmittable (M2.6-P0-1c) — no separate clear needed.
            x.indexReg.deleteEntry(target.topicKeys[i], target.entryIds[i]);
        }
        target.isIndexed = false;
    }

    /// @dev uncontested iff no Reject vote was revealed in ANY round (§8.1).
    function _noRejectEver(Moderation.Case storage c) private view returns (bool) {
        uint256 n = c.rounds.length;
        for (uint256 d; d < n; ++d) {
            if (c.rounds[d].rejectSeats != 0) return false;
        }
        return true;
    }

    /// @dev H-09: a case is "full quorum" — the precondition for the supersafe
    ///      view — iff no round fell back to arming below MIN_REVEALS after max
    ///      widen, and the deciding (final) round drew at least MIN_REVEALS
    ///      *independent* revealers (addresses, not seats — one multi-seat voter
    ///      must not satisfy quorum alone).
    function _fullQuorum(Moderation.Case storage c, Moderation.Params storage p) private view returns (bool) {
        uint256 n = c.rounds.length;
        for (uint256 d; d < n; ++d) {
            if (c.rounds[d].underQuorum) return false;
        }
        return c.rounds[c.depth].revealedCount >= p.minReveals;
    }

    /// @dev Release this case's content reservations so the content is submittable
    ///      again (REJECT/VOID). H-02 is enforced registry-side: the release no-ops
    ///      unless THIS logic and THIS case own the key.
    function _clearDedup(Moderation.Case storage c, Ext memory x) private {
        if (c.kind != Moderation.Kind.SUBMISSION) return;
        uint256 len = c.topicKeys.length;
        for (uint256 i; i < len; ++i) {
            x.indexReg.releaseContent(_dedupKey(c.contentHash, c.metaHash, c.topicKeys[i]), c.id);
        }
    }

    /// Must stay identical to `Moderation._dedupKey` — the registry keys
    /// reservations by this value and both sides compute it independently.
    function _dedupKey(bytes32 contentHash, bytes32 metaHash, bytes32 topicKey) private pure returns (bytes32) {
        return keccak256(abi.encode(contentHash, metaHash, topicKey));
    }
}
