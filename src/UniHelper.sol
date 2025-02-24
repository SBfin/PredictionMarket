// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {Market} from "./types/MarketTypes.sol";
import {Utils} from "./Utils.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract UniHelper is Utils {
    using QuoterRevert for bytes;
    using PoolIdLibrary for PoolKey;
    
    IV4Quoter public immutable quoter;
    IPoolManager public immutable poolManager;

    constructor(address _quoter, address _poolManager) {
        quoter = IV4Quoter(_quoter);
        poolManager = IPoolManager(_poolManager);
    }

    function createUniswapPool(
        PoolKey memory pool
    ) external returns (PoolKey memory) {
        uint160 pricePoolQ = TickMath.getSqrtPriceAtTick(0);

        console.log("Pool price SQRTX96: %d", pricePoolQ);

        poolManager.initialize(pool, pricePoolQ);

        console.log("Pool created");

        return pool;
    }

    function simulateSwap(
        Market memory market,
        bool zeroForOne,
        int128 desiredOutcomeTokens
    ) public returns (int256 collateralNeeded, uint256 oppositeTokensToMint) {
        bool isSell = desiredOutcomeTokens < 0;
        uint128 absAmount = uint128(isSell ? -desiredOutcomeTokens : desiredOutcomeTokens);

        // Get opposite tokens needed
        oppositeTokensToMint = quoteOppositeTokens(
            market.poolKey,
            zeroForOne,
            absAmount,
            isSell
        );

        // Calculate collateral needed
        collateralNeeded = calculateCollateralNeeded(
            market,
            zeroForOne,
            absAmount,
            isSell
        );
    }

    function quoteOppositeTokens(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 absAmount,
        bool isSell
    ) public returns (uint256 oppositeTokensToMint) {
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: !zeroForOne,  // Flip zeroForOne for opposite direction
            exactAmount: absAmount,
            hookData: new bytes(0)
        });

        if (isSell) {
            try quoter.quoteExactInputSingle(params) returns (uint256 amountOut, uint256) {
                oppositeTokensToMint = amountOut;
            } catch (bytes memory reason) {
                oppositeTokensToMint = reason.parseQuoteAmount();
            }
        } else {
            try quoter.quoteExactOutputSingle(params) returns (uint256 amountIn, uint256) {
                oppositeTokensToMint = amountIn;
            } catch (bytes memory reason) {
                oppositeTokensToMint = reason.parseQuoteAmount();
            }
        }
    }

    function calculateCollateralNeeded(
        Market memory market,
        bool zeroForOne,
        uint128 absAmount,
        bool isSell
    ) public view returns (int256) {
        uint256 amountOld;
        uint256 amountNew;

        if (zeroForOne) {
            amountOld = market.poolKey.currency0.balanceOf(address(poolManager));
            amountNew = isSell ? amountOld + absAmount : amountOld - absAmount;
        } else {
            amountOld = market.poolKey.currency1.balanceOf(address(poolManager));
            amountNew = isSell ? amountOld + absAmount : amountOld - absAmount;
        }

        return quoteCollateralNeededForTrade(
            market.poolKey.toId(),
            amountNew,
            amountOld,
            market.totalCollateral,
            market.collateralAddress
        );
    }
}