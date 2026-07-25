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
    /// A seat costs ~123,000 gas to draw, flat across panel size (measured over a
    /// 1,000-moderator tree; `test/spike/PanelCurve.t.sol`):
    ///
    ///     47 seats -> 5,784,708     80 seats ->  9,618,974
    ///     56 seats -> 6,992,608     96 seats -> 11,712,334
    ///     64 seats -> 7,825,247    128 seats -> 15,767,829
    ///
    /// The cost is dominated by per-seat storage writes — P0-2's collateral escrow
    /// and P0-3's staged weight update — not by tree descent, so it barely moves as
    /// the moderator set grows. Against the 8,000,000 single-transaction ceiling
    /// the break-even is ~65 seats; 64 already sits at 98% of it.
    ///
    /// 48 is chosen deliberately below that: 5.9M, 74% of the ceiling and ~35% of
    /// the Gnosis block limit, leaving room for the per-seat cost to keep growing
    /// (it rose twice in M2.6 alone). It still admits the shipped default ruleset,
    /// whose deepest target is 47.
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
