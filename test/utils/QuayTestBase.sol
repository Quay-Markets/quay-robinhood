// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {BBOStrategy} from "src/strategies/BBOStrategy.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

/// @dev Shared fixture: one liquidity group owned by `maker`, a fee-charging
///      WETH/USDC book with a realistic price, and a fee-free "math" book with
///      integer prices so expected outputs are exact.
abstract contract QuayTestBase is Test {
    uint256 internal constant Q128 = 1 << 128;
    uint64 internal constant START = 1_700_000_000;
    uint16 internal constant FEE_BPS = 30;

    bytes32 internal constant GROUP_MAIN = keccak256("GROUP_MAIN");
    bytes32 internal constant GROUP_MATH = keccak256("GROUP_MATH");

    // WETH/USDC quote defaults: ~2000 USDC per WETH with a 2 USDC spread.
    uint256 internal BID_WETH; // 1999 USDC atoms-per-WETH-atom in Q128
    uint256 internal ASK_WETH; // 2001 USDC atoms-per-WETH-atom in Q128
    uint128 internal constant MAX_IN0 = 100e18; // max WETH in
    uint128 internal constant MAX_IN1 = 300_000e6; // max USDC in

    // Math book: integer prices, zero fee, 18-dec tokens on both sides.
    uint256 internal constant BID_MATH = 100 * Q128;
    uint256 internal constant ASK_MATH = 200 * Q128;

    uint32 internal constant DECAY_PER_SEC = 100;
    uint32 internal constant MAX_DECAY = 500;
    uint64 internal constant FRESH_SECONDS = 2;
    uint64 internal constant VALID_SECONDS = 10;

    QuaySharedLiquidityAMM internal amm;
    BBOStrategy internal bbo;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal cbbtc;
    MockERC20 internal math0;
    MockERC20 internal math1;

    address internal protocolOwner;
    address internal maker;
    address internal updater;
    address internal taker;
    address internal recipient;

    bytes32 internal wethBook;
    bytes32 internal mathBook;

    function setUp() public virtual {
        vm.warp(START);

        protocolOwner = makeAddr("protocolOwner");
        maker = makeAddr("maker");
        updater = makeAddr("updater");
        taker = makeAddr("taker");
        recipient = makeAddr("recipient");

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cbbtc = new MockERC20("Coinbase BTC", "CBBTC", 8);
        math0 = new MockERC20("Math0", "M0", 18);
        math1 = new MockERC20("Math1", "M1", 18);

        BID_WETH = (1999e6 * Q128) / 1e18;
        ASK_WETH = (2001e6 * Q128) / 1e18;

        amm = new QuaySharedLiquidityAMM(protocolOwner);
        bbo = new BBOStrategy();

        vm.startPrank(protocolOwner);
        amm.registerStrategy(address(bbo));
        amm.setStrategyApproval(address(bbo), true);
        amm.createLiquidityGroup(GROUP_MAIN, maker);
        amm.createLiquidityGroup(GROUP_MATH, maker);
        wethBook = amm.createBook(
            address(weth),
            address(usdc),
            GROUP_MAIN,
            bytes32("WETHUSDC"),
            FEE_BPS,
            address(bbo),
            updater
        );
        mathBook = amm.createBook(
            address(math0), address(math1), GROUP_MATH, bytes32("MATH"), 0, address(bbo), updater
        );
        vm.stopPrank();

        _deposit(GROUP_MAIN, weth, 100e18);
        _deposit(GROUP_MAIN, usdc, 500_000e6);
        _deposit(GROUP_MATH, math0, 1_000_000e18);
        _deposit(GROUP_MATH, math1, 1_000_000_000e18);

        _pushWethQuote(1);
        _pushMathQuote(1);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(bytes32 groupId, MockERC20 token, uint256 amount) internal {
        token.mint(maker, amount);
        vm.startPrank(maker);
        token.approve(address(amm), amount);
        amm.deposit(groupId, address(token), amount);
        vm.stopPrank();
    }

    function _wethQuote(uint64 nonce) internal view returns (QuayTypes.QuoteState memory) {
        return QuayTypes.QuoteState({
            nonce: nonce,
            updatedAt: 0, // overwritten by the contract
            freshUntil: uint64(block.timestamp) + FRESH_SECONDS,
            validUntil: uint64(block.timestamp) + VALID_SECONDS,
            decayBpsPerSecond: DECAY_PER_SEC,
            maxDecayBps: MAX_DECAY,
            bidPxX128: BID_WETH,
            askPxX128: ASK_WETH,
            maxIn0: MAX_IN0,
            maxIn1: MAX_IN1,
            sourceHash: keccak256("source")
        });
    }

    function _mathQuote(uint64 nonce) internal view returns (QuayTypes.QuoteState memory) {
        QuayTypes.QuoteState memory q = _wethQuote(nonce);
        q.bidPxX128 = BID_MATH;
        q.askPxX128 = ASK_MATH;
        q.maxIn0 = 10_000e18;
        q.maxIn1 = 10_000_000e18;
        return q;
    }

    function _pushQuote(bytes32 bookId, QuayTypes.QuoteState memory q) internal {
        vm.prank(updater);
        amm.updateQuote(bookId, q);
    }

    function _pushWethQuote(uint64 nonce) internal {
        _pushQuote(wethBook, _wethQuote(nonce));
    }

    function _pushMathQuote(uint64 nonce) internal {
        _pushQuote(mathBook, _mathQuote(nonce));
    }

    function _swapParams(
        bytes32 bookId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal view returns (QuaySharedLiquidityAMM.SwapExactInputSingleParams memory) {
        return QuaySharedLiquidityAMM.SwapExactInputSingleParams({
            bookId: bookId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            recipient: recipient,
            deadline: uint64(block.timestamp) + 60,
            expectedQuoteNonce: 0,
            expectedInventoryNonceOut: 0
        });
    }

    /// @dev Mints tokenIn to `taker`, approves, and swaps. Returns amountOut.
    function _swapAs(address who, QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p)
        internal
        returns (uint256)
    {
        MockERC20(p.tokenIn).mint(who, p.amountIn);
        vm.startPrank(who);
        MockERC20(p.tokenIn).approve(address(amm), p.amountIn);
        uint256 out = amm.swapExactInputSingle(p);
        vm.stopPrank();
        return out;
    }
}
