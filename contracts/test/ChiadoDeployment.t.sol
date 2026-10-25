// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployChiado} from "../script/DeployChiado.s.sol";
import {ChiadoTestToken} from "../src/testnet/ChiadoTestToken.sol";

contract ChiadoDeploymentTest is Test {
    address constant DEPLOYER = address(0xA11CE);
    address constant REVIEWER = address(0xB0B);

    function test_tokenRefusesMainnetAndZeroInitialHolder() public {
        vm.chainId(100);
        vm.expectRevert(abi.encodeWithSelector(ChiadoTestToken.WrongChain.selector, 100));
        new ChiadoTestToken(DEPLOYER);
        vm.chainId(10200);
        vm.expectRevert(ChiadoTestToken.ZeroInitialHolder.selector);
        new ChiadoTestToken(address(0));
    }

    function test_faucetHasSixteenDecimalsAndMintsOnlyToCaller() public {
        vm.chainId(10200);
        ChiadoTestToken token = new ChiadoTestToken(DEPLOYER);
        assertEq(token.name(), "Chiado Moderation Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 16);
        assertEq(token.balanceOf(DEPLOYER), 1000e16);
        vm.prank(REVIEWER);
        token.faucet();
        assertEq(token.balanceOf(REVIEWER), 1000e16);
        assertEq(token.balanceOf(DEPLOYER), 1000e16);
        assertEq(token.totalSupply(), 2000e16);
    }

    function test_scriptRefusesWrongChainBeforeBroadcast() public {
        DeployChiado script = new DeployChiado();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChiado.ChiadoRequired.selector, 1));
        script.runChiado(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(DeployChiado.ChiadoRequired.selector, 1));
        script.run();
        Deploy.Params memory params = script.defaults(address(1));
        vm.expectRevert(abi.encodeWithSelector(DeployChiado.ChiadoRequired.selector, 1));
        script.deploy(params);
    }

    function test_scriptRefusesZeroDeployer() public {
        vm.chainId(10200);
        DeployChiado script = new DeployChiado();
        vm.expectRevert(DeployChiado.ZeroDeployer.selector);
        script.runChiado(address(0));
        vm.setEnv("CHIADO_DEPLOYER", vm.toString(address(0)));
        vm.expectRevert(DeployChiado.ZeroDeployer.selector);
        script.run();
    }

    function test_scriptDeploysLinkedStackAndSupportsActualStakeTransfer() public {
        vm.chainId(10200);
        vm.deal(DEPLOYER, 1 ether);
        DeployChiado script = new DeployChiado();
        (Deploy.Stack memory stack, ChiadoTestToken token) = script.runChiado(DEPLOYER);
        script.verify(stack);
        assertEq(stack.stakes.deployer(), DEPLOYER);
        assertEq(stack.index.deployer(), DEPLOYER);
        assertEq(address(stack.moderation.token()), address(token));
        assertEq(stack.stakes.stakeAmount(), 10e16);
        assertEq(token.balanceOf(DEPLOYER), 1000e16);
        vm.startPrank(DEPLOYER);
        token.approve(address(stack.stakes), 10e16);
        stack.stakes.stake();
        vm.stopPrank();
        assertEq(token.balanceOf(address(stack.stakes)), 10e16);
        assertEq(token.balanceOf(DEPLOYER), 990e16);
    }
}
