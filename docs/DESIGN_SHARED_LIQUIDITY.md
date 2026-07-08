# Quay shared-liquidity design

## Why the simple WETH/USDG contract is not enough

The provided `SimpleWethUsdgExchange` is a useful proof of concept for one pair:

- owner sets bid/ask
- contract holds reserves
- exact-input swaps use fixed prices
- quote functions are deterministic
- no caller-specific pricing

For aggregator integration, it needs these additions:

1. Multiple books, not one hard-coded pair.
2. Per-book quote state with nonce, freshness, expiry, and decay.
3. Shared liquidity groups so one USDC bucket can back multiple books.
4. Explicit executable quote function returning status codes instead of reverting.
5. Standard router swap function using ERC-20 `transferFrom`, not Permit2.
6. Updater registry and events so aggregators can list updater EOAs.
7. Inventory nonce so routers can detect shared-liquidity race conditions.

## Required semantic split

```text
Book = pricing object
LiquidityGroup = balance object
```

A book owns:

```text
token0
token1
bid
ask
max sizes
freshUntil
validUntil
decay
status
updaters
```

A liquidity group owns:

```text
token balances
protocol fees
inventory nonce per token
paused flag
owner
```

This satisfies the aggregator requirement:

```text
Liquidity can be shared.
Pricing must be independent.
```

## Example

```text
LiquidityGroup: MM_MAIN
  USDC inventory: 1,000,000
  WETH inventory: 500
  cbBTC inventory: 50

Book A: WETH/USDC
  liquidityGroupId = MM_MAIN
  bid/ask = WETH-specific quote

Book B: cbBTC/USDC
  liquidityGroupId = MM_MAIN
  bid/ask = cbBTC-specific quote
```

A WETH/USDC trade changes:

```text
MM_MAIN.USDC inventory
MM_MAIN.WETH inventory
inventoryNonce(MM_MAIN, USDC)
inventoryNonce(MM_MAIN, WETH)
```

It does not change:

```text
Book B bid
Book B ask
Book B quote nonce
Book B max sizes
Book B decay timestamps
```

So the cbBTC/USDC price is independent, but cbBTC/USDC fillability can change if the shared USDC side was consumed.

## Quote behavior

`quoteExactInput` is the executable quote. It returns invalid if not fillable.

```text
rawPriceAmountOut = per-book price function(amountIn)

if rawPriceAmountOut > sharedInventory[tokenOut]:
    return valid=false, reason=InsufficientLiquidity, amountOut=0
else:
    return valid=true, amountOut=rawPriceAmountOut
```

This avoids returning more output than the protocol can settle.

## Race handling

Because liquidity can be shared, the router may fetch a quote and then another trade can consume the same output inventory.

Quay exposes:

```text
QuoteResult.inventoryNonceOut
```

Router may pass it into:

```text
SwapExactInputSingleParams.expectedInventoryNonceOut
```

If another trade changes output inventory before settlement, swap reverts with `InventoryNonceMismatch` instead of silently settling against a different inventory state.

Router can set the field to `0` to ignore this guard and rely only on `minAmountOut`.

## Price decay

Quay uses quote-level decay:

```text
freshUntil: quote has no decay
validUntil: quote expires after this time
```

For token0 -> token1:

```text
bid = bid * (1 - decayBps)
```

For token1 -> token0:

```text
ask = ask * (1 + decayBps)
```

This means stale-but-not-expired quotes become worse for the taker.

## Settlement

No Permit2.

```text
IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn)
IERC20(tokenOut).safeTransfer(recipient, amountOut)
```

Caller must use direct ERC-20 approval to the Quay contract, or the aggregator router must hold the input token and approve Quay.

## Hackathon simplifications

This implementation intentionally avoids:

- exact-output swaps
- EIP-712 signed quote updates
- oracle guards
- upgradeable proxy
- multiple strategy modules
- Uniswap v4 hook adapter
- transfer-fee tokens

These can be added after the demo.
