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

    address ethUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // 抵押物数量
    uint256 public constant STARTING_USER_BALANCE = 10 ether; // 用户初始余额
    uint256 public constant DSC_MINTED = 1 ether; // DSC数量

    function setUp() public {
        deployDSC = new DeployDSC();

        (dsc, dscEngine, helperConfig) = deployDSC.run();
        (ethUsdPriceFeed, weth, , , ) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE); // 类型转换，转换为符合ERC20的代币
    }

    /**
     * test
     */
    // constructor
    function testRevertIfTokenLengthIsNotEqualPriceFeedLength() public {
        address[] memory tokenAddrList = new address[](1);
        address[] memory priceFeedAddrList = new address[](2);
        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddrList, priceFeedAddrList, address(dsc));
    }

    function testGetTokenAmountFromUsd() public view {
        // 在helperConfig中，ETH_USD_PRICE = 2000e8
        uint256 usdAmount = 100e18;
        uint256 expectedTokenAmount = 5e16;
        uint256 actualTokenAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            usdAmount
        );
        assertEq(expectedTokenAmount, actualTokenAmount);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15e18 * 2000/ETH = 30000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    // 抵押0个抵押物
    function testDepositCollateralWithZero() public {
        vm.startPrank(USER); // 以下操作都使用该模拟用户
        // ERC20Mock(weth) 将weth地址转为ERC20Mock合约
        // approve授权 USER =》address(dscEngine)
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    // 抵押超出接收范围的抵押物
    function testRevertsWithOutOfScopeCollateral() public {
        ERC20Mock token = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(token), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // modifier 授权+抵押
    modifier depositedCollateral(uint256 collateralAmount) {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(weth, collateralAmount);
        vm.stopPrank();
        _;
    }

    // 抵押并获取账户信息
    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral(uint256(AMOUNT_COLLATERAL))
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(USER);
        // 根据抵押物美元金额计算抵押物数量
        uint256 expectedCollateralAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, 0); // 只调用了depositCollateral，没有调用mintDsc
        assertEq(expectedCollateralAmount, AMOUNT_COLLATERAL);
    }

    // modifier 授权+抵押+mint
    modifier depositedAndMint(uint256 collateralAmount, uint256 mintAmount) {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(weth, collateralAmount);
        dscEngine.mintDsc(mintAmount);
        vm.stopPrank();
        _;
    }

    // mint dsc并获取账户信息
    function testMintAndGetAccountInfo()
        public
        depositedAndMint(uint256(AMOUNT_COLLATERAL), uint256(DSC_MINTED))
    {
        uint256 expectedTotalDscMinted = dscEngine.getDscMinted(USER);
        assertEq(expectedTotalDscMinted, DSC_MINTED);
    }

    // 计算健康因子
    function testCalculateHealthFactor()
        public
        depositedAndMint(uint256(AMOUNT_COLLATERAL), uint256(DSC_MINTED))
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(USER);
        (
            uint256 LIQUIDATION_THRESHOLD,
            uint256 LIQUIDATION_PRECISION,

        ) = dscEngine.getLiquidationData();
        uint256 currentHealthFactor = (((collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) * 1e18) /
            totalDscMinted;
        uint256 expectedHealthFactor = dscEngine.getHealthFactor(USER);
        assertEq(currentHealthFactor, expectedHealthFactor);
    }

    // 测试健康因子是否broke
    function testIfHealthFactorIsBroken()
        public
        depositedCollateral(uint256(AMOUNT_COLLATERAL))
    {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsBroken.selector);
        dscEngine.mintDsc(25000 ether);
    }

    // 测试合理抵押物数量
    function testLiquidateFactorOk()
        public
        depositedAndMint(uint256(AMOUNT_COLLATERAL), uint256(DSC_MINTED))
    {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(address(weth), USER, DSC_MINTED);
    }

    function testRedeemDsc()
        public
        depositedAndMint(uint256(AMOUNT_COLLATERAL), uint256(DSC_MINTED))
    {}
}
