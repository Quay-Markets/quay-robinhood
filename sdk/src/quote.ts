import { BPS, Q128, mulDiv } from './math.ts';
import type {
  QuoteInput,
  QuoteReasonCode,
  QuoteResult,
  QuoteState,
} from './types.ts';
import { QuoteReason } from './types.ts';

interface StrategyOutcome {
  amountOut: bigint;
  appliedPriceX128: bigint;
  appliedDecayBps: bigint;
  reason: QuoteReasonCode;
}

const rejected = (reason: QuoteReasonCode): StrategyOutcome => ({
  amountOut: 0n,
  appliedPriceX128: 0n,
  appliedDecayBps: 0n,
  reason,
});

/**
 * Pure mirror of QuaySharedLiquidityAMM.quoteExactInput. Field-retention
 * semantics match the contract exactly: checks that fail before the fee is
 * computed return zeroed fee/net fields; strategy-level rejections keep them.
 */
export function quoteExactInput(i: QuoteInput): QuoteResult {
  const r: QuoteResult = {
    valid: false,
    reason: QuoteReason.OK,
    amountOut: 0n,
    feeAmount: 0n,
    netAmountIn: 0n,
    appliedPriceX128: 0n,
    appliedDecayBps: 0n,
    availableOut: 0n,
    quoteNonce: 0n,
  };
  const invalid = (reason: QuoteReasonCode): QuoteResult => {
    r.valid = false;
    r.reason = reason;
    r.amountOut = 0n;
    return r;
  };

  if (i.protocolPaused === true) return invalid(QuoteReason.ProtocolPaused);
  const status = i.bookStatus ?? 'Active';
  if (status === 'Uninitialized') return invalid(QuoteReason.BookMissing);
  if (status !== 'Active') return invalid(QuoteReason.BookNotActive);
  if (i.groupPaused === true) return invalid(QuoteReason.GroupPaused);
  if (i.amountIn === 0n) return invalid(QuoteReason.AmountZero);

  const q = i.quote;
  if (q.nonce === 0n) return invalid(QuoteReason.QuoteMissing);
  if (i.nowSec > q.validUntil) return invalid(QuoteReason.QuoteExpired);
  if (i.strategyApproved === false) return invalid(QuoteReason.StrategyNotApproved);

  // Oracle guard, part 1: resolve the reference before pricing.
  let refPxX128 = 0n;
  if (i.oracle !== undefined) {
    const [ref, reason] = oracleReference(i.oracle, i.nowSec);
    if (reason !== QuoteReason.OK) return invalid(reason);
    refPxX128 = ref;
  }

  r.quoteNonce = q.nonce;
  r.feeAmount = mulDiv(i.amountIn, i.protocolFeeBps, BPS);
  r.netAmountIn = i.amountIn - r.feeAmount;

  const s = priceWithStrategy(i, r.netAmountIn);
  if (s.reason !== QuoteReason.OK) return invalid(s.reason);
  r.amountOut = s.amountOut;
  r.appliedPriceX128 = s.appliedPriceX128;
  r.appliedDecayBps = s.appliedDecayBps;

  if (r.amountOut === 0n) return invalid(QuoteReason.ZeroOutput);

  // Oracle guard, part 2: bound the EFFECTIVE executed price (covers decay
  // and strategy skew), derived from actual net input and output.
  if (refPxX128 !== 0n && i.oracle !== undefined) {
    const effectivePxX128 = i.token0In
      ? mulDiv(r.amountOut, Q128, r.netAmountIn)
      : mulDiv(r.netAmountIn, Q128, r.amountOut);
    const minPx = mulDiv(refPxX128, BPS - i.oracle.maxDeviationBps, BPS);
    const maxPx = mulDiv(refPxX128, BPS + i.oracle.maxDeviationBps, BPS);
    if (effectivePxX128 < minPx || effectivePxX128 > maxPx) {
      return invalid(QuoteReason.OracleDeviation);
    }
  }

  r.availableOut = i.availableOut;
  if (r.amountOut > i.availableOut) return invalid(QuoteReason.InsufficientLiquidity);

  r.valid = true;
  r.reason = QuoteReason.OK;
  return r;
}

function priceWithStrategy(i: QuoteInput, netAmountIn: bigint): StrategyOutcome {
  return bboQuote(i.quote, i.token0In, i.amountIn, netAmountIn, i.nowSec);
}

function oracleReference(
  o: NonNullable<QuoteInput['oracle']>,
  now: bigint,
): [bigint, QuoteReasonCode] {
  if (o.answer <= 0n) return [0n, QuoteReason.OracleInvalid];
  if (o.feedUpdatedAt === 0n || o.feedUpdatedAt > now) return [0n, QuoteReason.OracleInvalid];
  if (now - o.feedUpdatedAt > o.maxAge) return [0n, QuoteReason.OracleStale];
  const refPxX128 = o.answer * o.priceScale;
  if (refPxX128 === 0n) return [0n, QuoteReason.OracleInvalid];
  return [refPxX128, QuoteReason.OK];
}

/** Mirrors src/strategies/BBOStrategy.sol. */
export function bboQuote(
  q: QuoteState,
  token0In: boolean,
  amountIn: bigint,
  netAmountIn: bigint,
  now: bigint,
): StrategyOutcome {
  if (q.bidPxX128 === 0n || q.askPxX128 < q.bidPxX128) return rejected(QuoteReason.BadPrices);
  if (token0In && amountIn > q.maxIn0) return rejected(QuoteReason.SizeExceeded);
  if (!token0In && amountIn > q.maxIn1) return rejected(QuoteReason.SizeExceeded);

  let decay = 0n;
  if (now > q.freshUntil) {
    decay = (now - q.freshUntil) * q.decayBpsPerSecond;
    if (decay > q.maxDecayBps) decay = q.maxDecayBps;
  }

  let appliedPriceX128: bigint;
  let amountOut: bigint;
  if (token0In) {
    appliedPriceX128 = mulDiv(q.bidPxX128, BPS - decay, BPS);
    amountOut = mulDiv(netAmountIn, appliedPriceX128, Q128);
  } else {
    appliedPriceX128 = mulDiv(q.askPxX128, BPS + decay, BPS);
    amountOut = mulDiv(netAmountIn, Q128, appliedPriceX128);
  }
  if (amountOut === 0n) {
    return { amountOut: 0n, appliedPriceX128, appliedDecayBps: decay, reason: QuoteReason.ZeroOutput };
  }
  return { amountOut, appliedPriceX128, appliedDecayBps: decay, reason: QuoteReason.OK };
}

