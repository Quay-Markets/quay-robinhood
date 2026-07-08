// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {BisonFiStrategy} from "src/strategies/BisonFiStrategy.sol";

contract BisonFiStrategyTest is StrategyTestBase {
    uint256 internal constant PPM = 1e6;
    uint256 internal constant MID = 100; // token1 atoms per token0 atom

    // Base fixture inventories (GROUP_MATH): math0 = 1e24, math1 = 1e27.
    uint256 internal constant DEPTH1 = 1_000_000_000e18; // math1, side-0 output
    uint256 internal constant DEPTH0 = 1_000_000e18; // math0, side-1 output

    BisonFiStrategy internal strat;
    bytes32 internal book;

    function setUp() public override {
        super.setUp();
        strat = new BisonFiStrategy(amm);
        _approveModule(address(strat));
        book = _newMathBook(address(strat), bytes32("BISONFI"));
        _pushQuote(book, _midQuote(1, MID * Q128));

        vm.startPrank(maker);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true,
                ppmPerSecond: 50, // the original's 50 ppm/slot
                maxAgeSeconds: 5, // the original's 5-slot hard gate
                maxRatioPpm: 700_000 // the original's ~0.7 fill-ratio bail
            })
        );
        // side 0: max(256, 128) * 100 / 256 = 100 ppm constant spread,
        // one ladder tier activating at 10% fill ratio.
        BisonFiStrategy.Tier[] memory ladder = new BisonFiStrategy.Tier[](1);
        ladder[0] =
            BisonFiStrategy.Tier({thresholdRatioPpm: 100_000, slopePpm: 1000, offsetPpm: 50});
        strat.setSideConfig(book, 0, 256, 128, ladder);
        // side 1: max(512, 0) * 100 / 256 = 200 ppm, no ladder.
        strat.setSideConfig(book, 1, 512, 0, new BisonFiStrategy.Tier[](0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Constant spread + freshness haircut
    // ------------------------------------------------------------------

    function test_FreshQuote_ConstantSpreadOnly() public view {
        // netIn 1e12 -> perfect 1e14; fill ratio ~0.1 ppm -> no ladder tier.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertTrue(r.valid);
        assertEq(r.amountOut, (uint256(1e14) * (PPM - 100)) / PPM);
        assertEq(r.appliedDecayBps, 0);
        assertEq(r.appliedPriceX128, (MID * Q128 * (PPM - 100)) / PPM);
    }

    function test_FreshnessHaircutAccruesPerSecond() public {
        vm.warp(START + 2); // 2s * 50 ppm = 100 ppm freshness on top
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertEq(r.amountOut, (uint256(1e14) * (PPM - 200)) / PPM);
        assertEq(r.appliedDecayBps, 1); // 100 ppm freshness = 1 bp
    }

    function test_HardStalenessGateBeforeVenueExpiry() public {
        vm.warp(START + 5); // venue validUntil is START+10, strategy gates first
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.QuoteExpired));

        // A fresh quote push re-arms the gate.
        _pushQuote(book, _midQuote(2, MID * Q128));
        assertTrue(amm.quoteExactInput(book, address(math0), 1e12).valid);
    }

    function test_AsymmetricSideSpreads() public view {
        // side 1 carries 200 ppm: netIn 1e14 token1 -> perfect 1e12 token0.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e14);
        assertEq(r.amountOut, (uint256(1e12) * (PPM - 200)) / PPM);
        assertEq(r.appliedPriceX128, (MID * Q128 * PPM) / (PPM - 200));
    }

    // ------------------------------------------------------------------
    // Spread ladder on fill ratio
    // ------------------------------------------------------------------

    function test_LadderActivatesAtThreshold() public view {
        // perfect 1e26 of 1e27 depth -> r = 100_000 ppm exactly: Y kicks in.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e24);
        assertEq(r.amountOut, (uint256(1e26) * (PPM - 150)) / PPM); // 100 + 50

        // Below the threshold only the constant spread applies.
        r = amm.quoteExactInput(book, address(math0), 1e24 - 1e13);
        uint256 perfect = uint256(1e24 - 1e13) * MID;
        assertEq(r.amountOut, (perfect * (PPM - 100)) / PPM);
    }

    function test_LadderSlopeGrowsWithRatio() public view {
        // perfect 2e26 -> r = 200_000: 1000 * (200_000-100_000)/1e6 + 50 = 150.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 2e24);
        assertEq(r.amountOut, (uint256(2e26) * (PPM - 250)) / PPM); // 100 + 150
    }

    function test_MaxFillRatioRejected() public view {
        // perfect 8e26 of 1e27 depth -> r = 800_000 > 700_000.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 8e24);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.InsufficientLiquidity));
    }

    function test_DepthIsSharedGroupInventory() public {
        // Same trade, but the maker pulls 90% of math1: ratio grows 10x and
        // the ladder tier activates purely through shared-inventory depth.
        QuaySharedLiquidityAMM.QuoteResult memory before =
            amm.quoteExactInput(book, address(math0), 1e23);
        assertEq(before.amountOut, (uint256(1e25) * (PPM - 100)) / PPM); // r = 10_000

        vm.prank(maker);
        amm.withdraw(GROUP_MATH, address(math1), DEPTH1 - 1e26, maker);

        QuaySharedLiquidityAMM.QuoteResult memory afterQ =
            amm.quoteExactInput(book, address(math0), 1e23);
        assertEq(afterQ.amountOut, (uint256(1e25) * (PPM - 150)) / PPM); // r = 100_000
    }

    function test_SpreadOverflowRejectsQuote() public {
        // A pathological constant spread >= 100% must reject, not underflow.
        vm.prank(maker);
        strat.setSideConfig(book, 0, type(uint32).max, 0, new BisonFiStrategy.Tier[](0));
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.InsufficientLiquidity));
    }

    // ------------------------------------------------------------------
    // Config governance
    // ------------------------------------------------------------------

    function test_Unconfigured() public {
        bytes32 bare = _newMathBook(address(strat), bytes32("BARE"));
        _pushQuote(bare, _midQuote(1, MID * Q128));
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bare, address(math0), 1e12);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.BadPrices));
    }

    function test_SetConfig_RevertStranger() public {
        vm.startPrank(taker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true, ppmPerSecond: 1, maxAgeSeconds: 1, maxRatioPpm: 1
            })
        );
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setSideConfig(book, 0, 0, 0, new BisonFiStrategy.Tier[](0));
        vm.stopPrank();
    }

    function test_SetConfig_Validation() public {
        vm.startPrank(maker);
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true, ppmPerSecond: 50, maxAgeSeconds: 0, maxRatioPpm: 700_000
            })
        );
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true, ppmPerSecond: 50, maxAgeSeconds: 5, maxRatioPpm: 0
            })
        );
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true, ppmPerSecond: 50, maxAgeSeconds: 5, maxRatioPpm: uint32(PPM) + 1
            })
        );

        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSideConfig(book, 2, 0, 0, new BisonFiStrategy.Tier[](0)); // bad side

        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSideConfig(book, 0, 0, 0, new BisonFiStrategy.Tier[](5)); // too many

        BisonFiStrategy.Tier[] memory unsorted = new BisonFiStrategy.Tier[](2);
        unsorted[0] = BisonFiStrategy.Tier({thresholdRatioPpm: 5000, slopePpm: 0, offsetPpm: 0});
        unsorted[1] = BisonFiStrategy.Tier({thresholdRatioPpm: 5000, slopePpm: 0, offsetPpm: 0});
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSideConfig(book, 0, 0, 0, unsorted);
        vm.stopPrank();
    }

    function test_GetSideConfigRoundTrip() public view {
        (uint32 constSpread, uint32 constFloor, BisonFiStrategy.Tier[] memory ladder) =
            strat.getSideConfig(book, 0);
        assertEq(constSpread, 256);
        assertEq(constFloor, 128);
        assertEq(ladder.length, 1);
        assertEq(ladder[0].thresholdRatioPpm, 100_000);
        assertEq(ladder[0].slopePpm, 1000);
        assertEq(ladder[0].offsetPpm, 50);
    }

    // ------------------------------------------------------------------
    // Venue integration
    // ------------------------------------------------------------------

    function test_SwapSettlesAtQuotedAmount() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math0), 1e12);
        uint256 out =
            _swapAs(taker, _swapParams(book, address(math0), address(math1), 1e12, q.amountOut));
        assertEq(out, q.amountOut);
    }

    function testFuzz_QuoteMatchesSwap(uint256 amountIn, uint256 age) public {
        amountIn = bound(amountIn, 1e6, 1e24);
        age = bound(age, 0, 4);
        vm.warp(START + age);

        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math0), amountIn);
        assertTrue(q.valid);
        uint256 out = _swapAs(taker, _swapParams(book, address(math0), address(math1), amountIn, 0));
        assertEq(out, q.amountOut);
    }

    function testFuzz_PenaltyOnlyWorsensWithAge(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 0, 4);
        a2 = bound(a2, a1, 4);

        vm.warp(START + a1);
        uint256 out1 = amm.quoteExactInput(book, address(math0), 1e12).amountOut;
        vm.warp(START + a2);
        uint256 out2 = amm.quoteExactInput(book, address(math0), 1e12).amountOut;
        assertLe(out2, out1);
    }
}
