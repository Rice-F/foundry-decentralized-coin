// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDCS.s.sol";
import {DSCEngine} from "../../src/DCSEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DCSEngineTest is Test {
    DeployDSC deployDSC;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;

    address weth;
    address ethUsdPriceFeed;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployDSC = new DeployDSC();

        (dsc, dscEngine, helperConfig) = deployDSC.run();
        (ethUsdPriceFeed, weth, , , ) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE); // 类型转换，转换为符合ERC20的代币
    }

    /**
     * test
     */
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15e18 * 2000/ETH = 30000e18
        uint256 expectedUsd = 30000e18;
        // console.log("weth", weth);
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testDepositCollateralWithZero() public {
        vm.startPrank(USER); // 以下操作都使用该模拟用户
        // ERC20Mock(weth) 将weth地址转为ERC20Mock合约
        // approve授权 USER =》address(dscEngine)
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
