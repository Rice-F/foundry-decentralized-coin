// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.s.sol";
import {DSCEngine} from "../src/DCSEngine.s.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddrList;
    address[] public priceFeedAddrList;

    function run()
        external
        returns (DecentralizedStableCoin, DSCEngine, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address weth,
            address wbtcUsdPriceFeed,
            address wbtc,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        tokenAddrList = [weth, wbtc];
        priceFeedAddrList = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey); // 使用anvil的默认私钥
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine dscEngine = new DSCEngine(
            tokenAddrList,
            priceFeedAddrList,
            address(dsc)
        );
        dsc.transferOwnership(address(dscEngine)); // onlyOwner msg.sender => dscEngine
        vm.stopBroadcast();
        return (dsc, dscEngine, helperConfig);
    }
}
