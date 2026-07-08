// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTypes} from "src/QuayTypes.sol";

/// @notice Pluggable pricing module for a Quay book.
///
/// Contract with the venue core:
///   - Called via staticcall with a bounded gas stipend; must not write state.
///   - Receives the raw maker-posted QuoteState and interprets its fields.
///   - Venue-level checks (book/group status, pause, quote expiry, oracle
///     guard, protocol fee, inventory) stay in the core. The module only
///     turns (quote params, direction, net input) into an output amount.
///   - Must be deterministic in on-chain state; may read block.timestamp for
///     freshness decay but nothing sender- or gas-dependent.
///   - Return reason != OK (with amountOut = 0) for module-level rejections
///     such as size caps or unusable price params; do not revert for those.
interface IQuayStrategy {
    /// @param bookId venue book being quoted; modules holding per-book curve
    ///        configuration key it by this id
    /// @param q maker-posted quote parameters for the book
    /// @param token0In true when the taker sells token0 for token1
    /// @param amountIn gross taker input (before the venue's protocol fee)
    /// @param netAmountIn input actually priced (after the protocol fee)
    /// @param availableOut group inventory of the output token, read-only;
    ///        lets modules skew pricing as inventory drains. The core still
    ///        enforces amountOut <= availableOut regardless.
    /// @return amountOut output amount; 0 unless reason == OK
    /// @return appliedPriceX128 effective price used, Q128, for diagnostics
    /// @return appliedDecayBps decay applied to the posted price, for diagnostics
    /// @return reason OK or a module-level rejection reason
    function quoteExactInput(
        bytes32 bookId,
        QuayTypes.QuoteState calldata q,
        bool token0In,
        uint256 amountIn,
        uint256 netAmountIn,
        uint256 availableOut
    )
        external
        view
        returns (
            uint256 amountOut,
            uint256 appliedPriceX128,
            uint32 appliedDecayBps,
            QuayTypes.QuoteReason reason
        );
}
