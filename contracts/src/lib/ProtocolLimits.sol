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
    /// seats could not be drawn in a block. H-11 pins a ruleset per case at
    /// submit, so every case opened under one would be permanently unfinalizable
    /// with no path forward — no attacker required, just a plausible parameter
    /// choice by governance.
    ///
    /// **Since M2.6-P1-2 the seat draw is no longer what binds this.** `realizeSeats`
    /// draws `DRAW_SEATS_PER_BATCH` seats per call behind a cursor, so the panel
    /// can be any size the rest of the machinery supports and only a BATCH has to
    /// fit — measured at 3,690,617 gas for 24 seats, 46% of the 8,000,000 ceiling.
    /// Before batching, a 48-seat panel was a single 7,239,700-gas transaction at
    /// 90% of it.
    ///
    /// **What binds it now is `_void`, and that is why 48 has not been raised.**
    /// `_void` still loops the entire `seatHolders` array with no cursor, and it
    /// runs INSIDE `closeReveal` — so exceeding the limit reverts the transition
    /// and strands the case in an expired REVEAL with no other exit. Per-holder
    /// disposal measures ~140,000 gas, flat (`test/spike/VoidCurve.t.sol`):
    ///
    ///     24 holders ->  3,515,321      96 holders -> 13,253,772
    ///     48 holders ->  6,761,469
    ///
    /// Break-even against the ceiling is ~57 holders; 48 sits at 85%. Raising the
    /// cap now would recreate exactly the class of unfinalizable case this bound
    /// exists to prevent, just on the VOID path instead of the draw path.
    ///
    /// > **Raising MAX_PANEL is now gated on batched VOID (work order P0-7), not
    /// > on P1-2.** When `_void` gets the same phase-plus-cursor treatment as
    /// > settlement and the draw, re-measure and raise this — at that point no
    /// > single unbatched loop remains that scales with panel size.
    uint256 internal constant MAX_PANEL = 48;
    uint256 internal constant MAX_RULE_TOPICS = 16;
    uint256 internal constant MAX_ARRAY_LEN = 16;
    uint256 internal constant MAX_WINDOW = 30 days;
    uint256 internal constant MAX_FREEZE = 365 days;
    uint256 internal constant MAX_BOND_MULT = 100;
    uint256 internal constant MAX_SEED_LAG = 250; // < 256-block blockhash window
    uint256 internal constant MAX_TOTAL_DRAWS = 4000; // reachable settlement bound
}
