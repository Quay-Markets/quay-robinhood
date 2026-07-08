// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title HumidiFiStrategy
/// @notice EVM port of the HumidiFi pricing model (see quay-monorepo
///         onchain/vm/research/humidifi-pricing-model.md): a spot pricer
///         keyed off a keeper-pushed mid, with a smooth spread penalty,
///         a discrete tier kick, a spread cap, and a circuit breaker.
///
/// Original closed form (spread in 1e-8 fraction units):
///   total_spread = pool_base + isqrt(out / sqrt_div) + out / lin_div
///   effective mid = mid * (DENOM + spread) / DENOM, applied against the taker
///   plus a discrete +kick at a fixed input threshold and a hard size cliff.
///
/// Mapping onto the venue:
///   - QuoteState.bidPxX128 carries the keeper-pushed mid (token1 atoms per
///     token0 atom, Q128); askPxX128 is unused (post ask == bid).
///   - maxIn0/maxIn1 play the size-cliff role (Tier-C analog).
///   - The circuit breaker (state[584] analog) lives in per-book config.
///   - No time decay: like the original, freshness is binary via validUntil.
contract HumidiFiStrategy is IQuayStrategy, ConfigurableStrategy {
    /// @dev Spread units are 1e-8 fractions, matching the original
    ///      (base 62_116 units ~= 6.2 bps; cap 400_000 units = 40 bps).
    uint256 public constant SPREAD_DENOM = 1e8;

    /// @dev Circuit-breaker threshold from the original: values >= 100 halt.
    uint8 public constant BREAKER_HALT = 100;

    struct Config {
        bool exists;
        uint8 circuitBreaker; // >= BREAKER_HALT halts quoting
        uint64 baseSpread; // 1e-8 units
        uint64 sqrtDiv; // divisor inside isqrt(out / sqrtDiv)
        uint64 linDiv; // divisor of the linear term out / linDiv
        uint64 kickSpread; // 1e-8 units added at/above kickThreshold
        uint64 maxSpread; // spread cap, 1e-8 units
        // Trade-size threshold in token0 atoms (the base-token quantity moved:
        // input when selling token0, perfect output when selling token1).
        // 0 disables the kick.
        uint128 kickThreshold;
    }

    mapping(bytes32 bookId => Config) public configs;

    event ConfigSet(
        bytes32 indexed bookId,
        uint64 baseSpread,
        uint64 sqrtDiv,
        uint64 linDiv,
        uint128 kickThreshold,
        uint64 kickSpread,
        uint64 maxSpread
    );
    event CircuitBreakerSet(bytes32 indexed bookId, uint8 level);

    constructor(QuaySharedLiquidityAMM venue_) ConfigurableStrategy(venue_) {}

    // ------------------------------------------------------------------
    // Maker configuration
    // ------------------------------------------------------------------

    function setConfig(bytes32 bookId, Config calldata c) external onlyBookOwner(bookId) {
        if (!c.exists || c.sqrtDiv == 0 || c.linDiv == 0) revert BadConfig();
        if (c.maxSpread == 0 || c.maxSpread >= SPREAD_DENOM) revert BadConfig();
        configs[bookId] = c;
        emit ConfigSet(
            bookId, c.baseSpread, c.sqrtDiv, c.linDiv, c.kickThreshold, c.kickSpread, c.maxSpread
        );
        emit CircuitBreakerSet(bookId, c.circuitBreaker);
    }

    /// @notice Fast path for the keeper to trip or clear the breaker without
    ///         touching curve parameters.
    function setCircuitBreaker(bytes32 bookId, uint8 level) external onlyBookOwner(bookId) {
        if (!configs[bookId].exists) revert BadConfig();
        configs[bookId].circuitBreaker = level;
        emit CircuitBreakerSet(bookId, level);
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    function quoteExactInput(
        bytes32 bookId,
        QuoteState calldata q,
        bool token0In,
        uint256 amountIn,
        uint256 netAmountIn,
        uint256 /* availableOut */
    )
        external
        view
        returns (uint256 amountOut, uint256 appliedPriceX128, uint32 appliedDecayBps, QuoteReason)
    {
        Config storage c = configs[bookId];
        if (!c.exists) return (0, 0, 0, QuoteReason.BadPrices);
        if (c.circuitBreaker >= BREAKER_HALT) return (0, 0, 0, QuoteReason.BookNotActive);

        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (netAmountIn == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 mid = q.bidPxX128;
        uint256 outPerfect =
            token0In ? Math.mulDiv(netAmountIn, mid, Q128) : Math.mulDiv(netAmountIn, Q128, mid);
        if (outPerfect == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 baseTokenAmount = token0In ? netAmountIn : outPerfect;
        uint256 spread = _spreadUnits(c, baseTokenAmount, outPerfect);

        // Taker pays the inflated effective mid: out = perfect / (1 + spread).
        amountOut = Math.mulDiv(outPerfect, SPREAD_DENOM, SPREAD_DENOM + spread);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        appliedPriceX128 = token0In
            ? Math.mulDiv(mid, SPREAD_DENOM, SPREAD_DENOM + spread)
            : Math.mulDiv(mid, SPREAD_DENOM + spread, SPREAD_DENOM);
        // Diagnostic: spread expressed in bps (1e-8 units / 1e4).
        // casting to 'uint32' is safe: spread <= maxSpread < 1e8, so /1e4 < 1e4
        // forge-lint: disable-next-line(unsafe-typecast)
        appliedDecayBps = uint32(spread / 1e4);
        return (amountOut, appliedPriceX128, appliedDecayBps, QuoteReason.OK);
    }

    /// @dev total_spread = base + isqrt(out / sqrtDiv) + out / linDiv
    ///      (+ kick at the discrete base-token size threshold), capped.
    function _spreadUnits(Config storage c, uint256 baseTokenAmount, uint256 outPerfect)
        internal
        view
        returns (uint256 spread)
    {
        spread = uint256(c.baseSpread) + Math.sqrt(outPerfect / c.sqrtDiv) + outPerfect / c.linDiv;
        if (c.kickThreshold != 0 && baseTokenAmount >= c.kickThreshold) {
            spread += c.kickSpread;
        }
        if (spread > c.maxSpread) spread = c.maxSpread;
    }
}
