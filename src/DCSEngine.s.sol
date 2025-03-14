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
    error DSCEngine__HealthFactorIsBroken(); // 健康因子 < 1
    error DSCEngine__MintFailed(); // 铸造失败
    error DSCEngine__HealthFactorOk(); // 健康因子 > 1
    error DSCEngine__HealthFactorNotImproved(); // 健康因子没有得到改善

    /**
     * State Variables
     */
    uint256 private constant PRECISION = 1e18; // 精度
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // priceFeed精度
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 清算阈值 => 50%
    uint256 private constant LIQUIDATION_PRECISION = 100; // 清算阈值精度
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 健康因子
    uint256 private constant LIQUIDATION_BONUS = 10; // 清算奖励

    mapping(address token => address priceFeed) private s_tokenToPriceFeeds; // {token contract地址: 对应的priceFeed合约地址}
    mapping(address user => mapping(address token => uint256 amount)) // {user: {token类型1: amount, token类型2: amount}}
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // {user: mint的DSC数量}

    DecentralizedStableCoin private immutable i_dsc; // DSC合约
    address[] private s_tokenAddrList; // 所有支持的代币的合约地址

    /**
     * Event
     */
    // 抵押
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    // 赎回
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
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
            s_tokenAddrList.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * External Functions
     */
    // 抵押并铸造DSC
    function depositCollateralAndMintDsc(
        address collateralAddr,
        uint256 collateralAmount,
        uint256 dscAmountToMint
    ) external {
        depositCollateral(collateralAddr, collateralAmount);
        mintDsc(dscAmountToMint);
    }

    // 抵押
    function depositCollateral(
        address collateralAddr,
        uint256 collateralAmount // 抵押物数量
    )
        public
        moreThanZero(collateralAmount)
        isAllowedToken(collateralAddr)
        nonReentrant
    {
        // 存储抵押人抵押的代币数量 user: {token1: amount, token2: amount}
        s_collateralDeposited[msg.sender][collateralAddr] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralAddr, collateralAmount);
        // 转移代币至当前合约 IERC20合约中的transferFrom(from, to, value)
        bool success = IERC20(collateralAddr).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // burn并赎回
    function redeemCollateralForDsc(
        address collateralAddr,
        uint256 collateralAmount,
        uint256 dscAmountToBurn
    ) external {
        burnDsc(dscAmountToBurn);
        redeemCollateral(collateralAddr, collateralAmount);
    }

    // 赎回
    function redeemCollateral(
        address collateralAddr,
        uint256 collateralAmount
    ) public moreThanZero(collateralAmount) nonReentrant {
        // // 变更用户抵押的代币数量
        // s_collateralDeposited[msg.sender][
        //     collateralAddr
        // ] -= collateralAmount;
        // emit CollateralRedeemed(
        //     msg.sender,
        //     collateralAddr,
        //     collateralAmount
        // );
        // // 将代币从当前合约转出 IERC20合约中的transfer(to, value)
        // bool success = IERC20(collateralAddr).transfer(
        //     msg.sender,
        //     collateralAmount
        // );
        // if (!success) {
        //     revert DSCEngine__TransferFailed();
        // }
        _redeemCollateral(
            collateralAddr,
            collateralAmount,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // mint
    function mintDsc(
        uint256 dscAmountToMint
    ) public moreThanZero(dscAmountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // burn
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // s_DSCMinted[msg.sender] -= amount;
        // // 将用户的DSC转移至当前合约
        // bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // if (!success) {
        //     revert DSCEngine__TransferFailed();
        // }
        // i_dsc.burn(amount);
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 清算
    /**
     * user 抵押人
     * debtToCover 债务DSC对应的美元价值
     */
    function liquidate(
        address collateralAddr,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // 清算前健康因子
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // 债务DSC对应的token数量
        uint256 tokenAmountFromDebtToCover = getTokenAmountFromUsd(
            collateralAddr,
            debtToCover
        );
        // 奖励 = 债务DSC对应的token数量 * 10%
        uint256 bonusCollateral = (tokenAmountFromDebtToCover *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // 清算人获得的所有抵押物 = 债务DSC对应的token数量 + 奖励
        uint256 totalCollateralToRedeem = tokenAmountFromDebtToCover +
            bonusCollateral;
        // 将清算人获得的抵押物从当前合约转出给清算人
        _redeemCollateral(
            collateralAddr,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        // burn
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor < startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 健康系数
    function getHealthFactor() external {}

    /**
     * Private & Internal View Functions
     */
    // burn
    function _burnDsc(
        uint256 amount,
        address burnFrom,
        address dscFrom
    ) private {
        s_DSCMinted[burnFrom] -= amount;
        // 将用户的DSC转移至当前合约
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    // 赎回collateral
    function _redeemCollateral(
        address collateralAddr,
        uint256 collateralAmount,
        address from,
        address to
    ) private {
        // 变更抵押人抵押的代币数量
        s_collateralDeposited[from][collateralAddr] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralAddr, collateralAmount);
        // 将代币从当前合约转出 IERC20合约中的transfer(to, value)
        bool success = IERC20(collateralAddr).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

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
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) private pure returns (uint256) {
        // 没有DSC铸造，表示无负债，健康因子无穷大
        if (totalDscMinted == 0) return type(uint256).max;
        // （抵押物的美元价值 * 健康阈值）/ 清算精度
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken();
        }
    }

    /**
     * Public & External View Functions
     */
    // 根据当前债务计算token数量
    function getTokenAmountFromUsd(
        address collateralAddr,
        uint256 debtToCover
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[collateralAddr]
        );
        (, int256 tokenPrice, , , ) = priceFeed.latestRoundData();
        // DSC对应的美元价值 / token对应的美元价值
        return
            (debtToCover * PRECISION) /
            (uint256(tokenPrice) * ADDITIONAL_FEED_PRECISION);
    }

    // 计算user的总token资产价值多少美元（所有token类型资产累加）
    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_tokenAddrList.length; i++) {
            address token = s_tokenAddrList[i];
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

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getDscMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getLiquidationData()
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return (
            LIQUIDATION_THRESHOLD,
            LIQUIDATION_PRECISION,
            LIQUIDATION_BONUS
        );
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_tokenAddrList;
    }

    // 获取用户所有抵押的代币数量
    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
