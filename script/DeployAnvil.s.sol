// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IMarketMakerHook} from "../src/interfaces/IMarketMakerHook.sol";
import {CentralizedOracle} from "../src/oracle/CentralizedOracle.sol";
import {MarketMakerHook} from "../src/MarketMakerHook.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
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
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ViewHelper} from "../src/ViewHelper.sol";
import {UniHelper} from "../src/UniHelper.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
contract Deploy is Script {

    MarketMakerHook public hook;
    CentralizedOracle public oracle;
    V4Quoter public quoter;
    ERC20Mock public collateralToken;
    IMarketMakerHook public marketMakerHookInterface;
    PoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    address public creator;
    address public user1;
    address public user2;
    ViewHelper public viewHelper;
    UniHelper public uniHelper;
    PoolSwapTest public poolSwapTest;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6;

    function setUp() public {
        // Set up addresses before deployment
    }

    function deployInfrastructure() private {
        // Deploy Uniswap infrastructure
        manager = new PoolManager(address(this));
        console.log("Deployed PoolManager at", address(manager));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);   
        poolSwapTest = new PoolSwapTest(manager);
        oracle = new CentralizedOracle();
        quoter = new V4Quoter(manager);
        
        // Deploy UniHelper
        uniHelper = new UniHelper(address(quoter), address(manager));
        console.log("Deployed UniHelper at", address(uniHelper));
    }

    function deployHook() private {
        vm.stopBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(MarketMakerHook).creationCode,
            abi.encode(manager, modifyLiquidityRouter, poolSwapTest, quoter, uniHelper)
        );

        console.log("Deploying MarketMakerHook at", hookAddress);

        vm.startBroadcast();
        hook = new MarketMakerHook{salt: salt}(
            manager, 
            modifyLiquidityRouter, 
            poolSwapTest,
            quoter,
            uniHelper
        );
        require(address(hook) == hookAddress, "hook address mismatch");
        
        marketMakerHookInterface = IMarketMakerHook(address(hook));
    }

    function deployTokens() private {
        collateralToken = new ERC20Mock("Test Collateral token", "testUSDC", 6);
        
        collateralToken.mint(address(this), 1000000 * 10**6);
        
        // mint for testing to our addresses on base sepolia
        collateralToken.mint(0x39dc391f8FFE71156212C7c3196Ef09B9C0bdDf8, 1000000 * 10**6);
        collateralToken.mint(0x9757ea4Ac5b34881F339E2135aCA81ff855cd035, 1000000 * 10**6);
        collateralToken.mint(0xA7E5207858f622F9b31c2aE5F91a3C638B897407, 1000000 * 10**6);
        collateralToken.mint(0x1AEdf1675236806beeD2c8EFa2c096DbAEb1790E, 1000000 * 10**6);
        collateralToken.mint(0x3e6Fa8E5FB81Aad585ea4597d52085cac21Ee6c1, 1000000 * 10**6);

    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PK");
        vm.startBroadcast(deployerPrivateKey);

        deployInfrastructure();
        deployHook();
        deployTokens();

        // Debug balances
        console.log("Script contract balance:", collateralToken.balanceOf(address(this)));
        console.log("Hook contract balance:", collateralToken.balanceOf(address(hook)));
        console.log("Hook contract address:", address(hook));
        console.log("Collateral token address:", address(collateralToken));
        console.log("Deployer address:", address(vm.addr(deployerPrivateKey)));
        console.log("msg.sender:", msg.sender);

        // Transfer tokens to the deployer address
        address deployer = vm.addr(deployerPrivateKey);
        collateralToken.mint(deployer, 1000000 * 10**6);
        collateralToken.mint(msg.sender, 1000000 * 10**6);
        console.log("Deployer balance:", collateralToken.balanceOf(deployer));

        // Create market
        collateralToken.approve(address(hook), type(uint256).max);
        hook.createMarketWithCollateralAndLiquidity(address(oracle), msg.sender, address(collateralToken), 100e6);
        // Deploy ViewHelper after hook
        viewHelper = new ViewHelper(address(hook));
        console.log("Deployed ViewHelper at", address(viewHelper));

        // Use viewHelper instead of hook directly
        Market[] memory markets = viewHelper.getMarkets();
        
        // After market creation
        console.log("Market created, verifying...");
        console.log("Total markets:", markets.length);
        
        // Try to get markets
        if (markets.length > 0) {
            console.log("First market creator:", markets[0].creator);
        }
        // print markets
        for (uint256 i = 0; i < markets.length; i++) {
            console.log("Market creator:", markets[i].creator);
        }

        vm.stopBroadcast();
        console.log("Deployment complete!");
    }
}