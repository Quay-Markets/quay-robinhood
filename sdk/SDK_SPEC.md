# Quay shared-liquidity SDK spec

The SDK should be deterministic and match `QuaySharedLiquidityAMM.quoteExactInput`.

## State fetches

For each candidate book id:

```text
book = core.books(bookId)
quote = core.quotes(bookId)
maker = core.makers(book.makerId)
availableOut = core.availableLiquidity(book.makerId, tokenOut)
protocolPaused = core.protocolPaused()
```

For discovery:

```text
bookIds = core.getBooksForPair(tokenIn, tokenOut)
```

For oracle-guarded books, fetch the feed specified by `book.oracleFeed` and apply the same staleness/deviation logic as Solidity. For hackathon simplicity, aggregators can also call the on-chain view function as the source of truth.

## Math constants

```text
Q128 = 2^128
BPS = 10_000
```

## Side detection

```text
if tokenIn == book.token0 and tokenOut == book.token1:
  side = SELL_TOKEN0
elif tokenIn == book.token1 and tokenOut == book.token0:
  side = BUY_TOKEN0
else:
  invalid TOKEN_MISMATCH
```

## Fee

```text
fee = floor(amountIn * protocolFeeBps / 10_000)
netIn = amountIn - fee
```

## Decay

```text
if now <= quote.freshUntil:
  decayBps = 0
else:
  decayBps = min(quote.maxDecayBps, (now - quote.freshUntil) * quote.decayBpsPerSecond)
```

## SELL_TOKEN0 quote

```text
if netIn > quote.maxSellToken0In: invalid SIZE_TOO_LARGE
bid = floor(quote.bidPriceX128 * (10_000 - decayBps) / 10_000)
out = floor(netIn * bid / Q128)
if out > quote.maxToken1Out: invalid SIZE_TOO_LARGE
if out > availableOut: invalid INSUFFICIENT_LIQUIDITY
```

## BUY_TOKEN0 quote

```text
if netIn > quote.maxToken1In: invalid SIZE_TOO_LARGE
ask = floor(quote.askPriceX128 * (10_000 + decayBps) / 10_000)
out = floor(netIn * Q128 / ask)
if out > quote.maxBuyToken0Out: invalid SIZE_TOO_LARGE
if out > availableOut: invalid INSUFFICIENT_LIQUIDITY
```

## Router guidance

Use the on-chain view as the final pre-trade check when possible:

```text
quote = core.quoteExactInput(bookId, tokenIn, amountIn)
require quote.valid
swapExactInputSingle({
  bookId,
  tokenIn,
  tokenOut,
  amountIn,
  minAmountOut,
  recipient,
  deadline,
  expectedQuoteNonce: quote.quoteNonce
})
```

`expectedQuoteNonce` is optional but recommended for stock-token markets. If the MM updates quotes between route construction and settlement, the swap reverts instead of filling at a different quote nonce.
