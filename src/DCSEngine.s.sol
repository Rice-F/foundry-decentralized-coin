// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.s.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    /**
     * Error
     */
    error DSCEngine__NeedsMoreThanZero(); // >0
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength(); // token地址 => priceFeed地址
    error DSCEngine__TokenNotAllowed(); // token地址不合法
    error DSCEngine__TransferFailed(); // 转账失败
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor); // 健康因子小于1
    error DSCEngine__MintFailed(); // 铸造失败

    /**
     * State Variables
     */
    uint256 private constant PRECISION = 1e18; // 精度
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // priceFeed精度
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 清算阈值 => 50%
    uint256 private constant LIQUIDATION_PRECISION = 100; // 清算阈值精度
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_tokenToPriceFeeds; // {token contract地址: 对应的priceFeed合约地址}
    mapping(address user => mapping(address token => uint256 amount)) // {user: {token类型1: amount, token类型2: amount}}
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // {user: mint的DSC数量}

    DecentralizedStableCoin private immutable i_dsc; // DSC合约
    address[] private s_collateralTokens; // 所有支持的代币的合约地址

    /**
     * Event
     */
    // 抵押
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /**
     * Modifiers
     */
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /**
     * Constructor
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_tokenToPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * External Functions
     */
    // 抵押并铸造DSC
    function depositCollateralAndMintDsc() external {}

    // 抵押
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // 存储用户抵押的代币数量 user: {token1: amount, token2: amount}
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        // 转移代币至当前合约 transferFrom(from, to, value)
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // 赎回
    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    // mint
    function mintDsc(
        uint256 amountDscToMint
    ) external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // burn
    function burnDsc() external {}

    // 清算
    function liquidate() external {}

    // 健康系数
    function getHealthFactor() external {}

    /**
     * Private & Internal View Functions
     */
    // 获取user账户信息
    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    // 计算健康因子
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        // （抵押物的美元价值 * 健康阈值）/ 清算精度
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    /**
     * Public & External View Functions
     */
    // 计算user的总token资产价值多少美元（所有token类型资产累加）
    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    // 计算token对应的美元价值
    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // price的精度是8位，amount的精度是18位，price * 1e10 * amount / 1e18
        // uint256(price) * amount / 1e8;
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
