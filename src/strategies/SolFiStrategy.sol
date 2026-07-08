// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title SolFiStrategy
/// @notice EVM port of the SolFi pricing model (see quay-monorepo
///         onchain/vm/research/SOLFI_REPLICATION_REPORT.md): the price curve
///         is a piecewise-linear spline of up to 8 control points per side.
///         There is no keeper-pushed mid — the spline IS the curve, and the
///         maker reprices by rewriting it.
///
/// Spline semantics (identical to the original's validators):
///   - x[] are input-amount thresholds: x[0] == 0, strictly increasing
///   - y[] are output amounts at those inputs: monotonically non-decreasing
///   - between points the output is linearly interpolated
///   - beyond x[n-1] the output saturates at y[n-1]
///
/// Venue interplay: QuoteState's bid/ask are unused for pricing (post any
/// nonzero heartbeat values); maxIn0/maxIn1 still cap per-side size, and the
/// quote's validUntil provides the freshness gate.
contract SolFiStrategy is IQuayStrategy, ConfigurableStrategy {
    uint256 internal constant MAX_POINTS = 8;

    struct Spline {
        uint8 n; // number of control points; 0 = unconfigured
        uint128[MAX_POINTS] x;
        uint128[MAX_POINTS] y;
    }

    /// @dev side 0 = taker sells token0, side 1 = taker sells token1.
    mapping(bytes32 bookId => Spline[2]) internal splines;

    event SplineSet(bytes32 indexed bookId, uint8 side, uint128[] x, uint128[] y);

    constructor(QuaySharedLiquidityAMM venue_) ConfigurableStrategy(venue_) {}

    // ------------------------------------------------------------------
    // Maker configuration
    // ------------------------------------------------------------------

    function setSpline(bytes32 bookId, uint8 side, uint128[] calldata xs, uint128[] calldata ys)
        external
        onlyBookOwner(bookId)
    {
        uint256 n = xs.length;
        if (side > 1 || n == 0 || n > MAX_POINTS || ys.length != n) revert BadConfig();
        if (xs[0] != 0) revert BadConfig();
        for (uint256 i = 1; i < n; i++) {
            if (xs[i] <= xs[i - 1]) revert BadConfig(); // x strictly increasing
            if (ys[i] < ys[i - 1]) revert BadConfig(); // y monotone non-decreasing
        }

        Spline storage s = splines[bookId][side];
        // casting to 'uint8' is safe: n <= MAX_POINTS == 8 was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        s.n = uint8(n);
        for (uint256 i = 0; i < n; i++) {
            s.x[i] = xs[i];
            s.y[i] = ys[i];
        }
        emit SplineSet(bookId, side, xs, ys);
    }

    function getSpline(bytes32 bookId, uint8 side)
        external
        view
        returns (uint128[] memory xs, uint128[] memory ys)
    {
        Spline storage s = splines[bookId][side];
        xs = new uint128[](s.n);
        ys = new uint128[](s.n);
        for (uint256 i = 0; i < s.n; i++) {
            xs[i] = s.x[i];
            ys[i] = s.y[i];
        }
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
        uint256 /* availableOut: core enforces the inventory bound */
    ) external view returns (uint256 amountOut, uint256 appliedPriceX128, uint32, QuoteReason) {
        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (netAmountIn == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        Spline storage s = splines[bookId][token0In ? 0 : 1];
        if (s.n == 0) return (0, 0, 0, QuoteReason.BadPrices);

        amountOut = _lerp(s, netAmountIn);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        appliedPriceX128 = token0In
            ? Math.mulDiv(amountOut, Q128, netAmountIn)  // token1 per token0
            : Math.mulDiv(netAmountIn, Q128, amountOut);
        return (amountOut, appliedPriceX128, 0, QuoteReason.OK);
    }

    /// @dev Saturating piecewise-linear interpolation, floor rounding —
    ///      out = y[i] + (key - x[i]) * (y[i+1] - y[i]) / (x[i+1] - x[i]).
    function _lerp(Spline storage s, uint256 key) internal view returns (uint256) {
        uint256 n = s.n;
        if (key >= s.x[n - 1]) return s.y[n - 1];

        // key >= x[0] == 0 always holds, so a containing segment exists.
        uint256 i = 0;
        while (i + 1 < n && key >= s.x[i + 1]) {
            i++;
        }
        uint256 x0 = s.x[i];
        uint256 y0 = s.y[i];
        return y0 + Math.mulDiv(key - x0, s.y[i + 1] - y0, s.x[i + 1] - x0);
    }
}
