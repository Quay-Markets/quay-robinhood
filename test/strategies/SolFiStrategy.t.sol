// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {SolFiStrategy} from "src/strategies/SolFiStrategy.sol";

contract SolFiStrategyTest is StrategyTestBase {
    SolFiStrategy internal strat;
    bytes32 internal book;

    // Side-0 spline: sell math0. x = input atoms, y = output atoms.
    uint128[] internal xs0 = [uint128(0), 1e12, 2e12, 4e12];
    uint128[] internal ys0 = [uint128(0), 99e12, 190e12, 360e12];

    // Side-1 spline: sell math1, flatter curve.
    uint128[] internal xs1 = [uint128(0), 1e12];
    uint128[] internal ys1 = [uint128(0), 5e11];

    function setUp() public override {
        super.setUp();
        strat = new SolFiStrategy(amm);
        _approveModule(address(strat));
        book = _newMathBook(address(strat), bytes32("SOLFI"));
        _pushQuote(book, _midQuote(1, Q128)); // heartbeat; prices unused

        vm.startPrank(maker);
        strat.setSpline(book, 0, xs0, ys0);
        strat.setSpline(book, 1, xs1, ys1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Spline math
    // ------------------------------------------------------------------

    function test_ExactAtControlPoints() public view {
        assertEq(amm.quoteExactInput(book, address(math0), 1e12).amountOut, 99e12);
        assertEq(amm.quoteExactInput(book, address(math0), 2e12).amountOut, 190e12);
        assertEq(amm.quoteExactInput(book, address(math0), 4e12).amountOut, 360e12);
    }

    function test_InterpolatesBetweenPoints() public view {
        // Segment [1e12, 2e12): 99e12 + 0.5e12 * (190e12 - 99e12) / 1e12
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 15e11);
        assertEq(r.amountOut, 99e12 + 455e11);
        // Diagnostic price: out * Q128 / in.
        assertEq(r.appliedPriceX128, (uint256(1445e11) << 128) / 15e11);
    }

    function test_SaturatesBeyondLastPoint() public view {
        assertEq(amm.quoteExactInput(book, address(math0), 8e12).amountOut, 360e12);
        assertEq(amm.quoteExactInput(book, address(math0), 1e18).amountOut, 360e12);
    }

    function test_FirstSegmentFromZero() public view {
        // floor(7 * 99e12 / 1e12) = 693
        assertEq(amm.quoteExactInput(book, address(math0), 7).amountOut, 693);
    }

    function test_SidesAreIndependent() public view {
        assertEq(amm.quoteExactInput(book, address(math1), 1e12).amountOut, 5e11);
        assertEq(amm.quoteExactInput(book, address(math1), 5e11).amountOut, 25e10);
    }

    function test_UnconfiguredSideRejects() public {
        bytes32 half = _newMathBook(address(strat), bytes32("HALF"));
        _pushQuote(half, _midQuote(1, Q128));
        vm.prank(maker);
        strat.setSpline(half, 0, xs0, ys0);

        assertTrue(amm.quoteExactInput(half, address(math0), 1e12).valid);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(half, address(math1), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.BadPrices));
    }

    function testFuzz_OutputIsMonotone(uint256 a, uint256 b) public view {
        a = bound(a, 1, 1e19);
        b = bound(b, a, 1e19);
        assertLe(
            amm.quoteExactInput(book, address(math0), a).amountOut,
            amm.quoteExactInput(book, address(math0), b).amountOut
        );
    }

    // ------------------------------------------------------------------
    // Config governance
    // ------------------------------------------------------------------

    function test_SetSpline_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setSpline(book, 0, xs0, ys0);
    }

    function test_SetSpline_ProtocolOwnerAllowed() public {
        vm.prank(protocolOwner);
        strat.setSpline(book, 0, xs0, ys0);
    }

    function test_SetSpline_RevertUnknownBook() public {
        vm.prank(maker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setSpline(bytes32("nope"), 0, xs0, ys0);
    }

    function test_SetSpline_Validation() public {
        uint128[] memory x = new uint128[](2);
        uint128[] memory y = new uint128[](2);

        vm.startPrank(maker);
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 2, xs0, ys0); // bad side

        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, new uint128[](0), new uint128[](0)); // empty

        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, new uint128[](9), new uint128[](9)); // too long

        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, x, new uint128[](3)); // length mismatch

        x[0] = 1; // x[0] must be 0
        x[1] = 2;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, x, y);

        x[0] = 0;
        x[1] = 0; // x not strictly increasing
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, x, y);

        x[1] = 5;
        y[0] = 10;
        y[1] = 9; // y decreasing
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setSpline(book, 0, x, y);
        vm.stopPrank();
    }

    function test_GetSplineRoundTrip() public view {
        (uint128[] memory x, uint128[] memory y) = strat.getSpline(book, 0);
        assertEq(x.length, 4);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(x[i], xs0[i]);
            assertEq(y[i], ys0[i]);
        }
    }

    // ------------------------------------------------------------------
    // Venue integration
    // ------------------------------------------------------------------

    function test_SwapSettlesAtSplinePrice() public {
        uint256 out =
            _swapAs(taker, _swapParams(book, address(math0), address(math1), 15e11, 1445e11));
        assertEq(out, 1445e11);
        assertEq(math1.balanceOf(recipient), 1445e11);
    }

    function test_HeartbeatExpiryStillGates() public {
        vm.warp(START + VALID_SECONDS + 1);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.QuoteExpired));
    }

    function test_SizeCapsStillApply() public {
        QuayTypes.QuoteState memory q = _midQuote(2, Q128);
        q.maxIn0 = 1e12;
        _pushQuote(book, q);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12 + 1);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.SizeExceeded));
    }

    function testFuzz_QuoteMatchesSwap(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 4e12);
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math0), amountIn);
        assertTrue(q.valid);
        uint256 out = _swapAs(taker, _swapParams(book, address(math0), address(math1), amountIn, 0));
        assertEq(out, q.amountOut);
    }
}
