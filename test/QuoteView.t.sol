// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";

contract QuoteViewTest is QuayTestBase {
    using QuoteAssertions for QuaySharedLiquidityAMM.QuoteResult;

    // ------------------------------------------------------------------
    // Fresh quote math (math book: fee 0, bid 100, ask 200, exact integers)
    // ------------------------------------------------------------------

    function test_Quote_FreshSellToken0Exact() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertTrue(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.OK));
        assertEq(r.amountOut, 100e18); // 1e18 * 100
        assertEq(r.feeAmount, 0);
        assertEq(r.netAmountIn, 1e18);
        assertEq(r.appliedPriceX128, BID_MATH);
        assertEq(r.appliedDecayBps, 0);
        assertEq(r.tokenIn, address(math0));
        assertEq(r.tokenOut, address(math1));
        assertEq(r.liquidityGroupId, GROUP_MATH);
        assertEq(r.quoteNonce, 1);
        assertEq(r.availableOut, 1_000_000_000e18);
    }

    function test_Quote_FreshSellToken1Exact() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math1), 200e18);
        assertTrue(r.valid);
        assertEq(r.amountOut, 1e18); // 200e18 / 200
        assertEq(r.appliedPriceX128, ASK_MATH);
        assertEq(r.tokenOut, address(math0));
    }

    // ------------------------------------------------------------------
    // Fee math (WETH book: 30 bps input-side fee, realistic price)
    // ------------------------------------------------------------------

    function test_Quote_InputSideFeeSellWeth() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertTrue(r.valid);
        assertEq(r.feeAmount, 3e15); // 1e18 * 30 / 10_000
        assertEq(r.netAmountIn, 997e15);
        // 0.997 WETH * 1999 USDC; Q128 flooring may lose at most 1 atom.
        assertApproxEqAbs(r.amountOut, 1_993_003_000, 1);
    }

    function test_Quote_InputSideFeeSellUsdc() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(usdc), 2001e6);
        assertTrue(r.valid);
        assertEq(r.feeAmount, 6_003_000); // 2001e6 * 30 / 10_000
        assertEq(r.netAmountIn, 1_994_997_000);
        // net is exactly 0.997 * ask price -> 0.997 WETH, minus Q128 flooring.
        assertApproxEqAbs(r.amountOut, 997e15, 1);
    }

    // ------------------------------------------------------------------
    // Decay
    // ------------------------------------------------------------------

    function test_Quote_NoDecayAtFreshBoundary() public {
        vm.warp(START + FRESH_SECONDS);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertEq(r.appliedDecayBps, 0);
        assertEq(r.amountOut, 100e18);
    }

    function test_Quote_DecayedBidAndAsk() public {
        vm.warp(START + FRESH_SECONDS + 3); // 3s past fresh -> 300 bps
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertEq(r.appliedDecayBps, 300);
        assertEq(r.appliedPriceX128, 97 * Q128); // 100 * (10000-300)/10000
        assertEq(r.amountOut, 97e18);

        r = amm.quoteExactInput(mathBook, address(math1), 206e18);
        assertEq(r.appliedPriceX128, 206 * Q128); // 200 * (10000+300)/10000
        assertEq(r.amountOut, 1e18);
    }

    function test_Quote_DecayCapped() public {
        vm.warp(START + FRESH_SECONDS + 6); // 600 bps uncapped -> capped at 500
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertEq(r.appliedDecayBps, 500);
        assertEq(r.appliedPriceX128, 95 * Q128);
        assertEq(r.amountOut, 95e18);

        r = amm.quoteExactInput(mathBook, address(math1), 210e18);
        assertEq(r.appliedPriceX128, 210 * Q128);
        assertEq(r.amountOut, 1e18);
    }

    function test_Quote_ValidAtValidUntilBoundary() public {
        vm.warp(START + VALID_SECONDS);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertTrue(r.valid);
        assertEq(r.appliedDecayBps, 500); // capped
    }

    function test_Quote_ExpiredAfterValidUntil() public {
        vm.warp(START + VALID_SECONDS + 1);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.QuoteExpired);
    }

    // ------------------------------------------------------------------
    // Invalid reasons
    // ------------------------------------------------------------------

    function test_Quote_BookMissing() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bytes32("nope"), address(weth), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.BookMissing);
    }

    function test_Quote_BookNotActive() public {
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.BookNotActive);

        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Closed);
        r = amm.quoteExactInput(wethBook, address(weth), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.BookNotActive);
    }

    function test_Quote_GroupPaused() public {
        vm.prank(maker);
        amm.setLiquidityGroupPaused(GROUP_MAIN, true);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.GroupPaused);
    }

    function test_Quote_WrongToken() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(math0), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.WrongToken);
    }

    function test_Quote_AmountZero() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 0);
        r.assertInvalid(QuayTypes.QuoteReason.AmountZero);
    }

    function test_Quote_QuoteMissing() public {
        vm.prank(protocolOwner);
        bytes32 bookId = amm.createBook(
            address(cbbtc), address(usdc), GROUP_MAIN, bytes32("BTC"), 10, address(bbo), updater
        );
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(cbbtc), 1e8);
        r.assertInvalid(QuayTypes.QuoteReason.QuoteMissing);
    }

    function test_Quote_SizeExceeded() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), uint256(MAX_IN0) + 1);
        r.assertInvalid(QuayTypes.QuoteReason.SizeExceeded);

        r = amm.quoteExactInput(wethBook, address(usdc), uint256(MAX_IN1) + 1);
        r.assertInvalid(QuayTypes.QuoteReason.SizeExceeded);

        // Exactly at the cap is allowed (inventory permitting).
        r = amm.quoteExactInput(wethBook, address(weth), uint256(MAX_IN0));
        assertTrue(r.valid);
    }

    function test_Quote_ZeroOutput() public view {
        // 100 atoms of token1 at ask 200 floors to zero token0 out.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math1), 100);
        r.assertInvalid(QuayTypes.QuoteReason.ZeroOutput);

        // 1 WETH atom is worth ~2e-9 USDC atoms -> floors to zero.
        r = amm.quoteExactInput(wethBook, address(weth), 1);
        r.assertInvalid(QuayTypes.QuoteReason.ZeroOutput);
    }

    function test_Quote_InsufficientLiquidity() public {
        // Drain USDC so a 1-WETH sale cannot be paid out.
        vm.prank(maker);
        amm.withdraw(GROUP_MAIN, address(usdc), 500_000e6 - 1000e6, maker);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        r.assertInvalid(QuayTypes.QuoteReason.InsufficientLiquidity);
        assertEq(r.availableOut, 1000e6);
    }

    // ------------------------------------------------------------------
    // quotePriceOnly
    // ------------------------------------------------------------------

    function test_QuotePriceOnly_MatchesQuoteWhenFillable() public view {
        QuaySharedLiquidityAMM.QuoteResult memory a =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        QuaySharedLiquidityAMM.QuoteResult memory b =
            amm.quotePriceOnly(wethBook, address(weth), 1e18);
        assertEq(a.amountOut, b.amountOut);
        assertEq(uint8(a.reason), uint8(b.reason));
    }

    function test_QuotePriceOnly_ShowsPriceDespiteInsufficientLiquidity() public {
        vm.prank(maker);
        amm.withdraw(GROUP_MAIN, address(usdc), 500_000e6 - 1000e6, maker);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quotePriceOnly(wethBook, address(weth), 1e18);
        assertTrue(r.valid);
        assertGt(r.amountOut, 0);
        assertEq(r.availableOut, 1000e6);
        assertGt(r.amountOut, r.availableOut); // signals unfillable
    }

    // ------------------------------------------------------------------
    // Best-of and batch
    // ------------------------------------------------------------------

    function test_QuoteBestExactInput_PicksBestBook() public {
        // Second WETH/USDC book with zero fee and a better bid.
        vm.prank(protocolOwner);
        bytes32 betterBook = amm.createBook(
            address(weth), address(usdc), GROUP_MAIN, bytes32("BETTER"), 0, address(bbo), updater
        );
        QuayTypes.QuoteState memory q = _wethQuote(1);
        q.bidPxX128 = (2000e6 * Q128) / 1e18;
        _pushQuote(betterBook, q);

        QuaySharedLiquidityAMM.QuoteResult memory best =
            amm.quoteBestExactInput(address(weth), address(usdc), 1e18);
        assertTrue(best.valid);
        assertEq(best.bookId, betterBook);
        // Zero fee at 2000 vs 30 bps fee at 1999.
        assertApproxEqAbs(best.amountOut, 2_000_000_000, 1);
    }

    function test_QuoteBestExactInput_SkipsInvalidBooks() public {
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
        QuaySharedLiquidityAMM.QuoteResult memory best =
            amm.quoteBestExactInput(address(weth), address(usdc), 1e18);
        assertFalse(best.valid);
        assertEq(best.amountOut, 0);
    }

    function test_QuoteBestExactInput_NoBooksForPair() public view {
        QuaySharedLiquidityAMM.QuoteResult memory best =
            amm.quoteBestExactInput(address(weth), address(cbbtc), 1e18);
        best.assertInvalid(QuayTypes.QuoteReason.BookMissing);
    }

    function test_BatchQuoteExactInput() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = wethBook;
        ids[1] = mathBook;
        QuaySharedLiquidityAMM.QuoteResult[] memory rs =
            amm.batchQuoteExactInput(ids, address(weth), 1e18);
        assertEq(rs.length, 2);
        assertTrue(rs[0].valid);
        assertFalse(rs[1].valid);
        assertEq(uint8(rs[1].reason), uint8(QuayTypes.QuoteReason.WrongToken));
    }

    // ------------------------------------------------------------------
    // Result metadata
    // ------------------------------------------------------------------

    function test_Quote_MetadataFields() public view {
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(r.bookId, wethBook);
        assertEq(r.amountIn, 1e18);
        assertEq(r.updatedAt, START);
        assertEq(r.freshUntil, START + FRESH_SECONDS);
        assertEq(r.validUntil, START + VALID_SECONDS);
        assertEq(r.inventoryNonceOut, amm.inventoryNonce(GROUP_MAIN, address(usdc)));
    }
}

library QuoteAssertions {
    function assertInvalid(
        QuaySharedLiquidityAMM.QuoteResult memory r,
        QuayTypes.QuoteReason reason
    ) internal pure {
        require(!r.valid, "expected invalid quote");
        require(uint8(r.reason) == uint8(reason), "unexpected reason");
        require(r.amountOut == 0, "expected zero amountOut");
    }
}
