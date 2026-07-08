// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTypes} from "src/QuayTypes.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @notice Base for strategy modules that keep per-book curve configuration.
///
/// Split of responsibilities mirroring the Solana prop-AMMs being ported:
///   - Fast-moving state (mid price, size caps, freshness timestamps) flows
///     through the venue's updateQuote pipeline: nonced, evented, relayable.
///   - Slow-moving curve shape (spread ladders, splines, divisors) lives here,
///     keyed by bookId and settable only by the book's maker (its liquidity
///     group owner) or the venue owner. Config changes emit events so
///     aggregator SDKs can track them.
///
/// Configuration functions make external calls to the venue for access
/// control; quote-time code paths must stay free of external calls so quoting
/// stays deterministic under the venue's gas-capped staticcall.
abstract contract ConfigurableStrategy is QuayTypes {
    QuaySharedLiquidityAMM public immutable venue;

    error NotBookOwner();
    error BadConfig();

    constructor(QuaySharedLiquidityAMM venue_) {
        venue = venue_;
    }

    modifier onlyBookOwner(bytes32 bookId) {
        bytes32 groupId = venue.getBook(bookId).liquidityGroupId;
        // Only the owner field matters here; exists/paused gate quoting in the
        // venue, not configuration.
        // slither-disable-next-line unused-return
        (address groupOwner,,,) = venue.liquidityGroups(groupId);
        if (groupOwner == address(0)) revert NotBookOwner();
        if (msg.sender != groupOwner && msg.sender != venue.owner()) revert NotBookOwner();
        _;
    }
}
