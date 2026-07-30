// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ProtocolLimits
/// @notice The immutable caps governance may tune numbers *within* (H-11), held
///         in one place so the contract that VALIDATES a ruleset and the contract
///         that ENFORCES it cannot drift apart.
///
///         M2.6 moved ruleset authoring into `RulesetGovernor`, which left the
///         caps needed by two contracts. They were `internal constant` on
///         `Moderation`, so the governor could not see them: duplicating the
///         numbers would have created exactly the failure this milestone keeps
///         finding — a safety bound stated in two places, silently diverging.
///
///         `internal constant` in a library is inlined at compile time, so this
///         costs no runtime call and no bytecode on either side.
library ProtocolLimits {
    /// WAD scale for fractional parameters (1e18 = 100%).
    uint256 internal constant WAD = 1e18;

    uint256 internal constant MAX_RULE_DEPTH = 8;
    uint256 internal constant MAX_RULE_WIDEN = 8;
    /// Per-depth commit target. **Set from measurement, not from a round number.**
    ///
    /// ## What currently sets this bound
    ///
    /// It has moved twice, so the useful thing to know is which loop binds it now:
    /// **`MAX_TOTAL_DRAWS`, the aggregate-reachability check in
    /// `_validateParams` — not any single transaction.** Since M2.6-P0-7 no
    /// unbatched loop in `Moderation` scales with panel size. The three that did
    /// are all behind bounded cursors:
    ///
    ///     seat draw   `realizeSeats`  P1-2   24 seats/call, 3,664,261 gas (46%)
    ///     settlement  `claim`         H-04   40 seats/call
    ///     VOID        `claim`         P0-7   opening is O(1) at 5,849 gas;
    ///                                        disposal 12/call, 1,347,418 gas (17%)
    ///
    /// So a larger panel now costs more TRANSACTIONS, not a bigger one, and the
    /// per-transaction ceiling no longer divides down into a seat count.
    ///
    /// ## History, because the number moved for real reasons
    ///
    /// It was **512**, which let `_validateParams` accept a ruleset whose seats
    /// could not be drawn in a block. H-11 pins a ruleset per case at submit, so
    /// every case opened under one was permanently unfinalizable with no path
    /// forward — no attacker needed, just a plausible parameter choice.
    ///
    /// It was then **48**, set from the measured per-seat draw cost against the
    /// 8,000,000 single-transaction ceiling. That cost rose three times in M2.6
    /// (P0-2 escrow, P0-3 staged weight, P0-5 obligation handle), ~123k -> ~151k
    /// per seat, taking a cap-sized panel from 74% to 90% of the ceiling. P1-2
    /// batched the draw; P0-7 batched VOID disposal, which was the remaining
    /// unbatched loop and had been binding at ~140k per holder (48 holders =
    /// 6,761,469, 85% of the ceiling — and worse than a costly settlement, because
    /// `_void` ran inside `closeReveal` and a revert stranded the case).
    ///
    /// **128** is chosen with margin under what the aggregate check permits: a
    /// ruleset holding this target across many depths still trips
    /// `MAX_TOTAL_DRAWS` and is rejected, so the two bounds compose rather than
    /// overlap. `GasBounds` reads this constant directly — raising it again
    /// without re-measuring fails the suite.
    ///
    /// Re-derived at M2.6-P0-3d, which changed what a draw ATTEMPT costs and does:
    /// the draw no longer writes the sortition tree, so it pays extra descents
    /// instead of exclusion-plus-restore writes, and `ATTEMPTS_PER_SEAT` rose from
    /// 2 to 6. Both directions were measured and the seat-draw batch came out
    /// slightly CHEAPER (3,746,905 -> 3,664,261), so 128 and 24 both stand. The
    /// extra budget is only ever spent under scarcity; in every dense scenario the
    /// panel fills long before the cap binds, so gas at 6 equals gas at 2.
    ///
    /// > If a future item adds an unbatched per-seat or per-holder loop, THAT
    /// > becomes the binding constraint again and this number must be re-derived
    /// > from it. Check `GAS_BUDGETS.md` for the current measurements before
    /// > trusting the figure above.
    uint256 internal constant MAX_PANEL = 128;
    uint256 internal constant MAX_RULE_TOPICS = 16;
    uint256 internal constant MAX_ARRAY_LEN = 16;
    uint256 internal constant MAX_WINDOW = 30 days;
    uint256 internal constant MAX_FREEZE = 365 days;
    /// M2.6-P0-8: upper bound on `freezeCap`, the freezing-power multiplier.
    /// `_validateParams` checked only `freezeCap >= WAD` — a LOWER bound with no
    /// upper one — so an accepted ruleset could overflow `FreezeMath` inside
    /// `_settleInit`, which runs before a case reaches any recoverable state.
    /// Every settlement attempt would then revert, permanently. `MAX_FREEZE`
    /// bounded `freezeBase` and `failedRevealFreeze` but never the AMPLIFIED
    /// result, which is the product of the two.
    uint256 internal constant MAX_FREEZE_MULTIPLIER = 100 * WAD;
    uint256 internal constant MAX_BOND_MULT = 100;
    uint256 internal constant MAX_SEED_LAG = 250; // < 256-block blockhash window
    /// Reachable settlement bound: the most seat draws any accepted ruleset can
    /// produce across one case, and therefore the most seats settlement can have to
    /// dispose.
    ///
    /// M2.6-P1-3: what this bounds is only as good as how it is computed. The check
    /// iterated the `commitTargets` ARRAY while `Moderation._commitTarget` clamps to
    /// the last entry at deeper depths, so a short array was validated over the
    /// entries it gave and run over more depths than that. It now iterates
    /// `d = 0..maxDepth` over the runtime-clamped target, as
    /// `Σ_{d} attempts × runtimeTarget(d)` with `attempts` one named per-depth
    /// budget — so a new retry axis enters the product instead of needing a term of
    /// its own.
    ///
    /// The default ruleset reaches `4 × (5+11+23+47) = 344`. This number is the
    /// ceiling for anything governance can accept, not that figure.
    uint256 internal constant MAX_TOTAL_DRAWS = 4000;
}
