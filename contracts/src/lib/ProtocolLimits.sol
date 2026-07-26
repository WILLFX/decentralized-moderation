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
    /// This was 512, which meant `_validateParams` would accept a ruleset whose
    /// `realizeSeats` cannot fit in a block. H-11 pins a ruleset per case at
    /// submit, so every case opened under such a ruleset would be permanently
    /// unfinalizable with no path forward — no attacker required, just a
    /// plausible parameter choice by governance.
    ///
    /// A seat costs ~151,000 gas to draw, flat across panel size (measured over a
    /// 1,000-moderator tree; `test/spike/PanelCurve.t.sol`). The cost is dominated
    /// by per-seat STORAGE WRITES, not by tree descent, so it barely moves as the
    /// moderator set grows — but it has risen three times in M2.6 as each item
    /// added one:
    ///
    ///     after P0-2/P0-3 (escrow + staged weight)   ~123,000/seat
    ///     after P0-5      (per-case obligation slot) ~151,000/seat
    ///
    /// Against the 8,000,000 single-transaction ceiling that puts the break-even
    /// at ~53 seats. **48** is kept — a panel at the cap measures 7,239,700, which
    /// still clears the ceiling, and the shipped default ruleset's deepest target
    /// is 47.
    ///
    /// **The margin is gone, and that is the finding.** When this cap was set one
    /// item ago it sat at 74% of the ceiling; P0-5's per-case obligation slot took
    /// it to 90%. Lowering the cap to restore the margin would force the shipped
    /// ruleset's 47-seat final panel down with it — a change to the appeal
    /// ladder's statistics, which is a product decision and not a side effect a
    /// storage-layout change should make. So the cap holds and the constraint
    /// moves to what may be added next:
    ///
    /// > **No further per-seat storage write may land before cursor-based seat
    /// > drawing (work order P1-2).** One more slot per seat (~+24k) puts a
    /// > 48-seat panel at ~8.4M — over the ceiling — and every accepted ruleset at
    /// > the cap becomes unexecutable, with H-11 pinning it per case. P1-2 was the
    /// > precondition for RAISING the cap; it is now the precondition for keeping
    /// > it.
    ///
    /// **Raising this requires cursor-based seat drawing (work order P1-2) to land
    /// first.** `realizeSeats` attempts a whole commit target in one transaction;
    /// until that is batched, the cap IS the block limit divided by the per-seat
    /// cost, and no larger value can be made safe by validation alone.
    /// `GasBounds.test_max_panel_draw_fits_the_ceiling` asserts this bound rather
    /// than assuming it.
    uint256 internal constant MAX_PANEL = 48;
    uint256 internal constant MAX_RULE_TOPICS = 16;
    uint256 internal constant MAX_ARRAY_LEN = 16;
    uint256 internal constant MAX_WINDOW = 30 days;
    uint256 internal constant MAX_FREEZE = 365 days;
    uint256 internal constant MAX_BOND_MULT = 100;
    uint256 internal constant MAX_SEED_LAG = 250; // < 256-block blockhash window
    uint256 internal constant MAX_TOTAL_DRAWS = 4000; // reachable settlement bound
}
