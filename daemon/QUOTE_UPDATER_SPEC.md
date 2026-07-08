# Quote updater daemon spec

The updater daemon is the EVM equivalent of the Solana quote-account updater.

## Inputs

```text
market data: Alpaca / broker feed / CEX / internal fair value
on-chain sanity: optional Chainlink or Robinhood Stock Token feeds
inventory: core.tradable(makerId, token0/token1)
book config: core.books(bookId)
last quote: core.quotes(bookId)
```

## Output quote

For each book, produce:

```text
nonce: last nonce + 1
sourceTs: market-data timestamp
freshUntil: block timestamp estimate + fresh window
validUntil: block timestamp estimate + valid window
bidPriceX128: token1 atoms per token0 atom, scaled by 2^128
askPriceX128: token1 atoms per token0 atom, scaled by 2^128
maxSellToken0In: maximum token0 input accepted
maxBuyToken0Out: maximum token0 output allowed
maxToken1Out: maximum token1 output allowed
maxToken1In: maximum token1 input accepted
decayBpsPerSecond
maxDecayBps
sourceHash: hash of signed/off-chain quote batch metadata
```

## Price conversion

If market price is `P = token1 whole units per 1 whole token0`, then:

```text
rawRatio = P * 10^token1Decimals / 10^token0Decimals
priceX128 = rawRatio * 2^128
```

For example, if token0 is WETH with 18 decimals and token1 is USDG with 6 decimals:

```text
P = 3500 USDG per WETH
bidPriceX128 = bidP * 10^6 * 2^128 / 10^18
askPriceX128 = askP * 10^6 * 2^128 / 10^18
```

## Independence rule

The updater may use global risk data internally, but the on-chain quote for a book must be self-contained. A trade in another book should not mutate this book's quote state.

If shared liquidity decreases, the quote view may become invalid for insufficient output inventory. The book price itself is unchanged until the updater posts a new quote for that book.

## Suggested windows for demo

```text
fresh window: 2 seconds
valid window: 8 seconds
decay: 10 bps per second after fresh window
max decay: 100 bps
```

## Failure handling

Pause or stop quoting if:

```text
market data is stale
oracle sanity check fails
underlying market is in an abnormal state
inventory is below minimum
quote update transaction fails repeatedly
```

On failure, call `setBookStatus(bookId, PAUSED)` or push a quote with very small max sizes and short expiry, depending on the desired demo behavior.
