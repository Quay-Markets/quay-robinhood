// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @title BisonFiStrategy
/// @notice EVM port of the BisonFi pricing model, June re-RE variant
///         (quay-monorepo onchain/vm/research: BISONFI_JUN_HAIRCUT_RE.md and
///         bisonfi-decoder/src/simulator.rs `june_constant_haircut_ppm` +
///         `size_penalty_extra_ppm`, validated <=0.2 ppm against the live
///         binary): mid-based pricing with a fused freshness/constant haircut
///         and an additive, signed spread ladder keyed on the fill ratio
///         against live output-side depth.
///
/// Original math:
///   base_pick = floor != 0 ? floor : L
///   pick      = slot_delta >= 1 ? max(base_pick, field) : base_pick
///   haircut   = (pick + slot_delta * base_882) * 100 / 256      // ppm
///   ladder(r) = sum over tiers with r >= T_n of [K_n*(r - T_n)/scale + Y_n]
///               (signed; Y_n may be negative)
///   factor    = 1e9 - total_haircut_ppb; invalid when factor <= 0
///   out       = amount_in * price * factor / 1e9 (single floor division)
///   hard staleness gate at slot_delta >= MAX_SLOT_DELTA
///
/// Mapping onto the venue (slots become seconds):
///   - QuoteState.bidPxX128 carries the mid (token1 atoms per token0 atom,
///     Q128); q.updatedAt (venue-stamped) drives the freshness terms.
///   - Depth is the venue-provided availableOut (live shared-group inventory,
///     the June model's inv_out), floored at 1.
///   - Haircut math runs in ppb (x 100_000 / 256) as the simulator does for
///     bit-exactness against FACTOR_NUM; ladder config stays in ppm.
///   - The fill-ratio rejection is optional (maxRatioPpm = 0 disables); the
///     June model has no fixed gate — quotes go invalid via factor <= 0.
contract BisonFiStrategy is IQuayStrategy, ConfigurableStrategy {
    uint256 public constant PPM = 1e6;
    uint256 public constant PPB = 1e9;
    uint256 internal constant MAX_TIERS = 4;

    struct Tier {
        uint64 thresholdRatioPpm; // T_n: activates when r >= T_n
        int64 slopePpm; // K_n: adds slopePpm * (r - T_n) / PPM
        int64 offsetPpm; // Y_n: added once active; may be negative
    }

    struct SideConfig {
        uint32 field; // side-specific constant-spread field (894/896 analog)
        uint32 floorValue; // its floor (852/854 analog)
        uint8 tierCount;
        Tier[MAX_TIERS] ladder;
    }

    struct Config {
        bool exists;
        uint32 basePerSecond; // base_882 analog: per-second decay units
        uint32 maxAgeSeconds; // hard staleness gate (June mainnet: 3 slots)
        uint32 defaultPick; // L analog: pick fallback when floor == 0
        uint32 maxRatioPpm; // optional fill-ratio rejection; 0 disables
    }

    mapping(bytes32 bookId => Config) public configs;
    mapping(bytes32 bookId => SideConfig[2]) internal sides;

    event ConfigSet(
        bytes32 indexed bookId,
        uint32 basePerSecond,
        uint32 maxAgeSeconds,
        uint32 defaultPick,
        uint32 maxRatioPpm
    );
    event SideConfigSet(
        bytes32 indexed bookId, uint8 side, uint32 field, uint32 floorValue, uint8 tierCount
    );

    constructor(QuaySharedLiquidityAMM venue_) ConfigurableStrategy(venue_) {}

    // ------------------------------------------------------------------
    // Maker configuration
    // ------------------------------------------------------------------

    function setConfig(bytes32 bookId, Config calldata c) external onlyBookOwner(bookId) {
        if (!c.exists || c.maxAgeSeconds == 0) revert BadConfig();
        if (c.maxRatioPpm > PPM) revert BadConfig();
        configs[bookId] = c;
        emit ConfigSet(bookId, c.basePerSecond, c.maxAgeSeconds, c.defaultPick, c.maxRatioPpm);
    }

    function setSideConfig(
        bytes32 bookId,
        uint8 side,
        uint32 field,
        uint32 floorValue,
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
        s.field = field;
        s.floorValue = floorValue;
        // casting to 'uint8' is safe: ladder.length <= MAX_TIERS == 4
        // forge-lint: disable-next-line(unsafe-typecast)
        s.tierCount = uint8(ladder.length);
        for (uint256 i = 0; i < ladder.length; i++) {
            s.ladder[i] = ladder[i];
        }
        // casting to 'uint8' is safe: ladder.length <= MAX_TIERS == 4
        // forge-lint: disable-next-line(unsafe-typecast)
        emit SideConfigSet(bookId, side, field, floorValue, uint8(ladder.length));
    }

    function getSideConfig(bytes32 bookId, uint8 side)
        external
        view
        returns (uint32 field, uint32 floorValue, Tier[] memory ladder)
    {
        SideConfig storage s = sides[bookId][side];
        field = s.field;
        floorValue = s.floorValue;
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

        // Hard staleness gate (June mainnet gate is 3 slots; configurable).
        uint256 age = block.timestamp - q.updatedAt;
        if (age >= c.maxAgeSeconds) return (0, 0, 0, QuoteReason.QuoteExpired);

        if (token0In && amountIn > uint256(q.maxIn0)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return (0, 0, 0, QuoteReason.SizeExceeded);
        }
        if (netAmountIn == 0 || q.bidPxX128 == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        uint256 outPerfect = token0In
            ? Math.mulDiv(netAmountIn, q.bidPxX128, Q128)
            : Math.mulDiv(netAmountIn, Q128, q.bidPxX128);
        if (outPerfect == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        // Fill ratio against live output-side depth (inv_out floored at 1).
        uint256 ratioPpm = Math.mulDiv(outPerfect, PPM, Math.max(availableOut, 1));
        if (c.maxRatioPpm != 0 && ratioPpm > c.maxRatioPpm) {
            return (0, 0, 0, QuoteReason.InsufficientLiquidity);
        }

        // Field-by-field assignment keeps the outer frame below the EVM stack
        // limit; every field is set before use.
        // slither-disable-next-line uninitialized-local
        PenaltyInput memory p;
        p.mid = q.bidPxX128;
        p.token0In = token0In;
        p.netAmountIn = netAmountIn;
        p.ratioPpm = ratioPpm;
        p.age = age;
        return _applyPenalties(bookId, c, p);
    }

    struct PenaltyInput {
        uint256 mid;
        bool token0In;
        uint256 netAmountIn;
        uint256 ratioPpm;
        uint256 age;
    }

    function _applyPenalties(bytes32 bookId, Config storage c, PenaltyInput memory p)
        internal
        view
        returns (uint256 amountOut, uint256 appliedPriceX128, uint32 appliedDecayBps, QuoteReason)
    {
        SideConfig storage sc = sides[bookId][p.token0In ? 0 : 1];

        // June fused haircut, in ppb: (pick + age * base) * 100_000 / 256.
        // At age 0 the field term is dropped (the sd=0 discount).
        uint256 basePick = sc.floorValue != 0 ? sc.floorValue : c.defaultPick;
        uint256 pick = p.age >= 1 ? Math.max(basePick, sc.field) : basePick;
        uint256 constantPpb = ((pick + p.age * c.basePerSecond) * 100_000) / 256;

        // Signed total: negative ladder offsets may push factor above PPB
        // (price improvement past a tier boundary), matching the binary.
        // casting to 'int256' is safe: constantPpb <= (2*uint32.max)*100_000/256 << 2^255
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 totalPpb = int256(constantPpb) + _ladderPpm(sc, p.ratioPpm) * 1000;
        // casting to 'int256' is safe: PPB is the constant 1e9
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 factorNum = int256(PPB) - totalPpb;
        if (factorNum <= 0) return (0, 0, 0, QuoteReason.InsufficientLiquidity);
        // casting to 'uint256' is safe: factorNum > 0 was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 factor = uint256(factorNum);

        // Single fused floor division per side, as the original settles.
        amountOut = p.token0In
            ? Math.mulDiv(p.netAmountIn * factor, p.mid, Q128 * PPB)
            : Math.mulDiv(p.netAmountIn * factor, Q128, p.mid * PPB);
        if (amountOut == 0) return (0, 0, 0, QuoteReason.ZeroOutput);

        appliedPriceX128 =
            p.token0In ? Math.mulDiv(p.mid, factor, PPB) : Math.mulDiv(p.mid, PPB, factor);

        // Diagnostic: the freshness-decay component in bps (ppb / 1e5).
        uint256 freshnessBps = ((p.age * c.basePerSecond * 100_000) / 256) / 1e5;
        appliedDecayBps = freshnessBps > type(uint32).max
            ? type(uint32).max
            // casting to 'uint32' is safe: guarded by the ternary above
            // forge-lint: disable-next-line(unsafe-typecast)
            : uint32(freshnessBps);
        return (amountOut, appliedPriceX128, appliedDecayBps, QuoteReason.OK);
    }

    /// @dev Signed ladder in ppm: sum over active tiers (r >= T_n) of
    ///      K_n * (r - T_n) / PPM + Y_n.
    function _ladderPpm(SideConfig storage sc, uint256 ratioPpm)
        internal
        view
        returns (int256 spread)
    {
        uint256 tiers = sc.tierCount;
        for (uint256 i = 0; i < tiers; i++) {
            Tier storage t = sc.ladder[i];
            if (ratioPpm < t.thresholdRatioPpm) break; // sorted ascending
            // casting to 'int256' is safe: int64 widens; (ratioPpm - T) fits
            // uint64 after the threshold check; PPM is the constant 1e6
            // forge-lint: disable-next-line(unsafe-typecast)
            spread += (int256(t.slopePpm) * int256(ratioPpm - t.thresholdRatioPpm)) / int256(PPM)
                + t.offsetPpm;
        }
    }
}
