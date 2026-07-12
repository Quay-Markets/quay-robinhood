/** Mirrors QuayTypes.QuoteReason — enum order must match the contract. */
export const QuoteReason = {
  OK: 0,
  BookMissing: 1,
  BookNotActive: 2,
  GroupMissing: 3,
  GroupPaused: 4,
  WrongToken: 5,
  AmountZero: 6,
  QuoteMissing: 7,
  QuoteExpired: 8,
  BadPrices: 9,
  SizeExceeded: 10,
  ZeroOutput: 11,
  InsufficientLiquidity: 12,
  ProtocolPaused: 13,
  OracleInvalid: 14,
  OracleStale: 15,
  OracleDeviation: 16,
  StrategyNotApproved: 17,
  StrategyError: 18,
} as const;
export type QuoteReasonCode = (typeof QuoteReason)[keyof typeof QuoteReason];

/** Mirrors QuayTypes.QuoteState. */
export interface QuoteState {
  nonce: bigint;
  updatedAt: bigint;
  freshUntil: bigint;
  validUntil: bigint;
  decayBpsPerSecond: bigint;
  maxDecayBps: bigint;
  bidPxX128: bigint;
  askPxX128: bigint;
  maxIn0: bigint;
  maxIn1: bigint;
}

export type BookStatus = 'Uninitialized' | 'Active' | 'Paused' | 'Closed';

/** Per-book oracle guard config plus a caller-fetched feed reading. */
export interface OracleInput {
  maxAge: bigint;
  maxDeviationBps: bigint;
  priceScale: bigint;
  /** latestRoundData answer (int256) and updatedAt, fetched by the caller. */
  answer: bigint;
  feedUpdatedAt: bigint;
}

export type StrategyInput = { kind: 'bbo' };

/** Everything needed to price one book off-chain — see loadBookState. */
export interface QuoteInput {
  /** Trade direction: true when selling token0 for token1. */
  token0In: boolean;
  amountIn: bigint;
  /** block.timestamp the quote is evaluated at. */
  nowSec: bigint;
  protocolFeeBps: bigint;
  quote: QuoteState;
  /** Group inventory of the output token. */
  availableOut: bigint;
  strategy: StrategyInput;
  /** Venue-level flags; default to the healthy state when omitted. */
  bookStatus?: BookStatus;
  protocolPaused?: boolean;
  groupPaused?: boolean;
  strategyApproved?: boolean;
  oracle?: OracleInput;
}

/** Mirrors the fields of QuaySharedLiquidityAMM.QuoteResult the SDK computes. */
export interface QuoteResult {
  valid: boolean;
  reason: QuoteReasonCode;
  amountOut: bigint;
  feeAmount: bigint;
  netAmountIn: bigint;
  appliedPriceX128: bigint;
  appliedDecayBps: bigint;
  availableOut: bigint;
  quoteNonce: bigint;
}
