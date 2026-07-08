// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title SolFiStrategy
/// @notice EVM port of the SolFi pricing model as pinned by the round-4/5 RE
///         (quay-monorepo onchain/vm/research/solfi-decoder/
///         Y_AXIS_FORMULA_PINNED.md and the BPF-parity-tested solfi_clone):
///         a slot-decay quote model. The maker posts a mid; a side-specific
///         multiplier C interpolates linearly from a fresh value to a stale
///         value over a ramp window, then a linear fee applies. The account's
///         splines are dormant on the calibrated path and are not ported.
///
/// Original math (FEE_PRECISION = 1e7):
///   delta      = clock.slot - last_update_slot; reject at delta >= max gate
///   C(delta)   = (C_fresh * (ramp - clipped) + C_stale * clipped) / ramp,
///                clipped = min(delta, ramp)
///   out_base   = in_quote * C1(delta) / mid_denom * (1e7 - fee) / 1e7
///   out_quote  = in_base * mid_denom / C0(delta) * (1e7 - fee) / 1e7
///
/// Mapping onto the venue (slots become seconds):
///   - QuoteState.bidPxX128 carries the mid (token1 atoms per token0 atom,
///     Q128) — the mid_denom analog, refreshed through updateQuote.
///   - delta = block.timestamp - q.updatedAt (venue-stamped).
///   - Settlement uses one fused floor division per side, mirroring the
///     original's single-truncation settlement.
///   - c0 scales the sell-token0 side (values above PRECISION worsen the
///     taker); c1 scales the sell-token1 side (values below PRECISION worsen
///     the taker). Fresh-vs-stale pairs express the toxicity-defense ramp:
///     tight spread right after a refresh, wide when the quote ages.
contract SolFiStrategy is IQuayStrategy, ConfigurableStrategy {
    uint256 public constant PRECISION = 1e7; // FEE_PRECISION analog

    struct Config {
        bool exists;
        uint32 rampSeconds; // C interpolation window (original: ~25 slots)
        uint32 maxAgeSeconds; // hard freshness gate (original: 200 slots)
        uint32 feePpm7; // linear fee in 1e-7 units (original state[304])
        uint64 c1Fresh; // sell-token1 multiplier at delta = 0
        uint64 c1Stale; // sell-token1 multiplier at delta >= ramp
        uint64 c0Fresh; // sell-token0 divisor at delta = 0
        uint64 c0Stale; // sell-token0 divisor at delta >= ramp
    }

    mapping(bytes32 bookId => Config) public configs;

    event ConfigSet(
        bytes32 indexed bookId,
        uint32 rampSeconds,
        uint32 maxAgeSeconds,
        uint32 feePpm7,
        uint64 c1Fresh,
        uint64 c1Stale,
        uint64 c0Fresh,
        uint64 c0Stale
    );

    constructor(QuaySharedLiquidityAMM venue_) ConfigurableStrategy(venue_) {}

    // ------------------------------------------------------------------
    // Maker configuration
    // ------------------------------------------------------------------

    function setConfig(bytes32 bookId, Config calldata c) external onlyBookOwner(bookId) {
        bool bad = !c.exists || c.rampSeconds == 0 || c.maxAgeSeconds == 0 || c.feePpm7 >= PRECISION
            || c.c1Fresh == 0 || c.c1Stale == 0 || c.c0Fresh == 0 || c.c0Stale == 0;
        if (bad) revert BadConfig();
        configs[bookId] = c;
        emit ConfigSet(
            bookId,
            c.rampSeconds,
            c.maxAgeSeconds,
            c.feePpm7,
            c.c1Fresh,
            c.c1Stale,
            c.c0Fresh,
            c.c0Stale
        );
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
        uint256 /* availableOut: no size dependence on the calibrated path */
    ) external view returns (uint256, uint256, uint32, QuoteReason) {
        Config storage c = configs[bookId];
        if (!c.exists) return (0, 0, 0, QuoteReason.BadPrices);

        // Hard freshness gate (custom error 0x83 analog), strict < boundary.
        uint256 delta = block.timestamp - q.updatedAt;
        if (delta >= c.maxAgeSeconds) return (0, 0, 0, QuoteReason.QuoteExpired);

        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (netAmountIn == 0 || q.bidPxX128 == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 clipped = delta > c.rampSeconds ? c.rampSeconds : delta;
        uint256 amountOut = _settle(c, q.bidPxX128, token0In, netAmountIn, clipped);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 appliedPriceX128 = token0In
            ? Math.mulDiv(amountOut, Q128, netAmountIn)
            : Math.mulDiv(netAmountIn, Q128, amountOut);
        // Diagnostic: ramp progress in bps (0 = fresh, 10_000 = stale plateau).
        // casting to 'uint32' is safe: clipped <= rampSeconds, so the ratio <= 1e4
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 rampBps = uint32((clipped * 10_000) / c.rampSeconds);
        return (amountOut, appliedPriceX128, rampBps, QuoteReason.OK);
    }

    /// @dev Single fused floor division per side.
    function _settle(
        Config storage c,
        uint256 mid,
        bool token0In,
        uint256 netAmountIn,
        uint256 clipped
    ) internal view returns (uint256) {
        uint256 feeFactor = PRECISION - c.feePpm7;
        if (token0In) {
            // out = in * mid / Q128 * PRECISION / C0 * feeFactor / PRECISION.
            uint256 c0 = _interpolate(c.c0Fresh, c.c0Stale, clipped, c.rampSeconds);
            return Math.mulDiv(netAmountIn * feeFactor, mid, Q128 * c0);
        }
        // out = in * Q128 / mid * C1 / PRECISION * feeFactor / PRECISION.
        uint256 c1 = _interpolate(c.c1Fresh, c.c1Stale, clipped, c.rampSeconds);
        return Math.mulDiv(netAmountIn * feeFactor, c1 * Q128, mid * PRECISION * PRECISION);
    }

    /// @dev C(delta) = (fresh * (ramp - clipped) + stale * clipped) / ramp —
    ///      the original's all-unsigned exact interpolation; works whether the
    ///      stale value is above or below the fresh one.
    function _interpolate(uint256 fresh, uint256 stale, uint256 clipped, uint256 ramp)
        internal
        pure
        returns (uint256)
    {
        return (fresh * (ramp - clipped) + stale * clipped) / ramp;
    }
}
