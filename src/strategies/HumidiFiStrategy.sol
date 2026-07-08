// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title HumidiFiStrategy
/// @notice EVM port of the HumidiFi pricing model (quay-monorepo
///         onchain/vm/research: humidifi-decoder/src/simulator.rs is the
///         authoritative flat-spread pricer confirmed by on-chain replay;
///         humidifi-pricing-model.md adds the fitted sqrt/linear penalty and
///         tier kick, which remain open RE points): a spot pricer keyed off a
///         keeper-pushed mid with a taker-adverse spread and circuit breaker.
///
/// Authoritative settlement (simulator.rs): both directions multiply by
///   factor = (DENOM - spread) / DENOM
/// in a single fused floor division. The smooth penalty
///   spread = base + isqrt(out / sqrt_div) + out / lin_div
/// and the discrete +kick at an input threshold come from the fitted model
/// (humidifi-pricing-model.md) and are optional here: setting sqrtDiv or
/// linDiv to 0 disables that term, so the verified flat-spread regime is
/// spread = baseSpread. The 40 bps max-spread cap mirrors state[48]; the
/// original never demonstrably enforces it, so it is a defensive clamp.
///
/// Mapping onto the venue:
///   - QuoteState.bidPxX128 carries the keeper-pushed mid (token1 atoms per
///     token0 atom, Q128); askPxX128 is unused (post ask == bid).
///   - maxIn0/maxIn1 play the size-cliff role (Tier-C analog).
///   - The circuit breaker (state[584] analog) lives in per-book config.
///   - No time decay: like the original, freshness is binary via validUntil.
contract HumidiFiStrategy is IQuayStrategy, ConfigurableStrategy {
    /// @dev Spread units are 1e-8 fractions, matching the original's tier-fee
    ///      encoding (base 62_116 units ~= 6.2 bps; cap 400_000 = 40 bps).
    uint256 public constant SPREAD_DENOM = 1e8;

    /// @dev Circuit-breaker threshold from the original: values >= 100 halt.
    uint8 public constant BREAKER_HALT = 100;

    struct Config {
        bool exists;
        uint8 circuitBreaker; // >= BREAKER_HALT halts quoting
        uint64 baseSpread; // 1e-8 units; the flat-regime spread
        uint64 sqrtDiv; // divisor inside isqrt(out / sqrtDiv); 0 disables
        uint64 linDiv; // divisor of the linear term out / linDiv; 0 disables
        uint64 kickSpread; // 1e-8 units added at/above kickThreshold
        uint64 maxSpread; // spread cap, 1e-8 units
        // Trade-size threshold in raw input atoms (the original's tier
        // selector compares amount_in regardless of side, so the unit depends
        // on trade direction — set it for the side that matters or use two
        // books). 0 disables the kick.
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
        if (!c.exists) revert BadConfig();
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
        if (mid == 0) return (0, 0, 0, QuoteReason.BadPrices); // ZeroMid analog
        uint256 outPerfect =
            token0In ? Math.mulDiv(netAmountIn, mid, Q128) : Math.mulDiv(netAmountIn, Q128, mid);
        if (outPerfect == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 spread = _spreadUnits(c, netAmountIn, outPerfect);

        // Authoritative convention: multiply by (DENOM - spread) / DENOM in a
        // single fused floor division per direction (simulator.rs).
        uint256 factor = SPREAD_DENOM - spread;
        amountOut = token0In
            ? Math.mulDiv(netAmountIn * factor, mid, Q128 * SPREAD_DENOM)
            : Math.mulDiv(netAmountIn * factor, Q128, mid * SPREAD_DENOM);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        appliedPriceX128 = token0In
            ? Math.mulDiv(mid, factor, SPREAD_DENOM)
            : Math.mulDiv(mid, SPREAD_DENOM, factor);
        // Diagnostic: spread expressed in bps (1e-8 units / 1e4).
        // casting to 'uint32' is safe: spread <= maxSpread < 1e8, so /1e4 < 1e4
        // forge-lint: disable-next-line(unsafe-typecast)
        appliedDecayBps = uint32(spread / 1e4);
        return (amountOut, appliedPriceX128, appliedDecayBps, QuoteReason.OK);
    }

    /// @dev total_spread = base + isqrt(out / sqrtDiv) + out / linDiv
    ///      (+ kick at the discrete input threshold), capped. The sqrt and
    ///      linear terms are the fitted-model penalty; 0-divisors disable
    ///      them, leaving the replay-verified flat spread.
    function _spreadUnits(Config storage c, uint256 netAmountIn, uint256 outPerfect)
        internal
        view
        returns (uint256 spread)
    {
        spread = c.baseSpread;
        if (c.sqrtDiv != 0) spread += Math.sqrt(outPerfect / c.sqrtDiv);
        if (c.linDiv != 0) spread += outPerfect / c.linDiv;
        if (c.kickThreshold != 0 && netAmountIn >= c.kickThreshold) {
            spread += c.kickSpread;
        }
        if (spread > c.maxSpread) spread = c.maxSpread;
    }
}
