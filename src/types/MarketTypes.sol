// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "../OutcomeToken.sol";

enum MarketState {
    Active,
    Resolved,
    Cancelled
}

struct Market {
    PoolKey poolKey;
    address oracle;
    address creator;
    OutcomeToken yesToken;
    OutcomeToken noToken;
    MarketState state;
    bool outcome;
    uint256 totalCollateral;
    address collateralAddress;
}