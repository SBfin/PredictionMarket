// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Market, MarketState} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {console} from "forge-std/console.sol";
import {LogExpMath} from "./math/LogExpMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Utils - Utility functions for MarketMaker
contract Utils {

    using PoolIdLibrary for PoolKey;

    //////////////////////////
    //////// Getters ////////
    //////////////////////////
    function quoteCollateralNeededForTrade(
        PoolId poolId,
        uint256 amountNew,
        uint256 amountOld,
        uint256 collateralAmount,
        address collateralAddress
    ) public view returns (int256) {
        // Get collateral decimals
        uint256 collateralDecimals = OutcomeToken(collateralAddress).decimals();
        console.log("collateralDecimals:", collateralDecimals);

        // Calculate ratio first with more precision
        uint256 ratio = (amountOld * 1e18) / amountNew;
        console.log("ratio:", ratio);

        // Calculate ln(ratio)
        int256 lnRatio = LogExpMath.ln(int256(ratio));
        console.log("lnRatio:", lnRatio);

        // Scale result to match collateral decimals
        // For USDC (6 decimals):
        // lnRatio has 18 decimals
        // collateralAmount has 6 decimals
        // We want final result in 6 decimals
        int256 scaledResult = (lnRatio * int256(collateralAmount)) /
            int256(10 ** 18);
        console.log("scaledResult:", scaledResult);

        return scaledResult;
    }
    /*
    function getQuantitiesToMintAndInitialTick(uint256 probability) 
    public view returns (uint256 numberOfYes, uint256 numberOfNo, int24 tick) {
        numberOfYes = probability;
        numberOfNo = 100 - numberOfYes;
        ratio = (numberOfNo*1e18) / numberOfYes
        tick = logExpMath.ln(ratio)*1e18 / log.ExpMath

    }*/


}