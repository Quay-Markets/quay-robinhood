import { BPS, PPB, PPM, PRECISION_1E7, Q128, SPREAD_DENOM, isqrt, mulDiv } from './math.ts';
import type {
  BisonFiConfig,
  HumidiFiConfig,
  QuoteInput,
  QuoteReasonCode,
  QuoteResult,
  QuoteState,
  SolFiConfig,
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
  switch (i.strategy.kind) {
    case 'bbo':
      return bboQuote(i.quote, i.token0In, i.amountIn, netAmountIn, i.nowSec);
    case 'solfi':
      return solfiQuote(i.strategy.config, i.quote, i.token0In, i.amountIn, netAmountIn, i.nowSec);
    case 'humidifi':
      return humidifiQuote(i.strategy.config, i.quote, i.token0In, i.amountIn, netAmountIn);
    case 'bisonfi':
      return bisonfiQuote(
        i.strategy.config,
        i.quote,
        i.token0In,
        i.amountIn,
        netAmountIn,
        i.nowSec,
        i.availableOut,
      );
  }
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

/** Mirrors src/strategies/SolFiStrategy.sol (slot-decay linear-C model). */
export function solfiQuote(
  c: SolFiConfig,
  q: QuoteState,
  token0In: boolean,
  amountIn: bigint,
  netAmountIn: bigint,
  now: bigint,
): StrategyOutcome {
  const delta = now - q.updatedAt;
  if (delta >= c.maxAgeSeconds) return rejected(QuoteReason.QuoteExpired);
  if (token0In && amountIn > q.maxIn0) return rejected(QuoteReason.SizeExceeded);
  if (!token0In && amountIn > q.maxIn1) return rejected(QuoteReason.SizeExceeded);
  if (netAmountIn === 0n || q.bidPxX128 === 0n) return rejected(QuoteReason.ZeroOutput);

  const clipped = delta > c.rampSeconds ? c.rampSeconds : delta;
  const interp = (fresh: bigint, stale: bigint): bigint =>
    (fresh * (c.rampSeconds - clipped) + stale * clipped) / c.rampSeconds;
  const feeFactor = PRECISION_1E7 - c.feePpm7;

  const amountOut = token0In
    ? mulDiv(netAmountIn * feeFactor, q.bidPxX128, Q128 * interp(c.c0Fresh, c.c0Stale))
    : mulDiv(
        netAmountIn * feeFactor,
        interp(c.c1Fresh, c.c1Stale) * Q128,
        q.bidPxX128 * PRECISION_1E7 * PRECISION_1E7,
      );
  if (amountOut === 0n) return rejected(QuoteReason.ZeroOutput);

  const appliedPriceX128 = token0In
    ? mulDiv(amountOut, Q128, netAmountIn)
    : mulDiv(netAmountIn, Q128, amountOut);
  const appliedDecayBps = (clipped * 10_000n) / c.rampSeconds;
  return { amountOut, appliedPriceX128, appliedDecayBps, reason: QuoteReason.OK };
}

/** Mirrors src/strategies/HumidiFiStrategy.sol. */
export function humidifiQuote(
  c: HumidiFiConfig,
  q: QuoteState,
  token0In: boolean,
  amountIn: bigint,
  netAmountIn: bigint,
): StrategyOutcome {
  if (c.circuitBreaker >= 100n) return rejected(QuoteReason.BookNotActive);
  if (token0In && amountIn > q.maxIn0) return rejected(QuoteReason.SizeExceeded);
  if (!token0In && amountIn > q.maxIn1) return rejected(QuoteReason.SizeExceeded);
  if (netAmountIn === 0n) return rejected(QuoteReason.ZeroOutput);

  const mid = q.bidPxX128;
  if (mid === 0n) return rejected(QuoteReason.BadPrices);
  const outPerfect = token0In ? mulDiv(netAmountIn, mid, Q128) : mulDiv(netAmountIn, Q128, mid);
  if (outPerfect === 0n) return rejected(QuoteReason.ZeroOutput);

  let spread = c.baseSpread;
  if (c.sqrtDiv !== 0n) spread += isqrt(outPerfect / c.sqrtDiv);
  if (c.linDiv !== 0n) spread += outPerfect / c.linDiv;
  if (c.kickThreshold !== 0n && netAmountIn >= c.kickThreshold) spread += c.kickSpread;
  if (spread > c.maxSpread) spread = c.maxSpread;

  const factor = SPREAD_DENOM - spread;
  const amountOut = token0In
    ? mulDiv(netAmountIn * factor, mid, Q128 * SPREAD_DENOM)
    : mulDiv(netAmountIn * factor, Q128, mid * SPREAD_DENOM);
  if (amountOut === 0n) return rejected(QuoteReason.ZeroOutput);

  const appliedPriceX128 = token0In
    ? mulDiv(mid, factor, SPREAD_DENOM)
    : mulDiv(mid, SPREAD_DENOM, factor);
  return { amountOut, appliedPriceX128, appliedDecayBps: spread / 10_000n, reason: QuoteReason.OK };
}

/** Mirrors src/strategies/BisonFiStrategy.sol (June re-RE model). */
export function bisonfiQuote(
  c: BisonFiConfig,
  q: QuoteState,
  token0In: boolean,
  amountIn: bigint,
  netAmountIn: bigint,
  now: bigint,
  availableOut: bigint,
): StrategyOutcome {
  const age = now - q.updatedAt;
  if (age >= c.maxAgeSeconds) return rejected(QuoteReason.QuoteExpired);
  if (token0In && amountIn > q.maxIn0) return rejected(QuoteReason.SizeExceeded);
  if (!token0In && amountIn > q.maxIn1) return rejected(QuoteReason.SizeExceeded);
  if (netAmountIn === 0n || q.bidPxX128 === 0n) return rejected(QuoteReason.ZeroOutput);

  const mid = q.bidPxX128;
  const outPerfect = token0In ? mulDiv(netAmountIn, mid, Q128) : mulDiv(netAmountIn, Q128, mid);
  if (outPerfect === 0n) return rejected(QuoteReason.ZeroOutput);

  const depth = availableOut > 1n ? availableOut : 1n;
  const ratioPpm = mulDiv(outPerfect, PPM, depth);
  if (c.maxRatioPpm !== 0n && ratioPpm > c.maxRatioPpm) {
    return rejected(QuoteReason.InsufficientLiquidity);
  }

  const basePick = c.floorValue !== 0n ? c.floorValue : c.defaultPick;
  const pick = age >= 1n && c.field > basePick ? c.field : basePick;
  const constantPpb = ((pick + age * c.basePerSecond) * 100_000n) / 256n;

  let ladderPpm = 0n;
  for (const t of c.ladder) {
    if (ratioPpm < t.thresholdRatioPpm) break; // sorted ascending
    ladderPpm += (t.slopePpm * (ratioPpm - t.thresholdRatioPpm)) / PPM + t.offsetPpm;
  }

  const totalPpb = constantPpb + ladderPpm * 1000n;
  const factor = PPB - totalPpb;
  if (factor <= 0n) return rejected(QuoteReason.InsufficientLiquidity);

  const amountOut = token0In
    ? mulDiv(netAmountIn * factor, mid, Q128 * PPB)
    : mulDiv(netAmountIn * factor, Q128, mid * PPB);
  if (amountOut === 0n) return rejected(QuoteReason.ZeroOutput);

  const appliedPriceX128 = token0In ? mulDiv(mid, factor, PPB) : mulDiv(mid, PPB, factor);
  let freshnessBps = ((age * c.basePerSecond * 100_000n) / 256n) / 100_000n;
  const u32Max = 4_294_967_295n;
  if (freshnessBps > u32Max) freshnessBps = u32Max;
  return { amountOut, appliedPriceX128, appliedDecayBps: freshnessBps, reason: QuoteReason.OK };
}
