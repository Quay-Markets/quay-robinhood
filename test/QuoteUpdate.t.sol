// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";

contract QuoteUpdateTest is QuayTestBase {
    function test_UpdateQuote_StoresStateAndEmits() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.updatedAt = 123; // must be ignored and replaced by block.timestamp

        vm.expectEmit(true, true, false, true, address(amm));
        emit QuaySharedLiquidityAMM.QuoteUpdated(
            wethBook,
            updater,
            2,
            uint64(block.timestamp),
            q.freshUntil,
            q.validUntil,
            q.bidPxX128,
            q.askPxX128,
            q.maxIn0,
            q.maxIn1,
            q.sourceHash
        );
        vm.prank(updater);
        amm.updateQuote(wethBook, q);

        QuayTypes.QuoteState memory s = amm.getQuoteState(wethBook);
        assertEq(s.nonce, 2);
        assertEq(s.updatedAt, uint64(block.timestamp));
        assertEq(s.freshUntil, q.freshUntil);
        assertEq(s.validUntil, q.validUntil);
        assertEq(s.decayBpsPerSecond, q.decayBpsPerSecond);
        assertEq(s.maxDecayBps, q.maxDecayBps);
        assertEq(s.bidPxX128, q.bidPxX128);
        assertEq(s.askPxX128, q.askPxX128);
        assertEq(s.maxIn0, q.maxIn0);
        assertEq(s.maxIn1, q.maxIn1);
        assertEq(s.sourceHash, q.sourceHash);
    }

    function test_UpdateQuote_RevertNotUpdater() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuote(wethBook, _wethQuote(2));
    }

    function test_UpdateQuote_RevertUnknownBook() public {
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuote(bytes32("nope"), _wethQuote(2));
    }

    function test_UpdateQuote_RevertDeactivatedUpdater() public {
        vm.prank(maker);
        amm.setUpdater(wethBook, updater, false);
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuote(wethBook, _wethQuote(2));
    }

    function test_UpdateQuote_RevertZeroBid() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.bidPxX128 = 0;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_RevertAskBelowBid() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.askPxX128 = q.bidPxX128 - 1;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_ZeroSpreadAllowed() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.askPxX128 = q.bidPxX128;
        vm.prank(updater);
        amm.updateQuote(wethBook, q);
        assertEq(amm.getQuoteState(wethBook).askPxX128, q.bidPxX128);
    }

    function test_UpdateQuote_RevertFreshAfterValid() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.freshUntil = q.validUntil + 1;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_RevertAlreadyExpired() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.freshUntil = uint64(block.timestamp) - 5;
        q.validUntil = uint64(block.timestamp) - 1;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_ValidUntilNowAllowed() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.freshUntil = uint64(block.timestamp);
        q.validUntil = uint64(block.timestamp);
        vm.prank(updater);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_RevertDecayCapTooHigh() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.maxDecayBps = 10_000;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_RevertStaleNonce() public {
        vm.startPrank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.StaleQuoteNonce.selector);
        amm.updateQuote(wethBook, _wethQuote(1)); // equal to current
        vm.expectRevert(QuaySharedLiquidityAMM.StaleQuoteNonce.selector);
        amm.updateQuote(wethBook, _wethQuote(0)); // below current
        vm.stopPrank();
    }

    function test_UpdateQuote_NonceStrictlyIncreases() public {
        vm.startPrank(updater);
        amm.updateQuote(wethBook, _wethQuote(2));
        amm.updateQuote(wethBook, _wethQuote(10)); // gaps allowed
        vm.stopPrank();
        assertEq(amm.getQuoteState(wethBook).nonce, 10);
    }

    function test_UpdateQuote_RevertZeroMaxIn() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.maxIn0 = 0;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);

        q = _wethQuote(2);
        q.maxIn1 = 0;
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuote(wethBook, q);
    }

    function test_UpdateQuote_AllowedWhileBookPaused() public {
        // Makers may keep streaming quotes while paused; quoting stays invalid
        // until the book is re-activated.
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
        vm.prank(updater);
        amm.updateQuote(wethBook, _wethQuote(2));
        assertEq(amm.getQuoteState(wethBook).nonce, 2);
    }

    function test_UpdateQuote_RevertClosedBook() public {
        // Closed is terminal: no further quote events on the book.
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Closed);
        vm.prank(updater);
        vm.expectRevert(QuaySharedLiquidityAMM.BookClosed.selector);
        amm.updateQuote(wethBook, _wethQuote(2));
    }
}
