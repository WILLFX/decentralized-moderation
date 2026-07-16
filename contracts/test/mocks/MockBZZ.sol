// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Test double for the xBZZ token used by the Moderation contract.
/// @dev Swarm's BZZ / Gnosis xBZZ uses **16 decimals**, not the ERC20-typical 18
///      (verified against the Swarm token spec; the deployed Gnosis address must be
///      re-confirmed at M4 deployment). The contract's internal fixed-point math is
///      WAD (1e18) and independent of this — token amounts are base units and are
///      never assumed to be 1e18-per-token. This mock reproduces the 16-decimal
///      quirk so any accidental 1e18 "one token" assumption surfaces in tests.
contract MockBZZ is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock BZZ";
    }

    function symbol() public pure override returns (string memory) {
        return "xBZZ";
    }

    function decimals() public pure override returns (uint8) {
        return 16;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
