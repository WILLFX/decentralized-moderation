// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// @notice M2-0 smoke test: proves the toolchain compiles and runs, and pins the
///         two load-bearing environment facts (BZZ has 16 decimals; WAD math must
///         not conflate token base units with 1e18).
contract ScaffoldTest is Test {
    MockBZZ internal bzz;

    function setUp() public {
        bzz = new MockBZZ();
    }

    function test_toolchain_runs() public view {
        assertEq(bzz.symbol(), "xBZZ");
    }

    /// BZZ is 16 decimals — the whole point of the mock. If this ever reads 18,
    /// every "one token = 1e18" assumption downstream is silently wrong.
    function test_bzz_has_16_decimals() public view {
        assertEq(bzz.decimals(), 16, "xBZZ must be 16 decimals, not 18");
    }

    function test_mint_and_balance() public {
        uint256 oneToken = 10 ** bzz.decimals(); // 1e16, NOT 1e18
        bzz.mint(address(this), 5 * oneToken);
        assertEq(bzz.balanceOf(address(this)), 5 * oneToken);
        assertEq(oneToken, 1e16);
    }
}
