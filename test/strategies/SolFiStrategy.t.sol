// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ConfigurableStrategy} from "src/strategies/ConfigurableStrategy.sol";
import {SolFiStrategy} from "src/strategies/SolFiStrategy.sol";

contract SolFiStrategyTest is StrategyTestBase {
    uint256 internal constant PREC = 1e7;
    uint256 internal constant MID = 100; // token1 atoms per token0 atom
    uint32 internal constant RAMP = 25;
    uint32 internal constant MAX_AGE = 200;

    SolFiStrategy internal strat;
    bytes32 internal book;

    function setUp() public override {
        super.setUp();
        strat = new SolFiStrategy(amm);
        _approveModule(address(strat));
        book = _newMathBook(address(strat), bytes32("SOLFI"));
        _pushLongQuote(1);

        vm.prank(maker);
        strat.setConfig(book, _config(0));
    }

    /// @dev The freshness window outlives the venue default, so tests can walk
    ///      the full 25s ramp and the 200s gate.
    function _pushLongQuote(uint64 nonce) internal {
        QuayTypes.QuoteState memory q = _midQuote(nonce, MID * Q128);
        q.freshUntil = uint64(block.timestamp) + 300;
        q.validUntil = uint64(block.timestamp) + 300;
        _pushQuote(book, q);
    }

    function _config(uint32 feePpm7) internal pure returns (SolFiStrategy.Config memory) {
        return SolFiStrategy.Config({
            exists: true,
            rampSeconds: RAMP, // the original's ~25-slot ramp
            maxAgeSeconds: MAX_AGE, // the original's 200-slot window
            feePpm7: feePpm7,
            c1Fresh: 10_000_000, // hardcoded C_FRESH == fee precision
            c1Stale: 9_950_000, // ~50 bps worse for the taker when stale
            c0Fresh: 10_000_000,
            c0Stale: 10_100_000 // sell side worsens by divisor growth
        });
    }

    /// @dev The pinned interpolation, computed independently:
    ///      C = (fresh*(ramp-clipped) + stale*clipped) / ramp.
    function _c(uint256 fresh, uint256 stale, uint256 delta) internal pure returns (uint256) {
        uint256 clipped = delta > RAMP ? RAMP : delta;
        return (fresh * (RAMP - clipped) + stale * clipped) / RAMP;
    }

    // ------------------------------------------------------------------
    // Slot-decay pricing
    // ------------------------------------------------------------------

    function test_FreshQuoteIsTight() public view {
        // delta 0: C1 = C0 = PRECISION, fee 0 -> exact mid both ways.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e12);
        assertEq(r.amountOut, 1e10); // netIn / mid
        assertEq(r.appliedDecayBps, 0);

        r = amm.quoteExactInput(book, address(math0), 1e12);
        assertEq(r.amountOut, 1e14); // netIn * mid
    }

    function test_MidRampInterpolatesExactly() public {
        vm.warp(START + 10); // clipped 10 of 25
        // C1 = (1e7*15 + 9_950_000*10)/25 = 9_980_000
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e12);
        assertEq(r.amountOut, (uint256(1e12) * 9_980_000) / (MID * PREC));
        assertEq(r.appliedDecayBps, 4000); // 10/25 of the ramp in bps

        // C0 = (1e7*15 + 10_100_000*10)/25 = 10_040_000
        r = amm.quoteExactInput(book, address(math0), 1_004e9);
        assertEq(r.amountOut, (uint256(1_004e9) * MID * PREC) / 10_040_000);
        assertEq(r.amountOut, 1e14); // chosen to divide exactly
    }

    function test_EveryRampStepMatchesReference() public {
        for (uint256 d = 0; d <= RAMP; d++) {
            vm.warp(START + d);
            uint256 out = amm.quoteExactInput(book, address(math1), 1e12).amountOut;
            uint256 expected = (uint256(1e12) * _c(10_000_000, 9_950_000, d)) / (MID * PREC);
            assertEq(out, expected);
        }
    }

    function test_StalePlateauHolds() public {
        vm.warp(START + 30); // past the 25s ramp, inside the 200s window
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e12);
        assertEq(r.amountOut, (uint256(1e12) * 9_950_000) / (MID * PREC));
        assertEq(r.appliedDecayBps, 10_000); // stale plateau

        vm.warp(START + 150); // same plateau much later
        assertEq(
            amm.quoteExactInput(book, address(math1), 1e12).amountOut,
            (uint256(1e12) * 9_950_000) / (MID * PREC)
        );
    }

    function test_HardFreshnessGate() public {
        vm.warp(START + MAX_AGE - 1);
        assertTrue(amm.quoteExactInput(book, address(math1), 1e12).valid);

        vm.warp(START + MAX_AGE); // strict < boundary, 0x83 analog
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math1), 1e12);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.QuoteExpired));

        // A refresh re-arms the gate.
        _pushLongQuote(2);
        assertTrue(amm.quoteExactInput(book, address(math1), 1e12).valid);
    }

    function test_LinearFeeApplies() public {
        vm.prank(maker);
        strat.setConfig(book, _config(1_000_000)); // 10% in 1e-7 units

        assertEq(amm.quoteExactInput(book, address(math1), 1e12).amountOut, 9e9);
        assertEq(amm.quoteExactInput(book, address(math0), 1e12).amountOut, 9e13);
    }

    function test_MidComesFromQuotePipeline() public {
        QuayTypes.QuoteState memory q = _midQuote(2, 2 * MID * Q128);
        _pushQuote(book, q);
        assertEq(amm.quoteExactInput(book, address(math0), 1e12).amountOut, 2e14);
    }

    function testFuzz_StalenessOnlyWorsensBothSides(uint256 d1, uint256 d2) public {
        d1 = bound(d1, 0, MAX_AGE - 1);
        d2 = bound(d2, d1, MAX_AGE - 1);

        vm.warp(START + d1);
        uint256 buy1 = amm.quoteExactInput(book, address(math1), 1e12).amountOut;
        uint256 sell1 = amm.quoteExactInput(book, address(math0), 1e12).amountOut;
        vm.warp(START + d2);
        assertLe(amm.quoteExactInput(book, address(math1), 1e12).amountOut, buy1);
        assertLe(amm.quoteExactInput(book, address(math0), 1e12).amountOut, sell1);
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
        vm.prank(taker);
        vm.expectRevert(ConfigurableStrategy.NotBookOwner.selector);
        strat.setConfig(book, _config(0));
    }

    function test_SetConfig_Validation() public {
        SolFiStrategy.Config memory c = _config(0);
        vm.startPrank(maker);

        c.rampSeconds = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config(0);
        c.maxAgeSeconds = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config(uint32(PREC)); // fee == precision
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config(0);
        c.c1Stale = 0;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);

        c = _config(0);
        c.exists = false;
        vm.expectRevert(ConfigurableStrategy.BadConfig.selector);
        strat.setConfig(book, c);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Venue integration
    // ------------------------------------------------------------------

    function test_SizeCapsStillApply() public {
        QuayTypes.QuoteState memory q = _midQuote(2, MID * Q128);
        q.maxIn0 = 1e12;
        _pushQuote(book, q);

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(book, address(math0), 1e12 + 1);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.SizeExceeded));
    }

    function test_SwapSettlesAtQuotedAmount() public {
        vm.warp(START + 7); // mid-ramp
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math1), 1e12);
        uint256 out =
            _swapAs(taker, _swapParams(book, address(math1), address(math0), 1e12, q.amountOut));
        assertEq(out, q.amountOut);
    }

    function testFuzz_QuoteMatchesSwap(uint256 amountIn, uint256 age) public {
        amountIn = bound(amountIn, 1e6, 1e18);
        age = bound(age, 0, 60);
        vm.warp(START + age);

        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(book, address(math1), amountIn);
        assertTrue(q.valid);
        uint256 out = _swapAs(taker, _swapParams(book, address(math1), address(math0), amountIn, 0));
        assertEq(out, q.amountOut);
    }
}
