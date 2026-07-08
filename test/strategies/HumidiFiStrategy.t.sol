// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {HumidiFiStrategy} from "src/strategies/HumidiFiStrategy.sol";

contract HumidiFiStrategyTest is StrategyTestBase {
    uint256 internal constant DENOM = 1e8;
    uint256 internal constant MID = 100; // token1 atoms per token0 atom

    HumidiFiStrategy internal strat;
    bytes32 internal book;

    function setUp() public override {
        super.setUp();
        strat = new HumidiFiStrategy(amm);
        _approveModule(address(strat));
        book = _newMathBook(address(strat), bytes32("HUMIDIFI"));
        _pushQuote(book, _midQuote(1, MID * Q128));

        vm.prank(maker);
        strat.setConfig(book, _config());
    }

    function _config() internal pure returns (HumidiFiStrategy.Config memory) {
        return HumidiFiStrategy.Config({
            exists: true,
            circuitBreaker: 0,
            baseSpread: 50_000, // 5 bps in 1e-8 units
            sqrtDiv: 1e4,
            linDiv: 1e9,
            kickSpread: 594, // the original's discrete tier kick
            maxSpread: 400_000, // 40 bps, the state[48] analog
            kickThreshold: 0 // kick exercised in its own dedicated test
        });
    }

    /// @dev Independent reference: fitted-model spread + the authoritative
    ///      multiply-by-(1-s) single-division settlement.
    function _refOut(uint256 netIn, bool token0In) internal pure returns (uint256) {
        uint256 perfect = token0In ? netIn * MID : netIn / MID;
        uint256 spread = 50_000 + _isqrt(perfect / 1e4) + perfect / 1e9;
        if (spread > 400_000) spread = 400_000;
        return token0In
            ? (netIn * (DENOM - spread) * MID) / DENOM
            : (netIn * (DENOM - spread)) / (MID * DENOM);
    }

    function _isqrt(uint256 v) internal pure returns (uint256 r) {
        if (v == 0) return 0;
        r = v;
        uint256 next = (v / 2) + 1;
        while (next < r) {
            r = next;
            next = (v / next + next) / 2;
        }
    }

    // ------------------------------------------------------------------
    // Spread math
    // ------------------------------------------------------------------

    function test_SmoothSpreadExact() public view {
        // netIn 4e10 -> perfect 4e12; isqrt(4e8)=20_000; linear 4_000.
        // spread = 50_000 + 20_000 + 4_000 = 74_000 units (7.4 bps).
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 4e10);
        assertTrue(r.valid);
        assertEq(r.amountOut, (uint256(4e10) * (DENOM - 74_000) * MID) / DENOM);
        assertEq(r.amountOut, _refOut(4e10, true));
        assertEq(r.appliedDecayBps, 7); // 74_000 units / 1e4 -> 7 bps
        assertEq(r.appliedPriceX128, (MID * Q128 * (DENOM - 74_000)) / DENOM);
    }

    function test_ReverseDirectionExact() public view {
        // Sell token1: netIn 1e14 -> perfect 1e12; isqrt(1e8)=10_000; lin 1_000.
        // spread = 61_000.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e14);
        assertEq(r.amountOut, (uint256(1e14) * (DENOM - 61_000)) / (MID * DENOM));
        assertEq(r.amountOut, _refOut(1e14, false));
        // Taker buys token0 at the widened price.
        assertEq(r.appliedPriceX128, (MID * Q128 * DENOM) / (DENOM - 61_000));
    }

    function test_KickAppliesExactlyAtInputThreshold() public {
        // The original tier selector compares raw amount_in. Pick a size where
        // the smooth spread (~61_000) is far from the cap so the kick shows.
        HumidiFiStrategy.Config memory c = _config();
        c.kickThreshold = 1e10;
        vm.prank(maker);
        strat.setConfig(book, c);

        uint256 below = amm.quoteExactInput(book, address(math0), 1e10 - 1).amountOut;
        uint256 at = amm.quoteExactInput(book, address(math0), 1e10).amountOut;

        // Below the boundary: smooth spread only (netIn 1e10-1 ~ spread 60_998).
        assertEq(below, _refOut(1e10 - 1, true));
        // At the boundary: +594 on top of the smooth 61_000.
        assertEq(at, (uint256(1e10) * (DENOM - 61_594) * MID) / DENOM);
        assertLt(at, _refOut(1e10, true)); // strictly worse than no-kick
    }

    function test_FlatSpreadRegime() public {
        // sqrtDiv = linDiv = 0 disables the fitted penalty: the replay-verified
        // flat regime, spread == baseSpread for any size.
        HumidiFiStrategy.Config memory c = _config();
        c.sqrtDiv = 0;
        c.linDiv = 0;
        c.kickThreshold = 0;
        vm.prank(maker);
        strat.setConfig(book, c);

        assertEq(
            amm.quoteExactInput(book, address(math0), 1e10).amountOut,
            (uint256(1e10) * (DENOM - 50_000) * MID) / DENOM
        );
        assertEq(
            amm.quoteExactInput(book, address(math0), 1e15).amountOut,
            (uint256(1e15) * (DENOM - 50_000) * MID) / DENOM
        );
    }

    function test_SpreadIsCapped() public view {
        // Huge input: the linear term alone would exceed the 40 bps cap.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e16);
        assertEq(r.amountOut, (uint256(1e16) * (DENOM - 400_000) * MID) / DENOM);
        assertEq(r.appliedDecayBps, 40);
    }

    function test_MidComesFromQuotePipeline() public {
        _pushQuote(book, _midQuote(2, 2 * MID * Q128)); // keeper doubles the mid
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 4e10);
        // perfect doubles; recompute the reference at the new mid.
        uint256 perfect = uint256(4e10) * 2 * MID;
        uint256 spread = 50_000 + _isqrt(perfect / 1e4) + perfect / 1e9;
        assertEq(r.amountOut, (uint256(4e10) * (DENOM - spread) * 2 * MID) / DENOM);
    }

    function testFuzz_TakerNeverBeatsMid(uint256 netIn) public view {
        netIn = bound(netIn, 1, 1e20);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), netIn);
        if (!r.valid) return;
        uint256 perfect = netIn * MID;
        assertLt(r.amountOut, perfect); // spread is always > 0
        assertGe(r.amountOut, (perfect * (DENOM - 400_000)) / DENOM); // cap floor
    }

    // ------------------------------------------------------------------
    // Circuit breaker
    // ------------------------------------------------------------------

    function test_CircuitBreakerHaltsAtThreshold() public {
        vm.prank(maker);
        strat.setCircuitBreaker(book, 99); // below the halt threshold
        assertTrue(amm.quoteExactInput(book, address(math0), 1e10).valid);

        vm.prank(maker);
        strat.setCircuitBreaker(book, 100);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e10);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.BookNotActive));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(book, address(math0), address(math1), 1e10, 0);
        math0.mint(taker, 1e10);
        vm.startPrank(taker);
        math0.approve(address(amm), 1e10);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector, QuayTypes.QuoteReason.BookNotActive
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();

        vm.prank(maker);
        strat.setCircuitBreaker(book, 0);
        assertTrue(amm.quoteExactInput(book, address(math0), 1e10).valid);
    }

    // ------------------------------------------------------------------
    // Config governance
    // ------------------------------------------------------------------

    function test_Unconfigured() public {
        bytes32 bare = _newMathBook(address(strat), bytes32("BARE"));
        _pushQuote(bare, _midQuote(1, MID * Q128));
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bare, address(math0), 1e10);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.BadPrices));
    }

    function test_SetConfig_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setConfig(book, _config());

        vm.prank(taker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setCircuitBreaker(book, 100);
    }

    function test_SetConfig_Validation() public {
        HumidiFiStrategy.Config memory c = _config();
        vm.startPrank(maker);

        c.maxSpread = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config();
        c.maxSpread = uint64(DENOM);
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config();
        c.exists = false;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Venue integration
    // ------------------------------------------------------------------

    function test_SwapSettlesAtQuotedAmount() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math0), 4e10);
        uint256 out =
            _swapAs(taker, _swapParams(book, address(math0), address(math1), 4e10, q.amountOut));
        assertEq(out, q.amountOut);
    }

    function testFuzz_QuoteMatchesSwap(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e4, 1e15);
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math0), amountIn);
        assertTrue(q.valid);
        uint256 out = _swapAs(taker, _swapParams(book, address(math0), address(math1), amountIn, 0));
        assertEq(out, q.amountOut);
    }
}
