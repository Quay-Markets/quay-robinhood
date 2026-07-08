# Quay EVM shared-liquidity standalone propAMM

## Design target

Build a standalone EVM version of Quay that behaves like a professional market-maker venue:

```text
market-data daemon -> quote update -> on-chain quote state -> router view quote -> swap settlement
```

For the hackathon, do not build a VM and do not depend on Uniswap hooks. The canonical venue is the Quay contract. A Uniswap hook adapter can be added later as a distribution adapter.

## Required aggregator constraint

Aggregators said:

> Liquidity can be shared; pricing should be independent.

Therefore V1 uses this rule:

```text
Price state is per book.
Liquidity state is per maker/token.
```

This means:

```text
WETH/USDC swap:
  changes maker WETH and USDC shared inventory
  does not mutate cbBTC/USDC bid/ask quote state

cbBTC/USDC quote:
  reads cbBTC/USDC quote state for price
  reads shared USDC balance only to decide whether output is fillable
```

So a WETH/USDC swap can reduce the maximum fillable size of a cbBTC/USDC sell, but cannot change the cbBTC/USDC price function.

## State model

### Maker

```solidity
struct Maker {
    address owner;
    MakerStatus status;
}
```

The maker owns quote updates and deposits. Maker status gates every book owned by the maker.

### Shared liquidity

```solidity
mapping(uint32 makerId => mapping(address token => uint256 amount)) tradable;
mapping(uint32 makerId => mapping(address token => uint256 amount)) protocolFees;
```

`tradable[makerId][USDC]` is shared by all books owned by the maker that need USDC output. This is the EVM equivalent of a MarketMaker asset table.

### Book

```solidity
struct Book {
    uint32 makerId;
    address token0;
    address token1;
    BookStatus status;
    uint16 protocolFeeBps;
    address oracleFeed;
    uint64 maxOracleAge;
    uint32 maxOracleDeviationBps;
    uint64 version;
}
```

A book is one pair and one independent price stream. The book does not own liquidity directly. It references the maker's shared token inventory.

### Quote

```solidity
struct Quote {
    uint64 nonce;
    uint64 sourceTs;
    uint64 updatedAt;
    uint64 freshUntil;
    uint64 validUntil;
    uint32 decayBpsPerSecond;
    uint32 maxDecayBps;
    uint256 bidPriceX128;
    uint256 askPriceX128;
    uint256 maxSellToken0In;
    uint256 maxBuyToken0Out;
    uint256 maxToken1Out;
    uint256 maxToken1In;
    bytes32 sourceHash;
}
```

Price convention:

```text
token0 -> token1: output = netIn * bidPriceX128 / 2^128
token1 -> token0: output = netIn * 2^128 / askPriceX128
```

The taker always gets rounded down.

## Quote lifecycle

```text
updatedAt <= now <= freshUntil:
  quote is fresh, no decay

freshUntil < now <= validUntil:
  quote is valid but decayed
  bid decreases
  ask increases

now > validUntil:
  quote is invalid
```

Decay formula:

```text
decayBps = min(maxDecayBps, (now - freshUntil) * decayBpsPerSecond)

effectiveBid = bid * (10_000 - decayBps) / 10_000
effectiveAsk = ask * (10_000 + decayBps) / 10_000
```

## Quote validation

`quoteExactInput(bookId, tokenIn, amountIn)` returns invalid if any of these are true:

```text
protocol paused
book paused / retired / missing
maker paused / halted / missing
wrong token pair
quote missing or expired
oracle stale or quote midpoint deviates too far from oracle
amount exceeds side-specific max size
computed output is zero
computed output exceeds side-specific max output
computed output exceeds shared available output liquidity
```

The quote function returns a status code instead of reverting for normal invalid conditions. The swap function recomputes the quote and reverts if invalid.

## Settlement

`swapExactInputSingle` uses standard ERC-20 approval/transfer flow:

```text
1. Router/user approves QuaySharedLiquidityAMM for tokenIn.
2. Router/user calls swapExactInputSingle.
3. Contract recomputes quote.
4. Contract pulls tokenIn from msg.sender using transferFrom.
5. Contract increments shared input inventory by net input.
6. Contract accrues protocol fee in input token.
7. Contract decrements shared output inventory.
8. Contract transfers tokenOut to recipient.
```

No Permit2 is used.

## Router integration

Primary integration functions:

```solidity
function quoteExactInput(
    bytes32 bookId,
    address tokenIn,
    uint256 amountIn
) external view returns (QuoteResult memory);

function quoteBestExactInput(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
) external view returns (QuoteResult memory);

function batchQuoteExactInput(
    bytes32[] calldata bookIds,
    address tokenIn,
    uint256 amountIn
) external view returns (QuoteResult[] memory);

function swapExactInputSingle(SwapExactInputSingleParams calldata p) external returns (uint256 amountOut);
```

Book discovery:

```solidity
function getBooksForPair(address tokenA, address tokenB)
    external view returns (bytes32[] memory);

function quoteBestExactInput(address tokenIn, address tokenOut, uint256 amountIn)
    external view returns (QuoteResult memory);
```

## Shared-liquidity disclosure

Every quote returns:

```solidity
bytes32 liquidityGroupId;
uint256 availableOut;
```

The liquidity group for V1 is:

```text
liquidityGroupId = hash("QUAY_SHARED_LIQUIDITY_V1", makerId, tokenOut)
```

If two books return the same `liquidityGroupId` for an output token, they share that output inventory. Aggregators can use this to avoid double-counting available size across books.

## Upgrade policy

Hackathon V1 should not use a proxy. Deploy immutable core. If the implementation changes, deploy a new core and publish a new deployment manifest.

Events:

```solidity
event BookCreated(...)
event BookStatusChanged(...)
event QuoteUpdated(...)
event UpdaterSet(...)
event Swap(...)
```

These are enough for aggregators to index books, pauses, quote updates, and updater EOAs.
