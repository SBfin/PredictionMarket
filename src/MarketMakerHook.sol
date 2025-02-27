pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Market, MarketState} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {console} from "forge-std/console.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {LogExpMath} from "./math/LogExpMath.sol";
import {Utils} from "./Utils.sol";
import {IMarketMakerHook} from "./interfaces/IMarketMakerHook.sol";
import {UniHelper} from "./UniHelper.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @title CollateralHook - Hook for collateral token management
/// Users swap only through this hook
/// The pool contains ERC20 Tokens Yes and No
/// At pool creation, the pool is initialized with a fixed amount of ERC20 Tokens by the creator
/// After resolution, the pool freezes swaps operations and users can claim based on their pro-quota of the outcome tokens
// Token contract

contract MarketMakerHook is BaseHook, IMarketMakerHook, Utils {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint160;
    IPoolManager public poolm;
    PoolModifyLiquidityTest public posm;
    IV4Quoter public quoter;
    int24 public TICK_SPACING = 100;
    UniHelper public immutable uniHelper;
    PoolSwapTest public poolSwapTest;
    // Market ID counter
    uint256 private _marketCount;
    mapping(uint256 => PoolId) private _marketPoolIds;
    mapping(PoolId => Market) private _markets;
    /// @notice Mapping to track which addresses have claimed their winnings
    mapping(PoolId => mapping(address => bool)) private _hasClaimed;

    /// @notice Mapping to track claimed tokens (separate from liquidity tokens)
    mapping(PoolId => uint256) private _claimedTokens;
    error DirectSwapsNotAllowed();
    error DirectLiquidityNotAllowed();
    error NotOracle();
    error MarketAlreadyResolved();
    error NotOracleOrCreator();
    error MarketNotResolved();
    error NoTokensToClaim();
    error AlreadyClaimed();

    constructor(
        IPoolManager _poolManager,
        PoolModifyLiquidityTest _posm,
        PoolSwapTest _poolSwapTest,
        IV4Quoter _quoter,
        UniHelper _uniHelper
    ) BaseHook(_poolManager) {
        poolm = IPoolManager(_poolManager);
        posm = PoolModifyLiquidityTest(_posm);
        quoter = IV4Quoter(_quoter);
        poolSwapTest = PoolSwapTest(_poolSwapTest);
        uniHelper = _uniHelper;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _markets[poolId];
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _markets[poolId];
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        // Enforce full range positions only
        require(
            params.tickLower == TickMath.minUsableTick(TICK_SPACING) &&
            params.tickUpper == TickMath.maxUsableTick(TICK_SPACING),
            "Only full range positions allowed"
        );
        
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _markets[poolId];
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        // Only allow removals after market is resolved
        if (market.state != MarketState.Resolved) {
            revert DirectLiquidityNotAllowed();
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    //////////////////////////

    function createMarketWithCollateralAndLiquidity(
        address oracle,
        address creator,
        address collateralAddress,
        uint256 collateralAmount
    ) public returns (PoolId) {
        PoolId poolId = createMarketAndDepositCollateral(
            oracle,
            creator,
            collateralAddress,
            collateralAmount
        );
        _addInitialOutcomeTokensLiquidity(poolId);
        return poolId;
    }

    function createMarketAndDepositCollateral(
        address oracle,
        address creator,
        address collateralAddress,
        uint256 collateralAmount
    ) public returns (PoolId) {
        // Create two tokens yes and no
        // Create a pool with the two tokens
        // Initialize the pool with a fixed amount of tokens
        // Set the hook for the pool (this contract)
        // Create YES token
        bytes32 yesSalt = bytes32(uint256(1));  // Small number
        bytes32 noSalt = bytes32(uint256(type(uint256).max));  // Very large number
        
        // Deploy tokens with CREATE2
        OutcomeToken yesToken = new OutcomeToken{salt: yesSalt}("Market YES", "YES");
        OutcomeToken noToken = new OutcomeToken{salt: noSalt}("Market NO", "NO");
        
        // Verify addresses - this should now passx
        assert(address(yesToken) < address(noToken));
        console.log("YES token address:", address(yesToken));
        console.log("NO token address:", address(noToken));
    

        // make token0 the lower address
        assert(address(yesToken) < address(noToken));
        /*
        OutcomeToken token0;
        OutcomeToken token1;
        if (address(yesToken) < address(noToken)) {
            console.log("yesToken is token0");
            token0 = OutcomeToken(address(yesToken));
            token1 = OutcomeToken(address(noToken));
        } else {
            console.log("noToken is token0");
            token0 = OutcomeToken(address(noToken));
            token1 = OutcomeToken(address(yesToken));
        }*/

        // max approve to pool manager for both tokens
        yesToken.approve(address(poolSwapTest), type(uint256).max);
        noToken.approve(address(poolSwapTest), type(uint256).max);


        // Create a pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(yesToken)),
            currency1: Currency.wrap(address(noToken)),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });

        // transfer collateral from the msg.sender to this contract
        if (collateralAddress != address(0) && collateralAmount > 0) {
            IERC20(collateralAddress).transferFrom(
                msg.sender,
                address(this),
                collateralAmount
            );
        }

        uniHelper.createUniswapPool(poolKey);

        // poolId
        PoolId poolId = poolKey.toId();
        console.log("fetching poolId");
        // save the market. Reverts if market already exists
        _markets[poolId] = Market({
            poolKey: poolKey,
            oracle: oracle,
            creator: creator,
            yesToken: yesToken,
            noToken: noToken,
            state: MarketState.Active,
            outcome: false,
            totalCollateral: collateralAmount,
            collateralAddress: collateralAddress
        });
        console.log("Market created");

        // Store poolId for index lookup
        _marketPoolIds[_marketCount] = poolId;
        _marketCount++;

        return poolId;
    }

    //////////////////////////
    //// Internal functions //
    //////////////////////////

    function _addInitialOutcomeTokensLiquidity(PoolId poolId) internal {
        // price at tick 0
        uint160 pricePoolQ = TickMath.getSqrtPriceAtTick(0);
        console.log("Pool price SQRTX96: %d", pricePoolQ);

        // mint token yes and no to this contract and approve them
        uint256 initialSupply = 100e18;
        OutcomeToken(_markets[poolId].yesToken).mint(address(this), initialSupply);
        OutcomeToken(_markets[poolId].noToken).mint(address(this), initialSupply);
        console.log("Approving outcome tokens to p");
        console.log("address(posm):", address(posm));
        OutcomeToken(_markets[poolId].yesToken).approve(
            address(posm),
            type(uint256).max
        );
        OutcomeToken(_markets[poolId].noToken).approve(
            address(posm),
            type(uint256).max
        );

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            pricePoolQ,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            initialSupply,
            initialSupply // TO DO: this should be precisely equal to what we have minted
        );

        (uint256 amount0Check, uint256 amount1Check) = LiquidityAmounts
            .getAmountsForLiquidity(
                pricePoolQ,
                TickMath.getSqrtPriceAtTick(
                    TickMath.minUsableTick(TICK_SPACING)
                ),
                TickMath.getSqrtPriceAtTick(
                    TickMath.maxUsableTick(TICK_SPACING)
                ),
                liquidityDelta
            );

        console.log("amount0Check: %d", amount0Check);
        console.log("amount1Check: %d", amount1Check);

        posm.modifyLiquidity(
            _markets[poolId].poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING),
                TickMath.maxUsableTick(TICK_SPACING),
                int256(uint256(liquidityDelta)),
                0
            ),
            new bytes(0)
        );
    }

    //////////////////////////
    //// Swap Functions ////////
    //////////////////////////

    // Execute swap
    // After simulation, if user buys share:
    // Take collateral from user, mint opposite tokens and swap, return amount out to user
    // If user sells shares: transfer collateral to user, take user shares, execute swap, keep the opposite tokens
    function executeSwap(
        PoolId poolId,
        bool zeroForOne,
        int128 desiredOutcomeTokens
    ) public {
        Market memory market = _markets[poolId];
        (int256 collateralNeeded, uint256 oppositeTokensToMint) = uniHelper.simulateSwap(
            market,
            zeroForOne,
            desiredOutcomeTokens
        );

        console.log("collateralNeeded: %d", collateralNeeded);
        console.log("oppositeTokensToMint: %d", oppositeTokensToMint);

        // Create TestSettings struct
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            });

        // If user buys shares (collateralNeeded > 0)
        if (collateralNeeded > 0) {
            // Take collateral from user
            OutcomeToken(market.collateralAddress).transferFrom(
                msg.sender,
                address(this),
                uint256(collateralNeeded)
            );
            console.log("collateral taken from user");
            // Mint opposite tokens based on which direction we're trading
            if (zeroForOne) {
                // User wants YES tokens, so mint NO tokens
                OutcomeToken(market.noToken).mint(address(this), oppositeTokensToMint);
                console.log("NO (token1) tokens minted");
                console.log(
                    "balance of NO (token1) hook before transfer: %d",
                    OutcomeToken(market.noToken).balanceOf(
                        address(this)
                    )
                );
            } else {
                OutcomeToken(market.yesToken).mint(address(this), oppositeTokensToMint);
                console.log("YES (token0) tokens minted");
                console.log(
                    "balance of YES (token0) hook before transfer: %d",
                    OutcomeToken(market.yesToken).balanceOf(
                        address(this)
                    )
                );
            }

            // Execute swap with no price limit
            uint160 sqrtPriceLimitX96 = zeroForOne
                ? TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK) + 1 // Minimum possible price when selling token0
                : TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK) - 1; // Maximum possible price when selling token1

            // For exactOut swaps, amountSpecified should be positive
            // For exactIn swaps, amountSpecified should be negative
            console.log("zeroForOne: %d", zeroForOne);
            console.log("desiredOutcomeTokens: %d", desiredOutcomeTokens);
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: desiredOutcomeTokens,
                sqrtPriceLimitX96: !zeroForOne
                    ? TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK) + 1
                    : TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK) - 1
            });

            BalanceDelta delta = poolSwapTest.swap(
                    market.poolKey,
                    params,
                    testSettings,
                    new bytes(0)
                );

            // Update collateral amount in the market
            _markets[poolId].totalCollateral += uint256(collateralNeeded);

            // Return the tokens bought to the user
            if (zeroForOne) {
                console.log("giving back tokens to user");
                OutcomeToken(market.yesToken).transfer(
                    msg.sender,
                    uint256(int256(desiredOutcomeTokens))
                );
            } else {
                console.log("giving back tokens to user");
                OutcomeToken(market.noToken).transfer(
                    msg.sender,
                    uint256(int256(desiredOutcomeTokens))
                );
            }
        } else {
            // If user sells shares (collateralNeeded < 0)
            // Transfer collateral to user
            OutcomeToken(market.collateralAddress).transfer(
                msg.sender,
                uint256(-collateralNeeded)
            );

            // Take user's tokens based on which direction we're trading
            if (zeroForOne) {
                // User is selling YES tokens
                console.log("inside executeSwap sell YES");
                console.log(
                    "desiredOutcomeTokens in executeSwap sell YES: %d",
                    desiredOutcomeTokens
                );
                OutcomeToken(market.yesToken).transferFrom(
                    msg.sender,
                    address(this),
                    uint256(int256(-desiredOutcomeTokens))
                );
            } else {
                // User is selling NO tokens
                console.log("inside executeSwap sell NO");
                OutcomeToken(market.noToken).transferFrom(
                    msg.sender,
                    address(this),
                    uint256(int256(-desiredOutcomeTokens))
                );
            }

            // Execute swap with no price limit
            uint160 sqrtPriceLimitX96 = zeroForOne
                ? TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK) + 1 // Minimum possible price when selling token0
                : TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK) - 1; // Maximum possible price when selling token1

            // For exactOut swaps, amountSpecified should be positive
            // For exactIn swaps, amountSpecified should be negative
            console.log("zeroForOne: %d", zeroForOne);
            console.log("desiredOutcomeTokens: %d", desiredOutcomeTokens);
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: desiredOutcomeTokens,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK) + 1
                    : TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK) - 1
            });

            
            console.log("balance of yesToken before swap:", OutcomeToken(market.yesToken).balanceOf(address(this)));
            console.log("balance of noToken before swap:", OutcomeToken(market.noToken).balanceOf(address(this)));
            BalanceDelta delta = poolSwapTest.swap(
                    market.poolKey,
                    params,
                    testSettings,
                    new bytes(0)
                );

            // Update collateral amount in the market
            _markets[poolId].totalCollateral -= uint256(-collateralNeeded);


            // no need to return the tokens bought to the users, the creator will redeem them
        }
        // emit probability of YES after swap
        emit SwapExecuted(poolId, zeroForOne, desiredOutcomeTokens, msg.sender);

    }

   
    //////////////////////////
    //////// Modifiers ////////
    //////////////////////////

    /// @notice Allows oracle to resolve the market with the outcome
    /// @param poolId The ID of the market pool
    /// @param outcome true for YES, false for NO
    function resolveMarket(PoolId poolId, bool outcome) external {
        // Check if caller is oracle
        if (msg.sender != _markets[poolId].oracle) {
            revert NotOracle();
        }

        // Check if market is still active
        if (_markets[poolId].state != MarketState.Active) {
            revert MarketAlreadyResolved();
        }

        // Update market state and outcome
        _markets[poolId].state = MarketState.Resolved;
        _markets[poolId].outcome = outcome;
    }

    /// @notice Allows oracle or creator to cancel the market
    /// @param poolId The ID of the market pool
    function cancelMarket(PoolId poolId) external {
        // Check if caller is oracle or creator
        if (msg.sender != _markets[poolId].oracle) {
            revert NotOracle();
        }

        // Check if market is still active
        if (_markets[poolId].state != MarketState.Active) {
            revert MarketAlreadyResolved();
        }

        // Update market state
        _markets[poolId].state = MarketState.Cancelled;
    }

    /// @notice Allows users to claim collateral based on their winning token holdings
    /// @param poolId The ID of the market pool
    function claimWinnings(PoolId poolId) external {
        Market memory market = _markets[poolId];
        
        // Check market is resolved
        if (market.state != MarketState.Resolved) {
            revert MarketNotResolved();
        }

        // Check if user has already claimed
        if (_hasClaimed[poolId][msg.sender]) {
            revert AlreadyClaimed();
        }

        // Get user's token balance based on winning outcome
        uint256 winningTokenBalance;
        if (market.outcome) {
            // YES won
            winningTokenBalance = OutcomeToken(market.yesToken).balanceOf(msg.sender);
        } else {
            // NO won
            winningTokenBalance = OutcomeToken(market.noToken).balanceOf(msg.sender);
        }

        // Check user has tokens to claim
        if (winningTokenBalance == 0) {
            revert NoTokensToClaim();
        }

        // Calculate share of collateral based on unclaimed tokens
        uint256 totalWinningSupply = market.outcome ? 
            OutcomeToken(market.yesToken).totalSupply() - _claimedTokens[poolId] : 
            OutcomeToken(market.noToken).totalSupply() - _claimedTokens[poolId];
        
        uint256 collateralShare = (market.totalCollateral * winningTokenBalance) / totalWinningSupply;

        // Transfer winning tokens to contract
        if (market.outcome) {
            OutcomeToken(market.yesToken).transferFrom(msg.sender, address(this), winningTokenBalance);
            _claimedTokens[poolId] += winningTokenBalance;
        } else {
            OutcomeToken(market.noToken).transferFrom(msg.sender, address(this), winningTokenBalance);
            _claimedTokens[poolId] += winningTokenBalance;
        }

        // Mark as claimed
        _hasClaimed[poolId][msg.sender] = true;

        // Update total collateral
        _markets[poolId].totalCollateral -= collateralShare;

        // Transfer collateral to user
        IERC20(market.collateralAddress).transfer(msg.sender, collateralShare);
    }

    // Implement getters manually
    function markets(PoolId poolId) external view returns (Market memory) {
        return _markets[poolId];
    }

    function marketCount() external view returns (uint256) {
        return _marketCount;
    }

    function marketPoolIds(uint256 index) external view returns (PoolId) {
        return _marketPoolIds[index];
    }

    function claimedTokens(PoolId poolId) external view returns (uint256) {
        return _claimedTokens[poolId];
    }

    function hasClaimed(PoolId poolId, address user) external view returns (bool) {
        return _hasClaimed[poolId][user];
    }

}