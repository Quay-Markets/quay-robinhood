// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(
        MicroV4Swapper.PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// @title MicroV4Swapper
/// @notice Minimal exact-input single-hop Uniswap v4 swapper for ops use
///         (inventory purchases). No router dependency: talks straight to the
///         PoolManager and settles deltas itself. Caller receives the output;
///         input is pulled from the caller (ERC-20) or sent as msg.value
///         (native). Not a venue component — a standalone operational tool.
contract MicroV4Swapper {
    using SafeERC20 for IERC20;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapJob {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minAmountOut;
        address payer;
    }

    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 =
        1461446703485210103287273052203988822378723970341;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error Slippage();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function swapExactInSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut
    ) external payable returns (uint256 amountOut) {
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapJob({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    minAmountOut: minAmountOut,
                    payer: msg.sender
                })
            )
        );
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapJob memory job = abi.decode(data, (SwapJob));

        int256 delta = poolManager.swap(
            job.key,
            IPoolManager.SwapParams({
                zeroForOne: job.zeroForOne,
                amountSpecified: -int256(uint256(job.amountIn)),
                sqrtPriceLimitX96: job.zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1
            }),
            ""
        );

        // BalanceDelta packs (amount0 << 128 | amount1), both int128.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (address currencyIn, address currencyOut, int128 inDelta, int128 outDelta) = job.zeroForOne
            ? (job.key.currency0, job.key.currency1, amount0, amount1)
            : (job.key.currency1, job.key.currency0, amount1, amount0);

        uint256 owed = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        if (amountOut < job.minAmountOut) revert Slippage();

        // Pay the input. job.payer is always the swapExactInSingle caller:
        // the PoolManager only calls back its unlock initiator, so third
        // parties cannot inject a SwapJob with someone else's payer.
        // settle() return values are informational.
        // slither-disable-start arbitrary-send-erc20,unused-return
        if (currencyIn == address(0)) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(currencyIn);
            IERC20(currencyIn).safeTransferFrom(job.payer, address(poolManager), owed);
            poolManager.settle();
        }
        // slither-disable-end arbitrary-send-erc20,unused-return
        // Collect the output straight to the payer.
        poolManager.take(currencyOut, job.payer, amountOut);

        return abi.encode(amountOut);
    }
}
