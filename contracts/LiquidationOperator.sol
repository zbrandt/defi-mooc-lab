//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------


interface ILendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);

    function getLendingPoolCore() external view returns (address payable);
}

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // constants
    address userToLiquidate = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    uint64 deadline = 1621761060; // random uncreated block number
    uint256 amountBorrow = 2916378221683;
                            

    // ERC-20
    IWETH WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    // Aave lending
    ILendingPool lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // Uniswap interfaces.
    IUniswapV2Factory factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Pair pair_WETH_USDT = IUniswapV2Pair(factory.getPair(address(WETH), address(USDT)));
    IUniswapV2Pair pair_WBTC_WETH = IUniswapV2Pair(factory.getPair(address(WBTC), address(WETH)));

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {}

    receive() external payable {}

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // 0. security checks and initializing variables
        uint256 healthFactor;

        // 1. get the target user account data & make sure it is liquidatable
        (,,,,,healthFactor) = lendingPool.getUserAccountData(userToLiquidate);
        console.log(healthFactor / 10**18);
        require(healthFactor / 10**18 < 1, "Not unhealthy");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        pair_WETH_USDT.swap(0, amountBorrow, address(this), abi.encode("flash loan")); // address(this) is the address of the caller of the contract

        
        // 3. Convert the WETH into ETH and send back to sender
        uint profitWETH = WETH.balanceOf(address(this)); // all profit since we start with zero presumably
        console.log("profit: ", profitWETH);
        WETH.withdraw(profitWETH);
        msg.sender.call{value: profitWETH}(""); // send profits
        
    }
    // the workflow is like this:
    // check healthiness, then take out a flash loan for USDT
    // after that uniswapV2Call is executed somehow, I believe
    /* 
        we approve transfering USDT to the lending pool to cover the faulty debtor and recieve some WBTC in return
        then we swap the WBTC for WETH 
        we then figure out how much we need to repay for the flash loan based on reserves in the pair
        then we approve and transfer the repayment amount 
        then we are back to 3 where we see our balance of WETH (all profit since we started at 0)
        withdrawing from WETH turns into ETH I guess
        then we send the profits to msg.sender
    */ 



    // required by the swap
    function uniswapV2Call( // flash swap function?
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {

        uint preLiquidated = WBTC.balanceOf(address(this)); // returns amount of WBTC owned by caller

        // 2.1 liquidate the target user
        USDT.approve(address(lendingPool), amount1); // sets amount1 to be the lending pools allowance over the callers USDT tokens, needed before liquidate

        console.log("liquidate");
        lendingPool.liquidationCall(address(WBTC), address(USDT), userToLiquidate, amount1, false); // liquidate positions of userToLiquidate up to amount1 in WBTC, caller recieves underlying asset directly and gives USDT
        uint liquidated = WBTC.balanceOf(address(this)) - preLiquidated; // check how much was liquidated
        console.log("Liquidated: ", liquidated);

        // 2.2 swap the liquidated WBTC for WETH
        console.log("swap WBTC for WETH");
        WBTC.approve(address(pair_WBTC_WETH), liquidated); // approve before transfer
        WBTC.transfer(address(pair_WBTC_WETH), liquidated); // send WBTC to pool
        (uint reserveWBTC, uint reserveWETH1,) = pair_WBTC_WETH.getReserves(); 
        uint WETH_revenue = getAmountOut(liquidated, reserveWBTC, reserveWETH1);
        pair_WBTC_WETH.swap(0, WETH_revenue, address(this), ""); // regular swap to get WETH reveunue from collateral

        // 2.3 repay loan + interest
        console.log("repay flash loan in WETH");
        (uint reserveWETH2, uint reserveUSDT,) = pair_WETH_USDT.getReserves(); // get reserves in the pair
        uint repaymentAmount = getAmountIn(amount1, reserveWETH2, reserveUSDT); // given amount of asset amount1 and pair reserves, figures out how much to repay
        WETH.approve(msg.sender, repaymentAmount); // aprove before transfer
        WETH.transfer(msg.sender, repaymentAmount); // transfer to msg.sender

    }
}
