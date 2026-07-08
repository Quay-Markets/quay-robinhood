// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";

/// @title BBOStrategy
/// @notice Quay's default pricing module: a posted bid/ask quote with linear
///         staleness decay and per-side size caps.
///
/// QuoteState field interpretation:
///   bidPxX128 / askPxX128  token1 atoms per token0 atom, Q128
///   maxIn0 / maxIn1        max gross exact input per side
///   freshUntil             decay starts after this timestamp
///   decayBpsPerSecond      linear price worsening per second past freshUntil
///   maxDecayBps            decay ceiling
contract BBOStrategy is IQuayStrategy, QuayTypes {
    function quoteExactInput(
        QuoteState calldata q,
        bool token0In,
        uint256 amountIn,
        uint256 netAmountIn,
        uint256 /* availableOut: BBO prices independently of inventory */
    )
        external
        view
        returns (
            uint256 amountOut,
            uint256 appliedPriceX128,
            uint32 appliedDecayBps,
            QuoteReason reason
        )
    {
        if (q.bidPxX128 == 0 || q.askPxX128 < q.bidPxX128) {
            return (0, 0, 0, QuoteReason.BadPrices);
        }
        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }

        appliedDecayBps = _appliedDecayBps(q);
        uint256 decay = uint256(appliedDecayBps);

        if (token0In) {
            // Taker sells token0 at the bid. Decay worsens by lowering the bid.
            appliedPriceX128 = Math.mulDiv(q.bidPxX128, uint256(BPS) - decay, uint256(BPS));
            amountOut = Math.mulDiv(netAmountIn, appliedPriceX128, Q128);
        } else {
            // Taker sells token1 at the ask. Decay worsens by raising the ask.
            appliedPriceX128 = Math.mulDiv(q.askPxX128, uint256(BPS) + decay, uint256(BPS));
            amountOut = Math.mulDiv(netAmountIn, Q128, appliedPriceX128);
        }

        if (amountOut == 0) return (0, appliedPriceX128, appliedDecayBps, QuoteReason.ZeroOutput);
        reason = QuoteReason.OK;
    }

    function _appliedDecayBps(QuoteState calldata q) internal view returns (uint32) {
        if (block.timestamp <= q.freshUntil) return 0;
        uint256 elapsed = block.timestamp - q.freshUntil;
        uint256 decay = elapsed * q.decayBpsPerSecond;
        if (decay > q.maxDecayBps) decay = q.maxDecayBps;
        // casting to 'uint32' is safe: decay is capped at q.maxDecayBps, a uint32
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(decay);
    }
}
