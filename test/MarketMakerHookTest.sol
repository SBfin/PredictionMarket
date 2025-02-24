// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CentralizedOracle} from "../src/oracle/CentralizedOracle.sol";
import {MarketMakerHook} from "../src/MarketMakerHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {ViewHelper} from "../src/ViewHelper.sol";
import {UniHelper} from "../src/UniHelper.sol";

contract MarketMakerHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    MarketMakerHook public hook;
    CentralizedOracle public oracle;
    V4Quoter public quoter;
    ERC20Mock public collateralToken;
    ViewHelper public viewHelper;
    UniHelper public uniHelper;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6;

    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        console.log("Deploying Uniswap v4 infrastructure from ", address(this));
        deployFreshManagerAndRouters();
        
        // Deploy the oracle that will be used for market resolution
        oracle = new CentralizedOracle();

        // Deploy the quoter
        quoter = new V4Quoter(manager);

        // Deploy UniHelper
        uniHelper = new UniHelper(address(quoter), address(manager));
        console.log("UniHelper deployed at:", address(uniHelper));
        
        // Calculate hook address with specific flags for swap and liquidity operations
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy the hook using foundry cheatcode with specific flags
        deployCodeTo(
            "MarketMakerHook.sol:MarketMakerHook", 
            abi.encode(manager, modifyLiquidityRouter, quoter, uniHelper), 
            flags
        );
        
        // Initialize hook instance at the deployed address
        hook = MarketMakerHook(flags);
        console.log("Hook address:", address(hook));

        // create and mint a collateral token
        // Deploy mock token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        
        // Mint some tokens for testing
        collateralToken.mint(address(this), 1000000 * 10**6);

        // approve the hook to transfer the tokens
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);

        // Deploy ViewHelper
        viewHelper = new ViewHelper(address(hook));
    }

    function test_createMarketWithCollateralAndLiquidity() public {
        hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        // check if the market is created
    }

    function test_quoteCollateralNeededForTradeBuy() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        uint256 amountNew = 45;
        uint256 amountOld = 50;
        uint256 collateralAmount = COLLATERAL_AMOUNT;
        int256 quote = hook.quoteCollateralNeededForTrade(poolId, amountNew, amountOld, collateralAmount, address(collateralToken));
        console.log("Quote buy:", quote);
        // check reference excel model
        assert(quote == 10536051);
    }

    function test_quoteCollateralNeededForTradeSell() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        uint256 amountNew = 55;
        uint256 amountOld = 50;
        uint256 collateralAmount = COLLATERAL_AMOUNT;
        int256 quote = hook.quoteCollateralNeededForTrade(poolId, amountNew, amountOld, collateralAmount, address(collateralToken));
        console.log("Quote sell:", quote);
        // check reference excel model
        assert(quote == -9531017);
    }

    function test_simulateSwap() public {
        // Setup market with initial liquidity
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(
            address(oracle),
            address(this),
            address(collateralToken),
            COLLATERAL_AMOUNT
        );

        // Try to simulate a swap using UniHelper
        Market memory market = viewHelper.getMarket(poolId);
        int128 desiredOutcomeTokens = 5e18;
        (int256 collateralNeeded, uint256 tokensToMint) = uniHelper.simulateSwap(
            market,
            true, // zeroForOne - buying NO tokens
            desiredOutcomeTokens
        );

        // Assert results are reasonable
        assertGt(tokensToMint, 0, "Should get tokens to mint");
        assertTrue(collateralNeeded != 0, "Should need some collateral");
        
        // Log results
        console.log("Tokens to mint:", tokensToMint);
        console.log("Collateral needed:", collateralNeeded);
    }

    function test_executeSwapBuyToken0() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        // approve hook
        collateralToken.approve(address(hook), type(uint256).max);
        // save collateral balance before swap
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        hook.executeSwap(poolId, true, 5e18);
        // check collateral balance after swap
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));
        assert(collateralBalanceAfter < collateralBalanceBefore);
        // check YES token balance after swap
        assert(OutcomeToken(viewHelper.getMarket(poolId).yesToken).balanceOf(address(this)) == 5e18);
    }

    function test_executeSwapBuyToken1() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        collateralToken.approve(address(hook), type(uint256).max);
        // save collateral balance before swap
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        // save NO token balance before swap   
        uint256 noTokenBalanceBefore = OutcomeToken(viewHelper.getMarket(poolId).noToken).balanceOf(address(this));
        hook.executeSwap(poolId, false, 5e18);
        // check collateral balance after swap
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));
        assert(collateralBalanceAfter < collateralBalanceBefore);
        // check NO token balance after swap
        uint256 noTokenBalanceAfter = OutcomeToken(viewHelper.getMarket(poolId).noToken).balanceOf(address(this));
        assert(noTokenBalanceAfter > noTokenBalanceBefore);
    }

    function test_executeSwapSellToken0() public {
        
        // buy and then sell token0
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        collateralToken.approve(address(hook), type(uint256).max);
        hook.executeSwap(poolId, true, 5e18);

        // approve hook to receive token0
        OutcomeToken(viewHelper.getMarket(poolId).yesToken).approve(address(hook), type(uint256).max);
        // check balance of token0 before swap
        uint256 yesTokenBalanceBefore = OutcomeToken(viewHelper.getMarket(poolId).yesToken).balanceOf(address(this));
        console.log("yesTokenBalanceBefore: %d", yesTokenBalanceBefore);
        // collateral balance before swap
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        // sell token0
        hook.executeSwap(poolId, true, -5e18);
        // check balance of token0 after swap
        uint256 yesTokenBalanceAfter = OutcomeToken(viewHelper.getMarket(poolId).yesToken).balanceOf(address(this));
        assert(yesTokenBalanceAfter < yesTokenBalanceBefore);
        // check collateral balance after swap
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));
        assert(collateralBalanceAfter > collateralBalanceBefore);
    }

    function test_executeSwapSellToken1() public {
        // buy and then sell token1
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        collateralToken.approve(address(hook), type(uint256).max);
        hook.executeSwap(poolId, false, 5e18);
        // approve hook to receive token1
        OutcomeToken(viewHelper.getMarket(poolId).noToken).approve(address(hook), type(uint256).max);
        // check balance of token1 before swap
        uint256 noTokenBalanceBefore = OutcomeToken(viewHelper.getMarket(poolId).noToken).balanceOf(address(this));
        console.log("noTokenBalanceBefore: %d", noTokenBalanceBefore);
        // collateral balance before swap
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        // sell token1
        hook.executeSwap(poolId, false, -5e18);
        // check balance of token1 after swap
        uint256 noTokenBalanceAfter = OutcomeToken(viewHelper.getMarket(poolId).noToken).balanceOf(address(this));
        assert(noTokenBalanceAfter < noTokenBalanceBefore);
        // check collateral balance after swap
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));
        assert(collateralBalanceAfter > collateralBalanceBefore);
    }   

    function test_tokenValueChangesAfterBuy() public {
        // Create market
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(
            address(oracle),
            address(this),
            address(collateralToken),
            COLLATERAL_AMOUNT
        );

        // Get initial token values using viewHelper instead of hook
        (uint256 initialYesValue, uint256 initialNoValue, uint256 initialYesProbability) = viewHelper.getTokenValues(poolId);
        console.log("Initial YES value:", initialYesValue);
        console.log("Initial NO value:", initialNoValue);
        console.log("Initial YES probability:", initialYesProbability);

        // Buy YES tokens (should increase YES value and decrease NO value)
        collateralToken.approve(address(hook), type(uint256).max);
        hook.executeSwap(poolId, true, 5e18);

        // Get values after trade using viewHelper
        (uint256 afterYesValue, uint256 afterNoValue, uint256 afterYesProbability) = viewHelper.getTokenValues(poolId);
        console.log("After YES value:", afterYesValue);
        console.log("After NO value:", afterNoValue);
        console.log("After YES probability:", afterYesProbability);

        // YES value should decrease (more supply)
        assert(afterYesValue > initialYesValue);
        // NO value should increase (same supply, more collateral)
        assert(afterNoValue < initialNoValue);
        // YES probability should decrease (more supply)
        assert(afterYesProbability > initialYesProbability);
    }
    

    // test claim winnings
    function test_claimWinnings() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        // Let's just do a test swap to change probabilities
        // approve collateral token 
        collateralToken.approve(address(hook), type(uint256).max);
        hook.executeSwap(poolId, true, 5e18);

        // Resolve market, we should impersonate the oracle
        vm.prank(address(oracle));
        hook.resolveMarket(poolId, true);
        // check if we can claim winnings
        // approve hook to get winning tokens (yes)
        OutcomeToken(viewHelper.getMarket(poolId).yesToken).approve(address(hook), type(uint256).max);
        hook.claimWinnings(poolId);
    }

    // test claim winnings
    function test_claimWinningsWithArbitrageurs() public {
        PoolId poolId = hook.createMarketWithCollateralAndLiquidity(address(oracle), address(this), address(collateralToken), COLLATERAL_AMOUNT);
        // Let's just do a test swap to change probabilities
        // approve collateral token 
        collateralToken.approve(address(hook), type(uint256).max);
        (uint256 yesValue, uint256 noValue, uint256 yesProbability) = viewHelper.getTokenValues(poolId);
        console.log("yesValue: %d", yesValue);
        console.log("noValue: %d", noValue);
        console.log("yesProbability: %d", yesProbability);
        hook.executeSwap(poolId, true, 5e18);

        // As market is about to resolve, arbitrageurs will buy YES tokens
        // create a new user and prank it
        address arbitrageur = createArbitrageur(hook, poolId);

        vm.prank(arbitrageur);
        // push the probability close to 100%
        hook.executeSwap(poolId, true, 94e18);

        // Resolve market, we should impersonate the oracle
        vm.prank(address(oracle));
        hook.resolveMarket(poolId, true);
        // check if we can claim winnings
        // approve hook to get winning tokens (yes)
        OutcomeToken(viewHelper.getMarket(poolId).yesToken).approve(address(hook), type(uint256).max);
        hook.claimWinnings(poolId);
        // check if yes probability is higher than before
        (uint256 yesValueAfter, uint256 noValueAfter, uint256 yesProbabilityAfter) = viewHelper.getTokenValues(poolId);
        console.log("yesValueAfter: %d", yesValueAfter);
        console.log("noValueAfter: %d", noValueAfter);
        console.log("yesProbabilityAfter: %d", yesProbabilityAfter);

        assert(yesProbabilityAfter > yesProbability);
        assert(yesValueAfter > yesValue);
        assert(noValueAfter < noValue);
    }

    function createArbitrageur(MarketMakerHook marketHook, PoolId poolId) public returns (address) {
        address arbitrageur = makeAddr("arbitrageur");
        // mint collateral token for arbitrageur
        collateralToken.mint(arbitrageur, 1e30 * 10**6);
        // approve collateral token for arbitrageur
        vm.prank(arbitrageur);
        collateralToken.approve(address(marketHook), type(uint256).max);
        // approve outcome tokens for arbitrageur
        OutcomeToken(viewHelper.getMarket(poolId).yesToken).approve(arbitrageur, type(uint256).max);
        OutcomeToken(viewHelper.getMarket(poolId).noToken).approve(arbitrageur, type(uint256).max);
        return arbitrageur;
    }

}