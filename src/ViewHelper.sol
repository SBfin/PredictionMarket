// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Market, MarketState} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IMarketMakerHook} from "./interfaces/IMarketMakerHook.sol";
import {Utils} from "./Utils.sol";

contract ViewHelper is Utils {
    IMarketMakerHook public immutable hook;

    constructor(address _hook) {
        hook = IMarketMakerHook(_hook);
    }

    function getMarket(PoolId poolId) public view returns (Market memory) {
        return hook.markets(poolId);
    }

    function getMarkets() public view returns (Market[] memory) {
        uint256 count = hook.marketCount();
        Market[] memory allMarkets = new Market[](count);
        
        for (uint256 i = 0; i < count; i++) {
            PoolId poolId = hook.marketPoolIds(i);
            allMarkets[i] = hook.markets(poolId);
        }
        
        return allMarkets;
    }

    function getTokenSupplies(PoolId poolId) public view returns (uint256 yesSupply, uint256 noSupply) {
        Market memory market = hook.markets(poolId);
        yesSupply = OutcomeToken(market.yesToken).totalSupply();
        noSupply = OutcomeToken(market.noToken).totalSupply();
    }

    function getTokenValues(PoolId poolId) public view returns (uint256 yesValue, uint256 noValue, uint256 yesProbability) {
        Market memory market = hook.markets(poolId);
        
        (uint256 yesSupply, uint256 noSupply) = getTokenSupplies(poolId);
        uint256 totalCollateral = market.totalCollateral;
        
        uint256 collateralDecimals = OutcomeToken(market.collateralAddress).decimals();
        uint256 scaledCollateral = totalCollateral * (10 ** (18 - collateralDecimals));
        
        yesValue = (scaledCollateral * 1e18) / yesSupply;
        noValue = (scaledCollateral * 1e18) / noSupply;
        yesProbability = (yesValue * 1e18) / (yesValue + noValue);
    }

    function getClaimedTokens(PoolId poolId) public view returns (uint256) {
        return hook.claimedTokens(poolId);
    }

    function quoteCollateral(
        PoolId poolId,
        bool zeroForOne,
        uint256 desiredOutcomeTokens
    ) public view returns (int256) {
        Market memory market = hook.markets(poolId);
        
        // Get current token balances
        uint256 amountOld;
        if (zeroForOne) {
            amountOld = market.yesToken.totalSupply();
        } else {
            amountOld = market.noToken.totalSupply();
        }
        
        // Calculate new amount after trade
        uint256 amountNew = desiredOutcomeTokens > 0 
            ? amountOld + desiredOutcomeTokens  // Buying tokens
            : amountOld - desiredOutcomeTokens; // Selling tokens
            
        return quoteCollateralNeededForTrade(
            poolId,
            amountNew,
            amountOld,
            market.totalCollateral,
            market.collateralAddress
        );
    }
}