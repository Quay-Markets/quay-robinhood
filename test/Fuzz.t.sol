// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";

contract FuzzTest is QuayTestBase {
    /// @dev The quoter is the source of truth: a swap in the same block must
    ///      settle at exactly the quoted amount.
    function testFuzz_SwapMatchesQuote(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, uint256(MAX_IN0));
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), amountIn);
        assertTrue(q.valid);

        uint256 out = _swapAs(
            taker, _swapParams(wethBook, address(weth), address(usdc), amountIn, q.amountOut)
        );
        assertEq(out, q.amountOut);
    }

    /// @dev Input-side fee: fee + net always reconstruct amountIn exactly, and
    ///      the venue's books stay solvent after settlement.
    function testFuzz_SwapAccountingConsistent(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, uint256(MAX_IN0));
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), amountIn);
        assertTrue(q.valid);
        assertEq(q.feeAmount + q.netAmountIn, amountIn);
        assertEq(q.feeAmount, (amountIn * uint256(FEE_BPS)) / 10_000);

        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), amountIn, 0));

        assertEq(
            weth.balanceOf(address(amm)),
            amm.inventory(GROUP_MAIN, address(weth)) + amm.protocolFees(GROUP_MAIN, address(weth))
        );
        assertEq(
            usdc.balanceOf(address(amm)),
            amm.inventory(GROUP_MAIN, address(usdc)) + amm.protocolFees(GROUP_MAIN, address(usdc))
        );
    }

    /// @dev With any bid <= ask, selling token0 and selling the proceeds back
    ///      can never return more token0 than was put in.
    function testFuzz_RoundTripNeverProfits(uint256 amountIn, uint256 bidRaw, uint256 spreadRaw)
        public
    {
        uint256 bid = bound(bidRaw, Q128 / 1e6, 1000 * Q128);
        uint256 ask = bid + bound(spreadRaw, 0, bid);
        amountIn = bound(amountIn, 1, 1e24);

        _deposit(GROUP_MATH, math1, 1e30);
        QuayTypes.QuoteState memory q = _mathQuote(2);
        q.bidPxX128 = bid;
        q.askPxX128 = ask;
        q.maxIn0 = type(uint128).max;
        q.maxIn1 = type(uint128).max;
        _pushQuote(mathBook, q);

        QuaySharedLiquidityAMM.QuoteResult memory leg1 =
            amm.quoteExactInput(mathBook, address(math0), amountIn);
        vm.assume(leg1.valid);

        QuaySharedLiquidityAMM.QuoteResult memory leg2 =
            amm.quoteExactInput(mathBook, address(math1), leg1.amountOut);
        vm.assume(leg2.valid);

        assertLe(leg2.amountOut, amountIn);
    }

    /// @dev As a quote ages, the taker price only worsens on both sides.
    function testFuzz_DecayIsMonotone(uint256 t1, uint256 t2) public {
        t1 = bound(t1, 0, VALID_SECONDS);
        t2 = bound(t2, t1, VALID_SECONDS);

        vm.warp(START + t1);
        uint256 sellOut1 = amm.quoteExactInput(mathBook, address(math0), 1e18).amountOut;
        uint256 buyOut1 = amm.quoteExactInput(mathBook, address(math1), 1000e18).amountOut;

        vm.warp(START + t2);
        uint256 sellOut2 = amm.quoteExactInput(mathBook, address(math0), 1e18).amountOut;
        uint256 buyOut2 = amm.quoteExactInput(mathBook, address(math1), 1000e18).amountOut;

        assertLe(sellOut2, sellOut1);
        assertLe(buyOut2, buyOut1);
    }

    /// @dev Fee math holds for every configured fee tier.
    function testFuzz_FeeTiers(uint16 feeBps, uint256 amountIn) public {
        feeBps = uint16(bound(feeBps, 0, 9999));
        amountIn = bound(amountIn, 1e6, 1e27);

        vm.prank(protocolOwner);
        bytes32 bookId = amm.createBook(
            address(math0),
            address(math1),
            GROUP_MATH,
            bytes32("FEEBOOK"),
            feeBps,
            address(bbo),
            updater
        );
        QuayTypes.QuoteState memory q = _mathQuote(1);
        q.maxIn0 = type(uint128).max;
        _pushQuote(bookId, q);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(math0), amountIn);
        vm.assume(r.valid);

        assertEq(r.feeAmount, (amountIn * uint256(feeBps)) / 10_000);
        assertEq(r.netAmountIn + r.feeAmount, amountIn);
        assertEq(r.amountOut, r.netAmountIn * 100); // bid 100, exact
    }

    /// @dev A valid quote never promises more than the group's inventory.
    function testFuzz_QuoteNeverExceedsInventory(uint256 amountIn, uint256 inventoryOut) public {
        inventoryOut = bound(inventoryOut, 0, 1_000_000_000e18);
        amountIn = bound(amountIn, 1, 10_000e18);

        // Reset math1 inventory to the fuzzed level.
        vm.startPrank(maker);
        amm.withdraw(GROUP_MATH, address(math1), 1_000_000_000e18, maker);
        vm.stopPrank();
        if (inventoryOut > 0) _deposit(GROUP_MATH, math1, inventoryOut);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(mathBook, address(math0), amountIn);
        if (r.valid) {
            assertLe(r.amountOut, r.availableOut);
            assertEq(r.availableOut, inventoryOut);
        }
    }
}
