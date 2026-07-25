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
    uint256 internal constant MAX_PANEL = 512; // per-depth commit target
    uint256 internal constant MAX_RULE_TOPICS = 16;
    uint256 internal constant MAX_ARRAY_LEN = 16;
    uint256 internal constant MAX_WINDOW = 30 days;
    uint256 internal constant MAX_FREEZE = 365 days;
    uint256 internal constant MAX_BOND_MULT = 100;
    uint256 internal constant MAX_SEED_LAG = 250; // < 256-block blockhash window
    uint256 internal constant MAX_TOTAL_DRAWS = 4000; // reachable settlement bound
}
