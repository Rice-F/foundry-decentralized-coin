// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.s.sol";
import {DSCEngine} from "../../src/DCSEngine.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] public userWithDepositedList; // 已抵押用户的数组

    uint256 MAX_DEPOSIT_AMOUNT = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory tokenAddrList = dscEngine.getCollateralTokens();
        weth = ERC20Mock(tokenAddrList[0]);
        wbtc = ERC20Mock(tokenAddrList[1]);
    }

    function mintDsc(uint256 dscAmount, uint256 addressSeed) public {
        // 随机从已抵押用户列表中获取用户
        if (userWithDepositedList.length == 0) return;
        address sender = userWithDepositedList[
            addressSeed % userWithDepositedList.length
        ];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(sender);
        // 保持一定的比例以确保健康因子的合理
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);
        if (maxDscToMint < 0) return;

        dscAmount = bound(dscAmount, 0, uint256(maxDscToMint)); // DSC数量 < 抵押物数量
        if (dscAmount == 0) return;

        vm.startPrank(sender);
        dscEngine.mintDsc(dscAmount);
        vm.stopPrank();
    }

    function depositCollateral(
        uint256 collateralSeed,
        uint256 collateralAmount
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // 限制抵押物数量, [1 ,MAX_DEPOSIT_AMOUNT]之间
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_AMOUNT);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
        // 记录已抵押用户的地址，?没去重
        userWithDepositedList.push(msg.sender);
    }

    // 限制有效的抵押物类型
    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function redeemCollateral(
        uint256 collateralSeed,
        uint256 collateralAmount
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // 赎回限制
        uint256 maxCollateralAmountToRedeem = dscEngine
            .getCollateralBalanceOfUser(msg.sender, address(collateral));
        collateralAmount = bound(
            collateralAmount,
            0,
            maxCollateralAmountToRedeem
        );
        if (collateralAmount == 0) return;
        // vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), collateralAmount);
    }
}
