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
            maxSpread: 400_000, // 40 bps, the original's cap
            kickThreshold: 5e12
        });
    }

    /// @dev Reference formula straight from the research doc:
    ///      spread = base + isqrt(out/sqrtDiv) + out/linDiv (+kick), capped.
    function _expectedOut(uint256 outPerfect, bool kicked) internal pure returns (uint256) {
        uint256 spread = 50_000 + _isqrt(outPerfect / 1e4) + outPerfect / 1e9;
        if (kicked) spread += 594;
        if (spread > 400_000) spread = 400_000;
        return (outPerfect * DENOM) / (DENOM + spread);
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
        assertEq(r.amountOut, (uint256(4e12) * DENOM) / (DENOM + 74_000));
        assertEq(r.amountOut, _expectedOut(4e12, false));
        assertEq(r.appliedDecayBps, 7); // 74_000 units / 1e4 = 7.4 -> 7 bps
        assertEq(r.appliedPriceX128, (MID * Q128 * DENOM) / (DENOM + 74_000));
    }

    function test_ReverseDirectionExact() public view {
        // Sell token1: netIn 1e14 -> perfect 1e12; isqrt(1e8)=10_000; lin 1_000.
        // spread = 50_000 + 10_000 + 1_000 = 61_000.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e14);
        assertEq(r.amountOut, (uint256(1e12) * DENOM) / (DENOM + 61_000));
        // Taker buys token0: effective price is the inflated mid.
        assertEq(r.appliedPriceX128, (MID * Q128 * (DENOM + 61_000)) / DENOM);
    }

    function test_KickAppliesExactlyAtThreshold() public view {
        uint256 below = amm.quoteExactInput(book, address(math0), 5e12 - 1).amountOut;
        uint256 at = amm.quoteExactInput(book, address(math0), 5e12).amountOut;

        assertEq(below, _expectedOut(uint256(5e12 - 1) * MID, false));
        assertEq(at, _expectedOut(uint256(5e12) * MID, true));
    }

    function test_KickThresholdIsInBaseTokenUnits() public view {
        // Selling token1: the base-token quantity is the perfect output.
        // netIn 1e14 -> 1e12 token0 < 5e12 threshold: no kick.
        uint256 small = amm.quoteExactInput(book, address(math1), 1e14).amountOut;
        assertEq(small, _expectedOut(1e12, false));

        // netIn 5e14 -> 5e12 token0 == threshold: kick applies.
        uint256 large = amm.quoteExactInput(book, address(math1), 5e14).amountOut;
        assertEq(large, _expectedOut(5e12, true));
    }

    function test_SpreadIsCapped() public view {
        // Huge input: linear term alone would exceed the 40 bps cap.
        uint256 netIn = 1e16; // perfect 1e18 -> linear term 1e9 units >> cap
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), netIn);
        assertEq(r.amountOut, (uint256(1e18) * DENOM) / (DENOM + 400_000));
        assertEq(r.appliedDecayBps, 40);
    }

    function test_MidComesFromQuotePipeline() public {
        _pushQuote(book, _midQuote(2, 2 * MID * Q128)); // keeper doubles the mid
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 4e10);
        assertEq(r.amountOut, _expectedOut(8e12, false));
    }

    function testFuzz_TakerNeverBeatsMid(uint256 netIn) public view {
        netIn = bound(netIn, 1, 1e20);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), netIn);
        if (!r.valid) return;
        uint256 perfect = netIn * MID;
        assertLt(r.amountOut, perfect); // spread is always > 0
        assertGe(r.amountOut, (perfect * DENOM) / (DENOM + 400_000)); // cap floor
    }

    // ------------------------------------------------------------------
    // Circuit breaker
    // ------------------------------------------------------------------

    function test_CircuitBreakerHaltsAtThreshold() public {
        vm.prank(maker);
        strat.setCircuitBreaker(book, 99); // degraded but quoting
        assertTrue(amm.quoteExactInput(book, address(math0), 1e10).valid);

        vm.prank(maker);
        strat.setCircuitBreaker(book, 100);
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e10);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.BookNotActive));

        // Swap reverts while tripped; funds untouched by design.
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

        c.sqrtDiv = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config();
        c.linDiv = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config();
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
