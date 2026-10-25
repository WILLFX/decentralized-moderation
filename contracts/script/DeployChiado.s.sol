// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Deploy} from "./Deploy.s.sol";
import {ChiadoTestToken} from "../src/testnet/ChiadoTestToken.sol";

/// @notice Deploys a valueless test token and the reviewed stack on Chiado.
/// @dev Defaults and link verification are inherited unchanged. Every deployment
///      entry point checks Chiado. The default run() creates the faucet token.
///      run() reads public CHIADO_DEPLOYER; runChiado(address) takes that address
///      explicitly for automation. Neither path reads a key; signing is external.
contract DeployChiado is Deploy {
    error ChiadoRequired(uint256 chainId);
    error ZeroDeployer();

    function requireChiado() internal view {
        if (block.chainid != 10200) revert ChiadoRequired(block.chainid);
    }

    function deploy(Params memory params) public override returns (Stack memory) {
        requireChiado();
        return super.deploy(params);
    }

    function run() external override returns (Stack memory stack) {
        requireChiado();
        (stack,) = deployChiado(vm.envAddress("CHIADO_DEPLOYER"));
    }

    function runChiado(address deployer) external returns (Stack memory stack, ChiadoTestToken testToken) {
        return deployChiado(deployer);
    }

    function deployChiado(address deployer) internal returns (Stack memory stack, ChiadoTestToken testToken) {
        requireChiado();
        if (deployer == address(0)) revert ZeroDeployer();

        vm.startBroadcast(deployer);
        testToken = new ChiadoTestToken(deployer);
        stack = deploy(defaults(address(testToken)));
        vm.stopBroadcast();
    }
}
