// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";

/// @dev The aggregator-facing property: books sharing a liquidity group share
///      fillability but never price. A swap in book A can shrink what book B
///      can pay out, yet must not move book B's bid/ask or quote nonce.
contract SharedLiquidityTest is QuayTestBase {
    bytes32 internal btcBook;

    // 599/601 USDC atoms per CBBTC atom == ~60k USDC per BTC (8 dec), zero fee.
    uint256 internal constant BID_BTC = 599 * (1 << 128);
    uint256 internal constant ASK_BTC = 601 * (1 << 128);

    function setUp() public override {
        super.setUp();

        vm.prank(protocolOwner);
        btcBook = amm.createBook(
            address(cbbtc), address(usdc), GROUP_MAIN, bytes32("BTCUSDC"), 0, address(bbo), updater
        );
        _deposit(GROUP_MAIN, cbbtc, 10e8);

        QuayTypes.QuoteState memory q = _wethQuote(1);
        q.bidPxX128 = BID_BTC;
        q.askPxX128 = ASK_BTC;
        q.maxIn0 = 10e8;
        q.maxIn1 = 600_000e6;
        _pushQuote(btcBook, q);
    }

    function test_SwapDoesNotMoveSiblingBookPrice() public {
        QuaySharedLiquidityAMM.QuoteResult memory before =
            amm.quoteExactInput(btcBook, address(cbbtc), 1e8);
        assertTrue(before.valid);
        assertEq(before.amountOut, 599e8); // 1 BTC -> 59,900 USDC, exact

        // Large WETH sale consumes shared USDC inventory.
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 50e18, 0));

        QuaySharedLiquidityAMM.QuoteResult memory afterQ =
            amm.quoteExactInput(btcBook, address(cbbtc), 1e8);

        // Price state is untouched: same price, output, and quote nonce...
        assertTrue(afterQ.valid);
        assertEq(afterQ.amountOut, before.amountOut);
        assertEq(afterQ.appliedPriceX128, before.appliedPriceX128);
        assertEq(afterQ.quoteNonce, before.quoteNonce);

        // ...but shared fillability moved: less USDC, bumped inventory nonce.
        assertLt(afterQ.availableOut, before.availableOut);
        assertEq(afterQ.inventoryNonceOut, before.inventoryNonceOut + 1);

        // Both books disclose the same dependency group.
        assertEq(afterQ.liquidityGroupId, GROUP_MAIN);
        QuaySharedLiquidityAMM.QuoteResult memory wethQ =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(wethQ.liquidityGroupId, afterQ.liquidityGroupId);
    }

    function test_SharedDrainMakesSiblingUnfillable() public {
        // Two max-size WETH sales drain ~398,600 of the 500,000 USDC pool.
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 100e18, 0));
        _pushWethQuote(2); // re-arm freshness for the second fill
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 100e18, 0));

        uint256 usdcLeft = amm.inventory(GROUP_MAIN, address(usdc));
        assertLt(usdcLeft, 120_000e6);

        // 2 BTC needs ~119,800 USDC out; the shared pool can no longer pay.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(btcBook, address(cbbtc), 2e8);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.InsufficientLiquidity));
        assertEq(r.availableOut, usdcLeft);

        // A smaller size still fills at the same price.
        r = amm.quoteExactInput(btcBook, address(cbbtc), 1e8);
        assertTrue(r.valid);
        assertEq(r.amountOut, 599e8);
    }

    function test_InventoryNonceGuardCatchesSharedRace() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(btcBook, address(cbbtc), 1e8);

        // A WETH swap lands first and bumps the shared USDC inventory nonce.
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 1e18, 0));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(btcBook, address(cbbtc), address(usdc), 1e8, 0);
        p.expectedInventoryNonceOut = q.inventoryNonceOut;

        cbbtc.mint(taker, 1e8);
        vm.startPrank(taker);
        cbbtc.approve(address(amm), 1e8);
        vm.expectRevert(QuaySharedLiquidityAMM.InventoryNonceMismatch.selector);
        amm.swapExactInputSingle(p);

        // Without the guard the swap fills at the unchanged book price.
        p.expectedInventoryNonceOut = 0;
        uint256 out = amm.swapExactInputSingle(p);
        vm.stopPrank();
        assertEq(out, q.amountOut);
    }

    function test_IsolatedGroupsAreUnaffected() public {
        QuaySharedLiquidityAMM.QuoteResult memory before =
            amm.quoteExactInput(mathBook, address(math0), 1e18);

        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 50e18, 0));

        QuaySharedLiquidityAMM.QuoteResult memory afterQ =
            amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertEq(afterQ.amountOut, before.amountOut);
        assertEq(afterQ.availableOut, before.availableOut);
        assertEq(afterQ.inventoryNonceOut, before.inventoryNonceOut);
    }

    function test_DepositRaisesFillabilityForAllBooksInGroup() public {
        uint256 beforeAvail = amm.quoteExactInput(btcBook, address(cbbtc), 1e8).availableOut;
        _deposit(GROUP_MAIN, usdc, 100_000e6);

        assertEq(
            amm.quoteExactInput(btcBook, address(cbbtc), 1e8).availableOut, beforeAvail + 100_000e6
        );
        assertEq(
            amm.quoteExactInput(wethBook, address(weth), 1e18).availableOut, beforeAvail + 100_000e6
        );
    }
}
