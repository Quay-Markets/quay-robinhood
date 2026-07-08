// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {BisonFiStrategy} from "src/strategies/BisonFiStrategy.sol";

contract BisonFiStrategyTest is StrategyTestBase {
    uint256 internal constant PPB = 1e9;
    uint256 internal constant PPM = 1e6;
    uint256 internal constant MID = 100; // token1 atoms per token0 atom

    // Base fixture inventories (GROUP_MATH): math0 = 1e24, math1 = 1e27.
    uint256 internal constant DEPTH1 = 1_000_000_000e18; // math1, side-0 output

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
                basePerSecond: 128, // base_882 analog (128*100_000/256 = 50 ppm/s)
                maxAgeSeconds: 5,
                defaultPick: 256, // L analog for floor == 0 sides
                maxRatioPpm: 700_000
            })
        );
        // side 0: field 256, floor 128. June rule: age 0 uses the floor only
        // (50 ppm); age >= 1 uses max(floor, field) = 256.
        BisonFiStrategy.Tier[] memory ladder = new BisonFiStrategy.Tier[](1);
        ladder[0] =
            BisonFiStrategy.Tier({thresholdRatioPpm: 100_000, slopePpm: 1000, offsetPpm: 50});
        strat.setSideConfig(book, 0, 256, 128, ladder);
        // side 1: field 512, floor 0 -> base_pick falls back to defaultPick.
        strat.setSideConfig(book, 1, 512, 0, new BisonFiStrategy.Tier[](0));
        vm.stopPrank();
    }

    /// @dev June haircut reference, independently computed, in ppb.
    function _constPpb(uint256 field, uint256 floorV, uint256 age) internal pure returns (uint256) {
        uint256 basePick = floorV != 0 ? floorV : 256; // defaultPick in fixture
        uint256 pick = age >= 1 && field > basePick ? field : basePick;
        return ((pick + age * 128) * 100_000) / 256;
    }

    function _outAfter(uint256 perfect, uint256 haircutPpb) internal pure returns (uint256) {
        return (perfect * (PPB - haircutPpb)) / PPB;
    }

    // ------------------------------------------------------------------
    // June fused haircut: pick rule + per-second decay
    // ------------------------------------------------------------------

    function test_FreshUsesFloorOnly_TheSd0Discount() public view {
        // age 0: pick = floor = 128 -> 50 ppm, the field (256) is dropped.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertTrue(r.valid);
        assertEq(_constPpb(256, 128, 0), 50_000);
        assertEq(r.amountOut, _outAfter(1e14, 50_000));
        assertEq(r.appliedDecayBps, 0);
        assertEq(r.appliedPriceX128, (MID * Q128 * (PPB - 50_000)) / PPB);
    }

    function test_StaleQuotePicksUpFieldAndDecay() public {
        // age 1: pick = max(128, 256) = 256; haircut = (256+128)*100_000/256.
        vm.warp(START + 1);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertEq(_constPpb(256, 128, 1), 150_000);
        assertEq(r.amountOut, _outAfter(1e14, 150_000));

        // age 2: (256 + 2*128)*100_000/256 = 200_000 ppb; decay diag = 1 bp.
        vm.warp(START + 2);
        r = amm.quoteExactInput(book, address(math0), 1e12);
        assertEq(r.amountOut, _outAfter(1e14, 200_000));
        assertEq(r.appliedDecayBps, 1);
    }

    function test_HardStalenessGateBeforeVenueExpiry() public {
        vm.warp(START + 5); // venue validUntil is START+10; strategy gates first
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.QuoteExpired));

        _pushQuote(book, _midQuote(2, MID * Q128));
        assertTrue(amm.quoteExactInput(book, address(math0), 1e12).valid);
    }

    function test_FloorZeroFallsBackToDefaultPick() public {
        // side 1 fresh: base_pick = defaultPick = 256 -> 100 ppm (not field 512).
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e14);
        assertEq(_constPpb(512, 0, 0), 100_000);
        assertEq(r.amountOut, _outAfter(1e12, 100_000));

        // age 1: pick = max(256, 512) = 512 -> (512+128)*100_000/256 = 250_000.
        vm.warp(START + 1);
        r = amm.quoteExactInput(book, address(math1), 1e14);
        assertEq(r.amountOut, _outAfter(1e12, 250_000));
    }

    // ------------------------------------------------------------------
    // Spread ladder on fill ratio (signed)
    // ------------------------------------------------------------------

    function test_LadderActivatesAtThreshold() public view {
        // perfect 1e26 of 1e27 depth -> r = 100_000 ppm: Y = 50 ppm kicks in.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e24);
        assertEq(r.amountOut, _outAfter(1e26, 50_000 + 50_000));

        // Just below: constant spread only.
        r = amm.quoteExactInput(book, address(math0), 1e24 - 1e13);
        assertEq(r.amountOut, _outAfter(uint256(1e24 - 1e13) * MID, 50_000));
    }

    function test_LadderSlopeGrowsWithRatio() public view {
        // r = 200_000: 1000*(100_000)/1e6 + 50 = 150 ppm ladder + 50 ppm const.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 2e24);
        assertEq(r.amountOut, _outAfter(2e26, 200_000));
    }

    function test_NegativeOffsetCanImprovePrice() public {
        // The binary's signed haircut: negative Y past a boundary can push
        // factor above 1e9 (taker gets better than mid).
        BisonFiStrategy.Tier[] memory ladder = new BisonFiStrategy.Tier[](1);
        ladder[0] = BisonFiStrategy.Tier({thresholdRatioPpm: 100_000, slopePpm: 0, offsetPpm: -100});
        vm.prank(maker);
        strat.setSideConfig(book, 0, 256, 128, ladder);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e24);
        // total = 50_000 - 100_000 = -50_000 ppb -> factor 1_000_050_000.
        assertEq(r.amountOut, (uint256(1e26) * 1_000_050_000) / PPB);
        assertGt(r.amountOut, 1e26);
    }

    function test_HaircutOver100PercentRejects() public {
        // Huge field at age >= 1 (dropped at age 0 by the sd0 rule).
        vm.prank(maker);
        strat.setSideConfig(book, 0, type(uint32).max, 128, new BisonFiStrategy.Tier[](0));

        assertTrue(amm.quoteExactInput(book, address(math0), 1e12).valid); // age 0

        vm.warp(START + 1);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.InsufficientLiquidity));
    }

    function test_MaxRatioGateIsOptional() public {
        // With the calibration gate: r = 800_000 > 700_000 rejects.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 8e24);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.InsufficientLiquidity));

        // June model has no fixed gate: disabling it lets the ladder price it.
        vm.prank(maker);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true, basePerSecond: 128, maxAgeSeconds: 5, defaultPick: 256, maxRatioPpm: 0
            })
        );
        r = amm.quoteExactInput(book, address(math0), 8e24);
        assertTrue(r.valid);
        // ladder at r=800_000: 1000*700_000/1e6 + 50 = 750 ppm; +50 ppm const.
        assertEq(r.amountOut, _outAfter(8e26, 800_000));
    }

    function test_DepthIsSharedGroupInventory() public {
        QuaySharedLiquidityAMM.QuoteResult memory before =
            amm.quoteExactInput(book, address(math0), 1e23);
        assertEq(before.amountOut, _outAfter(1e25, 50_000)); // r = 10_000, no tier

        vm.prank(maker);
        amm.withdraw(GROUP_MATH, address(math1), DEPTH1 - 1e26, maker);

        // Same trade, 10x fill ratio through shared inventory: tier activates.
        QuaySharedLiquidityAMM.QuoteResult memory afterQ =
            amm.quoteExactInput(book, address(math0), 1e23);
        assertEq(afterQ.amountOut, _outAfter(1e25, 100_000));
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
                exists: true, basePerSecond: 1, maxAgeSeconds: 1, defaultPick: 1, maxRatioPpm: 0
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
                exists: true, basePerSecond: 128, maxAgeSeconds: 0, defaultPick: 256, maxRatioPpm: 0
            })
        );
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(
            book,
            BisonFiStrategy.Config({
                exists: true,
                basePerSecond: 128,
                maxAgeSeconds: 5,
                defaultPick: 256,
                maxRatioPpm: uint32(PPM) + 1
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
        (uint32 field, uint32 floorValue, BisonFiStrategy.Tier[] memory ladder) =
            strat.getSideConfig(book, 0);
        assertEq(field, 256);
        assertEq(floorValue, 128);
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
        assertLe(amm.quoteExactInput(book, address(math0), 1e12).amountOut, out1);
    }
}
