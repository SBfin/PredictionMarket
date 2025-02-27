// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Market, MarketState} from "../types/MarketTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {OutcomeToken} from "../OutcomeToken.sol";
// @title IMarketMakerHook - Interface for MarketMakerHook
interface IMarketMakerHook {
    // State variables (automatically get view functions)
    function markets(PoolId poolId) external view returns (Market memory);
    function marketCount() external view returns (uint256);
    function marketPoolIds(uint256 index) external view returns (PoolId);
    function claimedTokens(PoolId poolId) external view returns (uint256);
    function hasClaimed(PoolId poolId, address user) external view returns (bool);



    // Core functions
    function createMarketWithCollateralAndLiquidity(
        address oracle,
        address creator,
        address collateralAddress,
        uint256 collateralAmount
    ) external returns (PoolId);
    
    function executeSwap(
        PoolId poolId,
        bool zeroForOne,
        int128 desiredOutcomeTokens
    ) external;

    function resolveMarket(PoolId poolId, bool outcome) external;
    function claimWinnings(PoolId poolId) external;

    // Events
    event MarketCreated(
        PoolId indexed poolId,
        address indexed oracle,
        address indexed creator,
        address yesToken,
        address noToken,
        MarketState state,
        bool outcome,
        uint256 totalCollateral,
        address collateralAddress
    );
    event MarketResolved(PoolId indexed poolId, bool outcome);
    event MarketCancelled(PoolId indexed poolId);
    event WinningsClaimed(PoolId indexed poolId, address indexed user, uint256 amount);
    event SwapExecuted(PoolId poolId, bool zeroForOne, int128 desiredOutcomeTokens, address sender);
}