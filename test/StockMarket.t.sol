// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {MockERC20} from "test/utils/MockERC20.sol";
import {MockAggregatorV3} from "test/utils/MockAggregatorV3.sol";

/// @dev Executable recipe for a stock-token market: an off-chain daemon reads
///      Alpaca, posts bid/ask around the equity mid as signed quotes, a
///      protocol-set Chainlink guard bounds the executed price, and a shared
///      cranker account lands MANY independent makers' signed quotes in one
///      transaction (Solana-style update squeezing without shared authority).
contract StockMarketTest is QuayTestBase {
    MockERC20 internal aapl; // 18-dec stock token
    MockERC20 internal usdg; // 6-dec settlement stable
    MockAggregatorV3 internal feed; // 8-dec USD/share reference

    // priceScale = Q128 * 10^6 / (10^8 * 10^18): feed USD -> USDG atoms per
    // AAPL atom in Q128.
    uint256 internal constant PRICE_SCALE = uint256(1 << 128) / 1e20;
    uint16 internal constant GUARD_DEV_BPS = 200; // 2% band around the feed

    address internal makerA;
    address internal makerB;
    address internal updaterA;
    uint256 internal updaterAKey;
    address internal updaterB;
    uint256 internal updaterBKey;
    address internal cranker; // shared, untrusted submitter

    bytes32 internal constant GROUP_A = keccak256("STOCK_GROUP_A");
    bytes32 internal constant GROUP_B = keccak256("STOCK_GROUP_B");
    bytes32 internal bookA;
    bytes32 internal bookB;

    function setUp() public override {
        super.setUp();

        aapl = new MockERC20("AAPL Stock Token", "AAPL", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8);
        feed.set(190e8, block.timestamp); // $190.00 per share

        makerA = makeAddr("stockMakerA");
        makerB = makeAddr("stockMakerB");
        (updaterA, updaterAKey) = makeAddrAndKey("stockUpdaterA");
        (updaterB, updaterBKey) = makeAddrAndKey("stockUpdaterB");
        cranker = makeAddr("cranker");

        vm.startPrank(protocolOwner);
        amm.setTokenAllowed(address(aapl), true);
        amm.setTokenAllowed(address(usdg), true);
        amm.createLiquidityGroup(GROUP_A, makerA);
        amm.createLiquidityGroup(GROUP_B, makerB);
        bookA = amm.createBook(
            address(aapl), address(usdg), GROUP_A, bytes32("AAPL_A"), 0, address(bbo), updaterA
        );
        bookB = amm.createBook(
            address(aapl), address(usdg), GROUP_B, bytes32("AAPL_B"), 0, address(bbo), updaterB
        );
        // Venue-level guard: executed price must stay within 2% of the feed.
        amm.setBookOracle(bookA, address(feed), 60, GUARD_DEV_BPS, PRICE_SCALE);
        amm.setBookOracle(bookB, address(feed), 60, GUARD_DEV_BPS, PRICE_SCALE);
        vm.stopPrank();

        _depositAs(makerA, GROUP_A);
        _depositAs(makerB, GROUP_B);
    }

    function _depositAs(address who, bytes32 groupId) internal {
        aapl.mint(who, 1_000e18);
        usdg.mint(who, 500_000e6);
        vm.startPrank(who);
        aapl.approve(address(amm), 1_000e18);
        usdg.approve(address(amm), 500_000e6);
        amm.deposit(groupId, address(aapl), 1_000e18);
        amm.deposit(groupId, address(usdg), 500_000e6);
        vm.stopPrank();
    }

    /// @dev USD (6-dec) per share -> USDG atoms per AAPL atom in Q128.
    function _pxX128(uint256 usdE6) internal pure returns (uint256) {
        return (usdE6 << 128) / 1e18;
    }

    /// @dev What the Alpaca daemon builds each tick: bid/ask = mid -/+ 10 bps,
    ///      short freshness, decay to expiry within seconds.
    function _alpacaQuote(uint64 nonce, uint256 midUsdE6)
        internal
        view
        returns (QuayTypes.QuoteState memory q)
    {
        q = QuayTypes.QuoteState({
            nonce: nonce,
            updatedAt: 0,
            freshUntil: uint64(block.timestamp) + 2,
            validUntil: uint64(block.timestamp) + 10,
            decayBpsPerSecond: 25,
            maxDecayBps: 100,
            bidPxX128: _pxX128(midUsdE6 - midUsdE6 / 1000),
            askPxX128: _pxX128(midUsdE6 + midUsdE6 / 1000),
            maxIn0: 100e18, // max 100 shares in
            maxIn1: 50_000e6, // max 50k USDG in
            sourceHash: keccak256(abi.encode("alpaca-tick", nonce))
        });
    }

    function _sign(bytes32 bookId, QuayTypes.QuoteState memory q, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, amm.hashQuoteUpdate(bookId, q));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // The simple stock market, end to end
    // ------------------------------------------------------------------

    function test_TradeAtAlpacaPrice() public {
        // Tick: Alpaca says $190.00; daemon posts 189.81 / 190.19.
        vm.prank(updaterA);
        amm.updateQuote(bookA, _alpacaQuote(1, 190e6));

        // Taker buys ~10 shares with USDG at the ask.
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(bookA, address(usdg), 1_901_900_000); // 1,901.90 USDG
        assertTrue(q.valid);
        assertApproxEqRel(q.amountOut, 10e18, 1e12); // ~10 AAPL at 190.19

        MockERC20(address(usdg)).mint(taker, 1_901_900_000);
        vm.startPrank(taker);
        usdg.approve(address(amm), 1_901_900_000);
        uint256 out = amm.swapExactInputSingle(
            QuaySharedLiquidityAMM.SwapExactInputSingleParams({
                bookId: bookA,
                tokenIn: address(usdg),
                tokenOut: address(aapl),
                amountIn: 1_901_900_000,
                minAmountOut: q.amountOut,
                recipient: taker,
                deadline: uint64(block.timestamp) + 30,
                expectedQuoteNonce: q.quoteNonce,
                expectedInventoryNonceOut: 0
            })
        );
        vm.stopPrank();
        assertEq(out, q.amountOut);
        assertEq(aapl.balanceOf(taker), out);

        // And sells them back at the bid.
        vm.startPrank(taker);
        aapl.approve(address(amm), out);
        uint256 usdgBack = amm.swapExactInputSingle(
            QuaySharedLiquidityAMM.SwapExactInputSingleParams({
                bookId: bookA,
                tokenIn: address(aapl),
                tokenOut: address(usdg),
                amountIn: out,
                minAmountOut: 0,
                recipient: taker,
                deadline: uint64(block.timestamp) + 30,
                expectedQuoteNonce: 0,
                expectedInventoryNonceOut: 0
            })
        );
        vm.stopPrank();
        // Round trip pays the 20 bps posted spread, nothing else (fee 0).
        assertApproxEqRel(usdgBack, (uint256(1_901_900_000) * 9980) / 10_000, 1e14);
    }

    function test_OffMarketQuoteIsBlockedByTheGuard() public {
        // Daemon glitch: posts $250 while the reference says $190. The quote
        // pipeline is formally valid, but the executed price is 30% off the
        // feed -> guard rejects, takers cannot be filled off-market.
        vm.prank(updaterA);
        amm.updateQuote(bookA, _alpacaQuote(1, 250e6));

        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(bookA, address(usdg), 1_000e6);
        assertFalse(q.valid);
        assertEq(uint8(q.reason), uint8(QuayTypes.QuoteReason.OracleDeviation));
    }

    function test_MarketCloseDecayThenExpiry() public {
        vm.prank(updaterA);
        amm.updateQuote(bookA, _alpacaQuote(1, 190e6));
        uint256 freshOut = amm.quoteExactInput(bookA, address(aapl), 1e18).amountOut;

        // 16:00 — the daemon stops updating. Price decays against the taker...
        vm.warp(START + 6); // 4s past freshUntil -> 100 bps (capped)
        uint256 decayedOut = amm.quoteExactInput(bookA, address(aapl), 1e18).amountOut;
        assertLt(decayedOut, freshOut);

        // ...then the book goes dark entirely. No update -> no trade.
        vm.warp(START + 11);
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(bookA, address(aapl), 1e18);
        assertEq(uint8(q.reason), uint8(QuayTypes.QuoteReason.QuoteExpired));
    }

    // ------------------------------------------------------------------
    // Shared cranker: many makers, one submitting account
    // ------------------------------------------------------------------

    function test_SharedCrankerLandsManyMakersInOneTx() public {
        // Each maker's daemon signs its own quote with its own updater key;
        // a shared, untrusted cranker submits both in a single transaction.
        QuayTypes.QuoteState memory qA = _alpacaQuote(1, 190e6);
        QuayTypes.QuoteState memory qB = _alpacaQuote(1, 190_050_000); // B quotes $190.05

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bookA;
        ids[1] = bookB;
        QuayTypes.QuoteState[] memory quotes = new QuayTypes.QuoteState[](2);
        quotes[0] = qA;
        quotes[1] = qB;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(bookA, qA, updaterAKey);
        sigs[1] = _sign(bookB, qB, updaterBKey);

        vm.prank(cranker);
        bool[] memory applied = amm.tryBatchUpdateQuotesWithSig(ids, quotes, sigs);
        assertTrue(applied[0]);
        assertTrue(applied[1]);
        assertEq(amm.getQuoteState(bookA).nonce, 1);
        assertEq(amm.getQuoteState(bookB).nonce, 1);

        // Cross-maker key confusion is impossible: A's key cannot quote B.
        QuayTypes.QuoteState memory qB2 = _alpacaQuote(2, 191e6);
        sigs[1] = _sign(bookB, qB2, updaterAKey); // wrong maker's key
        quotes[0] = _alpacaQuote(2, 190_100_000);
        quotes[1] = qB2;
        sigs[0] = _sign(bookA, quotes[0], updaterAKey);

        vm.prank(cranker);
        applied = amm.tryBatchUpdateQuotesWithSig(ids, quotes, sigs);
        assertTrue(applied[0]);
        assertFalse(applied[1]);
        assertEq(amm.getQuoteState(bookB).nonce, 1); // B untouched
    }

    function test_LenientBatchSkipsOneMakersBadQuote() public {
        vm.prank(updaterB);
        amm.updateQuote(bookB, _alpacaQuote(5, 190e6)); // B is already at nonce 5

        // A is fresh; B's daemon lags and re-signs a stale nonce.
        QuayTypes.QuoteState memory qA = _alpacaQuote(1, 190e6);
        QuayTypes.QuoteState memory qBStale = _alpacaQuote(5, 190e6);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bookA;
        ids[1] = bookB;
        QuayTypes.QuoteState[] memory quotes = new QuayTypes.QuoteState[](2);
        quotes[0] = qA;
        quotes[1] = qBStale;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(bookA, qA, updaterAKey);
        sigs[1] = _sign(bookB, qBStale, updaterBKey);

        // The atomic batch would punish maker A for maker B's lag...
        vm.prank(cranker);
        vm.expectRevert(QuaySharedLiquidityAMM.StaleQuoteNonce.selector);
        amm.batchUpdateQuotesWithSig(ids, quotes, sigs);

        // ...the lenient batch lands A and skips B, with an event trail.
        vm.expectEmit(true, false, false, true, address(amm));
        emit QuaySharedLiquidityAMM.QuoteUpdateSkipped(bookB, 1);
        vm.prank(cranker);
        bool[] memory applied = amm.tryBatchUpdateQuotesWithSig(ids, quotes, sigs);
        assertTrue(applied[0]);
        assertFalse(applied[1]);
        assertEq(amm.getQuoteState(bookA).nonce, 1);
        assertEq(amm.getQuoteState(bookB).nonce, 5);
    }
}
