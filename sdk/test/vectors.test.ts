import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { quoteExactInput } from '../src/quote.ts';
import type { QuoteInput, StrategyInput } from '../src/types.ts';

/**
 * Parity contract: every vector in sdk/test-vectors.json was produced by the
 * Solidity venue (test/SdkVectors.t.sol). The SDK must reproduce every output
 * field exactly. Regenerate vectors with `forge test --match-contract
 * SdkVectorsTest` after contract changes.
 */

interface RawVector {
  name: string;
  kind: 'bbo';
  token0In: boolean;
  amountIn: string;
  nowSec: string;
  protocolFeeBps: string;
  availableOut: string;
  quote: Record<string, string>;
  config: Record<string, unknown>;
  expected: {
    valid: boolean;
    reason: string;
    amountOut: string;
    feeAmount: string;
    netAmountIn: string;
    appliedPriceX128: string;
    appliedDecayBps: string;
  };
}

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'test-vectors.json'), 'utf8')) as RawVector[];

function big(v: unknown, field: string): bigint {
  if (typeof v !== 'string') throw new Error(`missing field ${field}`);
  return BigInt(v);
}

function strategyInput(_v: RawVector): StrategyInput {
  return { kind: 'bbo' };
}

describe('SDK quote math matches Solidity bit-for-bit', () => {
  expect(vectors.length).toBeGreaterThan(8);

  for (const v of vectors) {
    it(v.name, () => {
      const input: QuoteInput = {
        token0In: v.token0In,
        amountIn: BigInt(v.amountIn),
        nowSec: BigInt(v.nowSec),
        protocolFeeBps: BigInt(v.protocolFeeBps),
        availableOut: BigInt(v.availableOut),
        quote: {
          nonce: big(v.quote['nonce'], 'nonce'),
          updatedAt: big(v.quote['updatedAt'], 'updatedAt'),
          freshUntil: big(v.quote['freshUntil'], 'freshUntil'),
          validUntil: big(v.quote['validUntil'], 'validUntil'),
          decayBpsPerSecond: big(v.quote['decayBpsPerSecond'], 'decayBpsPerSecond'),
          maxDecayBps: big(v.quote['maxDecayBps'], 'maxDecayBps'),
          bidPxX128: big(v.quote['bidPxX128'], 'bidPxX128'),
          askPxX128: big(v.quote['askPxX128'], 'askPxX128'),
          maxIn0: big(v.quote['maxIn0'], 'maxIn0'),
          maxIn1: big(v.quote['maxIn1'], 'maxIn1'),
        },
        strategy: strategyInput(v),
      };

      const r = quoteExactInput(input);
      expect(r.valid, 'valid').toBe(v.expected.valid);
      expect(r.reason, 'reason').toBe(Number(v.expected.reason));
      expect(r.amountOut, 'amountOut').toBe(BigInt(v.expected.amountOut));
      expect(r.feeAmount, 'feeAmount').toBe(BigInt(v.expected.feeAmount));
      expect(r.netAmountIn, 'netAmountIn').toBe(BigInt(v.expected.netAmountIn));
      expect(r.appliedPriceX128, 'appliedPriceX128').toBe(BigInt(v.expected.appliedPriceX128));
      expect(r.appliedDecayBps, 'appliedDecayBps').toBe(BigInt(v.expected.appliedDecayBps));
    });
  }
});
