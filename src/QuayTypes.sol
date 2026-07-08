// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Types shared between the venue core and pluggable strategy modules.
abstract contract QuayTypes {
    uint256 public constant Q128 = 1 << 128;
    uint16 public constant BPS = 10_000;
    uint32 public constant MAX_DECAY_BPS = 9999;

    enum QuoteReason {
        OK,
        BookMissing,
        BookNotActive,
        GroupMissing,
        GroupPaused,
        WrongToken,
        AmountZero,
        QuoteMissing,
        QuoteExpired,
        BadPrices,
        SizeExceeded,
        ZeroOutput,
        InsufficientLiquidity,
        ProtocolPaused,
        OracleInvalid,
        OracleStale,
        OracleDeviation,
        StrategyNotApproved,
        StrategyError
    }

    /// @notice Maker-posted quote parameters. The venue enforces nonce
    ///         monotonicity and validUntil expiry; the meaning of the price,
    ///         size, and decay fields is defined by the book's strategy module.
    struct QuoteState {
        uint64 nonce;
        uint64 updatedAt;
        uint64 freshUntil;
        uint64 validUntil;
        uint32 decayBpsPerSecond;
        uint32 maxDecayBps;
        uint256 bidPxX128;
        uint256 askPxX128;
        uint128 maxIn0;
        uint128 maxIn1;
        bytes32 sourceHash;
    }
}
