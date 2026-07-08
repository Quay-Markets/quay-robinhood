/**
 * Zero-dependency calldata builders for the router path. Both functions
 * encode only static types, so manual ABI encoding is exact by construction.
 * For everything else (views, signed updates), use the full ABI export with
 * viem/ethers.
 */

export interface SwapExactInputSingleParams {
  bookId: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  minAmountOut: bigint;
  recipient: `0x${string}`;
  deadline: bigint;
  /** 0 disables the check. */
  expectedQuoteNonce: bigint;
  /** 0 disables the check; recommended when books share a liquidity group. */
  expectedInventoryNonceOut: bigint;
}

/** cast sig "swapExactInputSingle((bytes32,address,address,uint256,uint256,address,uint64,uint64,uint64))" */
const SWAP_SELECTOR = '98df3076';

function word(value: bigint, label: string): string {
  if (value < 0n || value >= 1n << 256n) throw new Error(`${label} out of uint256 range`);
  return value.toString(16).padStart(64, '0');
}

function addressWord(value: string, label: string): string {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`${label} is not an address: ${value}`);
  return value.slice(2).toLowerCase().padStart(64, '0');
}

function bytes32Word(value: string, label: string): string {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error(`${label} is not bytes32: ${value}`);
  return value.slice(2).toLowerCase();
}

/** Calldata for QuaySharedLiquidityAMM.swapExactInputSingle. */
export function encodeSwapExactInputSingle(p: SwapExactInputSingleParams): `0x${string}` {
  const body =
    bytes32Word(p.bookId, 'bookId') +
    addressWord(p.tokenIn, 'tokenIn') +
    addressWord(p.tokenOut, 'tokenOut') +
    word(p.amountIn, 'amountIn') +
    word(p.minAmountOut, 'minAmountOut') +
    addressWord(p.recipient, 'recipient') +
    word(p.deadline, 'deadline') +
    word(p.expectedQuoteNonce, 'expectedQuoteNonce') +
    word(p.expectedInventoryNonceOut, 'expectedInventoryNonceOut');
  return `0x${SWAP_SELECTOR}${body}`;
}

export interface QuoteUpdate {
  nonce: bigint;
  /** Ignored by the contract (stamped with block.timestamp); part of the ABI tuple. */
  updatedAt: bigint;
  freshUntil: bigint;
  validUntil: bigint;
  decayBpsPerSecond: bigint;
  maxDecayBps: bigint;
  bidPxX128: bigint;
  askPxX128: bigint;
  maxIn0: bigint;
  maxIn1: bigint;
  sourceHash: `0x${string}`;
}

/** cast sig "updateQuote(bytes32,(uint64,uint64,uint64,uint64,uint32,uint32,uint256,uint256,uint128,uint128,bytes32))" */
const UPDATE_QUOTE_SELECTOR = '6f732027';

/** Calldata for QuaySharedLiquidityAMM.updateQuote (direct updater push). */
export function encodeUpdateQuote(bookId: `0x${string}`, q: QuoteUpdate): `0x${string}` {
  const body =
    bytes32Word(bookId, 'bookId') +
    word(q.nonce, 'nonce') +
    word(q.updatedAt, 'updatedAt') +
    word(q.freshUntil, 'freshUntil') +
    word(q.validUntil, 'validUntil') +
    word(q.decayBpsPerSecond, 'decayBpsPerSecond') +
    word(q.maxDecayBps, 'maxDecayBps') +
    word(q.bidPxX128, 'bidPxX128') +
    word(q.askPxX128, 'askPxX128') +
    word(q.maxIn0, 'maxIn0') +
    word(q.maxIn1, 'maxIn1') +
    bytes32Word(q.sourceHash, 'sourceHash');
  return `0x${UPDATE_QUOTE_SELECTOR}${body}`;
}

/**
 * EIP-712 typed data for updateQuoteWithSig, ready for
 * viem walletClient.signTypedData / ethers signer.signTypedData.
 * `updatedAt` is intentionally absent — the venue stamps it on-chain.
 */
export function quoteUpdateTypedData(args: {
  chainId: number;
  verifyingContract: `0x${string}`;
  bookId: `0x${string}`;
  quote: Omit<QuoteUpdate, 'updatedAt'>;
}) {
  return {
    domain: {
      name: 'QuaySharedLiquidityAMM',
      version: '1',
      chainId: args.chainId,
      verifyingContract: args.verifyingContract,
    },
    types: {
      QuoteUpdate: [
        { name: 'bookId', type: 'bytes32' },
        { name: 'nonce', type: 'uint64' },
        { name: 'freshUntil', type: 'uint64' },
        { name: 'validUntil', type: 'uint64' },
        { name: 'decayBpsPerSecond', type: 'uint32' },
        { name: 'maxDecayBps', type: 'uint32' },
        { name: 'bidPxX128', type: 'uint256' },
        { name: 'askPxX128', type: 'uint256' },
        { name: 'maxIn0', type: 'uint128' },
        { name: 'maxIn1', type: 'uint128' },
        { name: 'sourceHash', type: 'bytes32' },
      ],
    },
    primaryType: 'QuoteUpdate' as const,
    message: {
      bookId: args.bookId,
      nonce: args.quote.nonce,
      freshUntil: args.quote.freshUntil,
      validUntil: args.quote.validUntil,
      decayBpsPerSecond: args.quote.decayBpsPerSecond,
      maxDecayBps: args.quote.maxDecayBps,
      bidPxX128: args.quote.bidPxX128,
      askPxX128: args.quote.askPxX128,
      maxIn0: args.quote.maxIn0,
      maxIn1: args.quote.maxIn1,
      sourceHash: args.quote.sourceHash,
    },
  };
}
