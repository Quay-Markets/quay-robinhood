// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {MockAggregatorV3} from "test/utils/MockAggregatorV3.sol";

contract OracleTest is QuayTestBase {
    MockAggregatorV3 internal feed;

    // WETH/USDC book: token0 18 dec, token1 6 dec, feed 8 dec (USD per WETH).
    // priceScale = Q128 * 10^6 / (10^8 * 10^18) = Q128 / 1e20.
    uint256 internal constant PRICE_SCALE = uint256(1 << 128) / 1e20;
    uint32 internal constant MAX_AGE = 60;
    uint16 internal constant DEV_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
        feed = new MockAggregatorV3(8);
        feed.set(2000e8, block.timestamp); // matches the 1999/2001 quote mid
        vm.prank(maker);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE);
    }

    function _reason(QuaySharedLiquidityAMM.QuoteResult memory r) internal pure returns (uint8) {
        return uint8(r.reason);
    }

    // ------------------------------------------------------------------
    // Guard behavior
    // ------------------------------------------------------------------

    function test_Oracle_FreshInRangeQuoteValid() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertTrue(r.valid);
        // Guard must not change the price itself.
        assertApproxEqAbs(r.amountOut, 1_993_003_000, 1);
    }

    function test_Oracle_DeviationBlocksQuoteAndSwap() public {
        // Feed says 2100, quote mid is 2000 -> ~4.76% > 1%.
        feed.set(2100e8, block.timestamp);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertFalse(r.valid);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleDeviation));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        weth.mint(taker, 1e18);
        vm.startPrank(taker);
        weth.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector,
                QuaySharedLiquidityAMM.QuoteReason.OracleDeviation
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();
    }

    function test_Oracle_DeviationBoundary() public {
        // 4.76% mid-vs-ref deviation: passes at 5% tolerance, fails at 4%.
        feed.set(2100e8, block.timestamp);

        vm.prank(maker);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, 500, PRICE_SCALE);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.prank(maker);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, 400, PRICE_SCALE);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleDeviation));

        // Deviation must be measured relative to the oracle reference, not the
        // quote mid: diff/ref = 4.762%, diff/mid = 5.0%. At 4.80% tolerance the
        // ref basis passes while a mid basis would reject.
        vm.prank(maker);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, 480, PRICE_SCALE);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);
    }

    function test_Oracle_StaleFeed() public {
        vm.warp(START + MAX_AGE); // exactly at the age bound: still fine
        _pushWethQuote(2); // re-arm quote freshness after the warp
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.warp(START + MAX_AGE + 1);
        _pushWethQuote(3);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleStale));
    }

    function test_Oracle_NonPositiveAnswer() public {
        feed.set(0, block.timestamp);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleInvalid));

        feed.set(-1, block.timestamp);
        r = amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleInvalid));
    }

    function test_Oracle_RevertingFeedIsInvalidNotReverting() public {
        feed.setRevert(true);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleInvalid));
    }

    function test_Oracle_OverflowingAnswerIsInvalidNotReverting() public {
        feed.set(type(int256).max, block.timestamp);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuaySharedLiquidityAMM.QuoteReason.OracleInvalid));
    }

    function test_Oracle_UnguardedBookUnaffected() public {
        feed.setRevert(true);
        assertTrue(amm.quoteExactInput(mathBook, address(math0), 1e18).valid);
    }

    function test_Oracle_DetachRestoresQuoting() public {
        feed.set(2100e8, block.timestamp);
        assertFalse(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.prank(maker);
        amm.setBookOracle(wethBook, address(0), 0, 0, 0);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);
    }

    // ------------------------------------------------------------------
    // Config validation
    // ------------------------------------------------------------------

    function test_SetBookOracle_EmitsAndStores() public {
        vm.expectEmit(true, true, false, true, address(amm));
        emit QuaySharedLiquidityAMM.BookOracleSet(
            wethBook, address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE
        );
        vm.prank(protocolOwner);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE);

        (address f, uint32 age, uint16 dev, uint256 scale) = amm.oracleConfigs(wethBook);
        assertEq(f, address(feed));
        assertEq(age, MAX_AGE);
        assertEq(dev, DEV_BPS);
        assertEq(scale, PRICE_SCALE);
    }

    function test_SetBookOracle_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE);
    }

    function test_SetBookOracle_RevertBadParams() public {
        vm.startPrank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.BadOracleConfig.selector);
        amm.setBookOracle(wethBook, address(feed), 0, DEV_BPS, PRICE_SCALE);
        vm.expectRevert(QuaySharedLiquidityAMM.BadOracleConfig.selector);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, 0, PRICE_SCALE);
        vm.expectRevert(QuaySharedLiquidityAMM.BadOracleConfig.selector);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, 10_001, PRICE_SCALE);
        vm.expectRevert(QuaySharedLiquidityAMM.BadOracleConfig.selector);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, DEV_BPS, 0);
        vm.expectRevert(QuaySharedLiquidityAMM.BadOracleConfig.selector);
        amm.setBookOracle(wethBook, taker, MAX_AGE, DEV_BPS, PRICE_SCALE); // no code
        vm.stopPrank();
    }
}
