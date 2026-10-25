// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Valueless faucet token for testing moderation on Chiado only.
/// @dev Unrestricted faucet supply is intentional. This token cannot measure
///      economic security or stand in for real BZZ balances.
contract ChiadoTestToken is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 1000e16;

    error WrongChain(uint256 chainId);
    error ZeroInitialHolder();

    constructor(address initialHolder) {
        if (block.chainid != 10200) revert WrongChain(block.chainid);
        if (initialHolder == address(0)) revert ZeroInitialHolder();
        _mint(initialHolder, FAUCET_AMOUNT);
    }

    function name() public pure override returns (string memory) {
        return "Chiado Moderation Test Token";
    }

    function symbol() public pure override returns (string memory) {
        return "TEST";
    }

    function decimals() public pure override returns (uint8) {
        return 16;
    }

    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
