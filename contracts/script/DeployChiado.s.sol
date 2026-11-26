// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {Deploy} from "./Deploy.s.sol";
import {ChiadoTestToken} from "../src/testnet/ChiadoTestToken.sol";

/// @notice Chiado-only deployment with explicit governance. The family starts inactive.
contract DeployChiado is Deploy {
    error ChiadoRequired(uint256 chainId);
    error ZeroDeployer();
    function requireChiado() internal view {
        if (block.chainid != 10200) revert ChiadoRequired(block.chainid);
    }
    function run(Moderation.Config memory cfg, uint256 stakeAmount, address authorizer, uint256 noticePeriod)
        public override returns (Stack memory)
    {
        requireChiado();
        return super.run(cfg, stakeAmount, authorizer, noticePeriod);
    }
    function deploy(Moderation.Config memory cfg, uint256 stakeAmount, address authorizer, uint256 noticePeriod)
        public override returns (Stack memory)
    {
        requireChiado();
        return super.deploy(cfg, stakeAmount, authorizer, noticePeriod);
    }
    function runChiado(address deployer, address authorizer, uint256 noticePeriod)
        external returns (Stack memory stack, ChiadoTestToken testToken)
    {
        requireChiado();
        if (deployer == address(0)) revert ZeroDeployer();
        vm.startBroadcast(deployer);
        testToken = new ChiadoTestToken(deployer);
        stack = deploy(defaults(address(testToken)), 10e16, authorizer, noticePeriod);
        vm.stopBroadcast();
    }
}
