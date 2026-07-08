// Minimal TypeScript mirror of QuaySharedLiquidityAMM quote math.
// Uses bigint only. This is intentionally dependency-free for hackathon use.

export const Q128 = 1n << 128n;
export const BPS = 10_000n;

export type BookStatus = "Uninitialized" | "Active" | "Paused" | "Closed";

export interface BookState {
  token0: string;
  token1: string;
  liquidityGroupId: string;
  protocolFeeBps: bigint;
  status: BookStatus;
}

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

export interface QuoteInput {
  bookId: string;
  book: BookState;
  quote: QuoteState;
  tokenIn: string;
  amountIn: bigint;
  nowSec: bigint;
  availableOut: bigint;
  inventoryNonceOut: bigint;
  groupPaused: boolean;
}

export interface QuoteResult {
  valid: boolean;
  reason: string;
  bookId: string;
  liquidityGroupId: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: bigint;
  netAmountIn: bigint;
  feeAmount: bigint;
  amountOut: bigint;
  appliedPriceX128: bigint;
  appliedDecayBps: bigint;
  quoteNonce: bigint;
  inventoryNonceOut: bigint;
}

function norm(a: string): string {
  return a.toLowerCase();
}

export function quoteExactInput(i: QuoteInput): QuoteResult {
  const base: QuoteResult = {
    valid: false,
    reason: "Unknown",
    bookId: i.bookId,
    liquidityGroupId: i.book.liquidityGroupId,
    tokenIn: i.tokenIn,
    tokenOut: "0x0000000000000000000000000000000000000000",
    amountIn: i.amountIn,
    netAmountIn: 0n,
    feeAmount: 0n,
    amountOut: 0n,
    appliedPriceX128: 0n,
    appliedDecayBps: 0n,
    quoteNonce: i.quote.nonce,
    inventoryNonceOut: i.inventoryNonceOut,
  };

  if (i.book.status !== "Active") return { ...base, reason: "BookNotActive" };
  if (i.groupPaused) return { ...base, reason: "GroupPaused" };
  if (i.amountIn === 0n) return { ...base, reason: "AmountZero" };
  if (i.quote.nonce === 0n) return { ...base, reason: "QuoteMissing" };
  if (i.nowSec > i.quote.validUntil) return { ...base, reason: "QuoteExpired" };
  if (i.quote.bidPxX128 === 0n || i.quote.askPxX128 < i.quote.bidPxX128) return { ...base, reason: "BadPrices" };

  const token0In = norm(i.tokenIn) === norm(i.book.token0);
  const token1In = norm(i.tokenIn) === norm(i.book.token1);
  if (!token0In && !token1In) return { ...base, reason: "WrongToken" };

  const tokenOut = token0In ? i.book.token1 : i.book.token0;
  const maxIn = token0In ? i.quote.maxIn0 : i.quote.maxIn1;
  if (i.amountIn > maxIn) return { ...base, tokenOut, reason: "SizeExceeded" };

  let decay = 0n;
  if (i.nowSec > i.quote.freshUntil) {
    decay = (i.nowSec - i.quote.freshUntil) * i.quote.decayBpsPerSecond;
    if (decay > i.quote.maxDecayBps) decay = i.quote.maxDecayBps;
  }

  const feeAmount = (i.amountIn * i.book.protocolFeeBps) / BPS;
  const netAmountIn = i.amountIn - feeAmount;

  let appliedPriceX128: bigint;
  let amountOut: bigint;

  if (token0In) {
    appliedPriceX128 = (i.quote.bidPxX128 * (BPS - decay)) / BPS;
    amountOut = (netAmountIn * appliedPriceX128) / Q128;
  } else {
    appliedPriceX128 = (i.quote.askPxX128 * (BPS + decay)) / BPS;
    amountOut = (netAmountIn * Q128) / appliedPriceX128;
  }

  if (amountOut === 0n) return { ...base, tokenOut, reason: "ZeroOutput" };
  if (amountOut > i.availableOut) return { ...base, tokenOut, reason: "InsufficientLiquidity" };

  return {
    ...base,
    valid: true,
    reason: "OK",
    tokenOut,
    netAmountIn,
    feeAmount,
    amountOut,
    appliedPriceX128,
    appliedDecayBps: decay,
  };
}
