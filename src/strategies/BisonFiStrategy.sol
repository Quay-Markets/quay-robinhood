// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title BisonFiStrategy
/// @notice EVM port of the BisonFi pricing model (see quay-monorepo
///         onchain/vm/research/bisonfi-pricing-model.md): mid-based pricing
///         with an explicit freshness haircut, an asymmetric per-side
///         constant spread, and an additive per-tier spread ladder keyed on
///         the fill ratio against inventory depth.
///
/// Original math, in ppm (1e-6 fractions):
///   haircut_ppm = 50 * slot_delta + max(side_field, side_floor) * 100 / 256
///   hard staleness gate at slot_delta >= 5
///   ladder: spread(r) = sum over tiers with r >= T_n of [K_n*(r - T_n) + Y_n]
///   where r = out_perfect / depth; rejection near r > 0.7
///
/// Mapping onto the venue:
///   - QuoteState.bidPxX128 carries the mid (token1 atoms per token0 atom,
///     Q128); askPxX128 is unused (post ask == bid).
///   - Slots become seconds: q.updatedAt is stamped by the venue on every
///     quote update, so freshness = ppmPerSecond * (now - updatedAt), with a
///     hard staleness gate at maxAgeSeconds (independent of validUntil).
///   - Depth is the venue-provided availableOut (shared group inventory),
///     which is exactly BisonFi's per-side depth role.
contract BisonFiStrategy is IQuayStrategy, ConfigurableStrategy {
    uint256 public constant PPM = 1e6;
    uint256 internal constant MAX_TIERS = 4;

    struct Tier {
        uint64 thresholdRatioPpm; // T_n: activates when r >= T_n
        uint64 slopePpm; // K_n: adds slopePpm * (r - T_n) / PPM
        uint64 offsetPpm; // Y_n: flat ppm added once the tier activates
    }

    struct SideConfig {
        uint32 constSpread; // side-specific constant-spread field
        uint32 constFloor; // its floor; haircut uses max(field, floor)*100/256
        uint8 tierCount;
        Tier[MAX_TIERS] ladder;
    }

    struct Config {
        bool exists;
        uint32 ppmPerSecond; // freshness decay (original: 50 ppm per slot)
        uint32 maxAgeSeconds; // hard staleness gate (original: 5 slots)
        uint32 maxRatioPpm; // fill-ratio rejection (original: ~700_000)
    }

    mapping(bytes32 bookId => Config) public configs;
    mapping(bytes32 bookId => SideConfig[2]) internal sides;

    event ConfigSet(
        bytes32 indexed bookId, uint32 ppmPerSecond, uint32 maxAgeSeconds, uint32 maxRatioPpm
    );
    event SideConfigSet(
        bytes32 indexed bookId, uint8 side, uint32 constSpread, uint32 constFloor, uint8 tierCount
    );

    constructor(QuaySharedLiquidityAMM venue_) ConfigurableStrategy(venue_) {}

    // ------------------------------------------------------------------
    // Maker configuration
    // ------------------------------------------------------------------

    function setConfig(bytes32 bookId, Config calldata c) external onlyBookOwner(bookId) {
        if (!c.exists || c.maxAgeSeconds == 0) revert BadConfig();
        if (c.maxRatioPpm == 0 || c.maxRatioPpm > PPM) revert BadConfig();
        configs[bookId] = c;
        emit ConfigSet(bookId, c.ppmPerSecond, c.maxAgeSeconds, c.maxRatioPpm);
    }

    function setSideConfig(
        bytes32 bookId,
        uint8 side,
        uint32 constSpread,
        uint32 constFloor,
        Tier[] calldata ladder
    ) external onlyBookOwner(bookId) {
        if (side > 1 || ladder.length > MAX_TIERS) revert BadConfig();
        for (uint256 i = 1; i < ladder.length; i++) {
            // Tiers sorted by activation threshold, strictly increasing.
            if (ladder[i].thresholdRatioPpm <= ladder[i - 1].thresholdRatioPpm) {
                revert BadConfig();
            }
        }

        SideConfig storage s = sides[bookId][side];
        s.constSpread = constSpread;
        s.constFloor = constFloor;
        s.tierCount = uint8(ladder.length);
        for (uint256 i = 0; i < ladder.length; i++) {
            s.ladder[i] = ladder[i];
        }
        emit SideConfigSet(bookId, side, constSpread, constFloor, uint8(ladder.length));
    }

    function getSideConfig(bytes32 bookId, uint8 side)
        external
        view
        returns (uint32 constSpread, uint32 constFloor, Tier[] memory ladder)
    {
        SideConfig storage s = sides[bookId][side];
        constSpread = s.constSpread;
        constFloor = s.constFloor;
        ladder = new Tier[](s.tierCount);
        for (uint256 i = 0; i < s.tierCount; i++) {
            ladder[i] = s.ladder[i];
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
        uint256 availableOut
    ) external view returns (uint256, uint256, uint32, QuoteReason) {
        Config storage c = configs[bookId];
        if (!c.exists) return (0, 0, 0, QuoteReason.BadPrices);

        // Hard staleness gate, the 5-slot analog. Venue guarantees
        // updatedAt <= block.timestamp.
        uint256 age = block.timestamp - q.updatedAt;
        if (age >= c.maxAgeSeconds) return (0, 0, 0, QuoteReason.QuoteExpired);

        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (netAmountIn == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 outPerfect = token0In
            ? Math.mulDiv(netAmountIn, q.bidPxX128, Q128)
            : Math.mulDiv(netAmountIn, Q128, q.bidPxX128);
        if (outPerfect == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        // Fill ratio against shared-group depth, the out_perfect/depth term.
        if (availableOut == 0) return (0, 0, 0, QuoteReason.InsufficientLiquidity);
        uint256 ratioPpm = Math.mulDiv(outPerfect, PPM, availableOut);
        if (ratioPpm > c.maxRatioPpm) {
            return (0, 0, 0, QuoteReason.InsufficientLiquidity);
        }

        // Field-by-field assignment keeps the outer frame below the EVM stack
        // limit; every field is set before use.
        // slither-disable-next-line uninitialized-local
        PenaltyInput memory p;
        p.mid = q.bidPxX128;
        p.token0In = token0In;
        p.outPerfect = outPerfect;
        p.ratioPpm = ratioPpm;
        p.freshnessPpm = uint256(c.ppmPerSecond) * age;
        return _applyPenalties(bookId, p);
    }

    struct PenaltyInput {
        uint256 mid;
        bool token0In;
        uint256 outPerfect;
        uint256 ratioPpm;
        uint256 freshnessPpm;
    }

    function _applyPenalties(bytes32 bookId, PenaltyInput memory p)
        internal
        view
        returns (uint256 amountOut, uint256 appliedPriceX128, uint32 appliedDecayBps, QuoteReason)
    {
        SideConfig storage sc = sides[bookId][p.token0In ? 0 : 1];
        uint256 constantPpm = (uint256(Math.max(sc.constSpread, sc.constFloor)) * 100) / 256;
        uint256 totalPpm = p.freshnessPpm + constantPpm + _ladderPpm(sc, p.ratioPpm);
        if (totalPpm >= PPM) return (0, 0, 0, QuoteReason.InsufficientLiquidity);

        amountOut = Math.mulDiv(p.outPerfect, PPM - totalPpm, PPM);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        appliedPriceX128 = p.token0In
            ? Math.mulDiv(p.mid, PPM - totalPpm, PPM)
            : Math.mulDiv(p.mid, PPM, PPM - totalPpm);
        // Diagnostic: freshness component in bps (ppm / 100).
        // casting to 'uint32' is safe: freshnessPpm < PPM here, so /100 < 1e4
        // forge-lint: disable-next-line(unsafe-typecast)
        appliedDecayBps = uint32(p.freshnessPpm / 100);
        return (amountOut, appliedPriceX128, appliedDecayBps, QuoteReason.OK);
    }

    /// @dev spread(r) = sum over active tiers (r >= T_n) of
    ///      K_n * (r - T_n) / PPM + Y_n, everything in ppm.
    function _ladderPpm(SideConfig storage sc, uint256 ratioPpm)
        internal
        view
        returns (uint256 spread)
    {
        uint256 tiers = sc.tierCount;
        for (uint256 i = 0; i < tiers; i++) {
            Tier storage t = sc.ladder[i];
            if (ratioPpm < t.thresholdRatioPpm) break; // sorted ascending
            spread += (uint256(t.slopePpm) * (ratioPpm - t.thresholdRatioPpm)) / PPM + t.offsetPpm;
        }
    }
}
