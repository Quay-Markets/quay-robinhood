// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {MockAggregatorV3} from "test/utils/MockAggregatorV3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
        vm.prank(protocolOwner);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE);
    }

    function _reason(QuaySharedLiquidityAMM.QuoteResult memory r) internal pure returns (uint8) {
        return uint8(r.reason);
    }

    function _setDeviation(uint16 devBps) internal {
        vm.prank(protocolOwner);
        amm.setBookOracle(wethBook, address(feed), MAX_AGE, devBps, PRICE_SCALE);
    }

    // ------------------------------------------------------------------
    // Guard behavior — bounds the EFFECTIVE executed price
    // ------------------------------------------------------------------

    function test_Oracle_FreshInRangeQuoteValid() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertTrue(r.valid);
        // Guard must not change the price itself.
        assertApproxEqAbs(r.amountOut, 1_993_003_000, 1);
    }

    function test_Oracle_DeviationBlocksQuoteAndSwap() public {
        // Feed says 2100; the taker's effective sell price is ~1999 -> 4.8% off.
        feed.set(2100e8, block.timestamp);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertFalse(r.valid);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleDeviation));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        weth.mint(taker, 1e18);
        vm.startPrank(taker);
        weth.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector, QuayTypes.QuoteReason.OracleDeviation
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();
    }

    function test_Oracle_DeviationBoundary() public {
        // Effective sell price ~1999 vs ref 2100: deficit/ref = 4.8095%.
        // Bound is ref * (1 - dev): passes from 481 bps up, rejects at 480.
        feed.set(2100e8, block.timestamp);

        _setDeviation(500);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        _setDeviation(481);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        _setDeviation(480);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleDeviation));
    }

    function test_Oracle_DecayedExecutionPriceIsGuarded() public {
        // The guard checks the executed price, not the posted mid: a decayed
        // quote (300 bps at +5s) drops the effective sell price to ~1939,
        // outside the 1% band around 2000, even though the posted mid is fine.
        vm.warp(START + FRESH_SECONDS + 3);
        feed.set(2000e8, block.timestamp);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertFalse(r.valid);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleDeviation));

        // A wider band admits the decayed execution.
        _setDeviation(400);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);
    }

    function test_Oracle_GuardsBothSides() public {
        // Selling token1: effective buy price ~2001 must stay under
        // ref * (1 + dev). Feed at 1900 -> maxPx = 1919 -> reject.
        feed.set(1900e8, block.timestamp);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(usdc), 2001e6);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleDeviation));

        feed.set(2000e8, block.timestamp);
        assertTrue(amm.quoteExactInput(wethBook, address(usdc), 2001e6).valid);
    }

    function test_Oracle_StaleFeed() public {
        vm.warp(START + MAX_AGE); // exactly at the age bound: still fine
        _pushWethQuote(2); // re-arm quote freshness after the warp
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.warp(START + MAX_AGE + 1);
        _pushWethQuote(3);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleStale));
    }

    function test_Oracle_ZeroOrFutureTimestampInvalid() public {
        feed.set(2000e8, 0);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));

        feed.set(2000e8, block.timestamp + 1);
        r = amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));
    }

    function test_Oracle_NonPositiveAnswer() public {
        feed.set(0, block.timestamp);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));

        feed.set(-1, block.timestamp);
        r = amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));
    }

    function test_Oracle_RevertingFeedIsInvalidNotReverting() public {
        feed.setRevert(true);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));
    }

    function test_Oracle_OverflowingAnswerIsInvalidNotReverting() public {
        feed.set(type(int256).max, block.timestamp);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(_reason(r), uint8(QuayTypes.QuoteReason.OracleInvalid));
    }

    function test_Oracle_UnguardedBookUnaffected() public {
        feed.setRevert(true);
        assertTrue(amm.quoteExactInput(mathBook, address(math0), 1e18).valid);
    }

    function test_Oracle_DetachRestoresQuoting() public {
        feed.set(2100e8, block.timestamp);
        assertFalse(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.prank(protocolOwner);
        amm.setBookOracle(wethBook, address(0), 0, 0, 0);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);
    }

    // ------------------------------------------------------------------
    // Config validation — protocol-owner only, makers cannot loosen
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

    function test_SetBookOracle_MakerCannotTouchTheGuard() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.setBookOracle(wethBook, address(0), 0, 0, 0);
    }

    function test_SetBookOracle_RevertUnknownBook() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidBook.selector);
        amm.setBookOracle(bytes32("nope"), address(feed), MAX_AGE, DEV_BPS, PRICE_SCALE);
    }

    function test_SetBookOracle_RevertBadParams() public {
        vm.startPrank(protocolOwner);
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
