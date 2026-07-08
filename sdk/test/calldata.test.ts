import { describe, expect, it } from 'vitest';
import { encodeSwapExactInputSingle, encodeUpdateQuote, quoteUpdateTypedData } from '../src/calldata.ts';

/**
 * Reference calldata produced by Foundry:
 *   cast calldata "swapExactInputSingle((bytes32,address,address,uint256,uint256,address,uint64,uint64,uint64))" ...
 *   cast calldata "updateQuote(bytes32,(uint64,...,bytes32))" ...
 */

describe('calldata builders match cast', () => {
  it('encodeSwapExactInputSingle', () => {
    const encoded = encodeSwapExactInputSingle({
      bookId: '0x1111111111111111111111111111111111111111111111111111111111111111',
      tokenIn: '0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa',
      tokenOut: '0xBbbBBBbbBBBbbbBbbBbbBBbBbbBbBbbBbBBBBbBB',
      amountIn: 123456789000000000000n,
      minAmountOut: 987654321n,
      recipient: '0xcCcCCCcCCCCcCCCCcCcccCcCCCcCcCCCCCcCcCcC',
      deadline: 1700000060n,
      expectedQuoteNonce: 7n,
      expectedInventoryNonceOut: 42n,
    });
    expect(encoded).toBe(
      '0x98df30761111111111111111111111111111111111111111111111111111111111111111000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb000000000000000000000000000000000000000000000006b14e9f7e4f5a5000000000000000000000000000000000000000000000000000000000003ade68b1000000000000000000000000cccccccccccccccccccccccccccccccccccccccc000000000000000000000000000000000000000000000000000000006553f13c0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000002a',
    );
  });

  it('encodeUpdateQuote', () => {
    const encoded = encodeUpdateQuote(
      '0x2222222222222222222222222222222222222222222222222222222222222222',
      {
        nonce: 5n,
        updatedAt: 0n,
        freshUntil: 1700000002n,
        validUntil: 1700000010n,
        decayBpsPerSecond: 100n,
        maxDecayBps: 500n,
        bidPxX128: 34028236692093846346337460743176821145600n,
        askPxX128: 68056473384187692692674921486353642291200n,
        maxIn0: 1000000000000000000000n,
        maxIn1: 300000000000n,
        sourceHash: '0x3333333333333333333333333333333333333333333333333333333333333333',
      },
    );
    expect(encoded).toBe(
      '0x6f732027222222222222222222222222222222222222222222222222222222222222222200000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006553f102000000000000000000000000000000000000000000000000000000006553f10a000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000001f40000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000c80000000000000000000000000000000000000000000000000000000000000000000000000000003635c9adc5dea0000000000000000000000000000000000000000000000000000000000045d964b8003333333333333333333333333333333333333333333333333333333333333333',
    );
  });

  it('quoteUpdateTypedData mirrors the pinned EIP-712 schema', () => {
    const td = quoteUpdateTypedData({
      chainId: 4663,
      verifyingContract: '0x00000000000000000000000000000000000000AA',
      bookId: '0x1111111111111111111111111111111111111111111111111111111111111111',
      quote: {
        nonce: 5n,
        freshUntil: 1700000002n,
        validUntil: 1700000010n,
        decayBpsPerSecond: 100n,
        maxDecayBps: 500n,
        bidPxX128: 1n,
        askPxX128: 2n,
        maxIn0: 3n,
        maxIn1: 4n,
        sourceHash: '0x3333333333333333333333333333333333333333333333333333333333333333',
      },
    });
    // Field names/order must match QUOTE_UPDATE_TYPEHASH in the contract
    // (pinned on-chain by test_DigestMatchesManualEip712Computation).
    expect(td.domain.name).toBe('QuaySharedLiquidityAMM');
    expect(td.domain.version).toBe('1');
    expect(td.types.QuoteUpdate.map((f) => `${f.type} ${f.name}`).join(',')).toBe(
      'bytes32 bookId,uint64 nonce,uint64 freshUntil,uint64 validUntil,uint32 decayBpsPerSecond,uint32 maxDecayBps,uint256 bidPxX128,uint256 askPxX128,uint128 maxIn0,uint128 maxIn1,bytes32 sourceHash',
    );
  });
});
