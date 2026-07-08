# Quay EVM Shared-Liquidity propAMM

Standalone hackathon design for Quay on an EVM chain.

This version is designed around the aggregator feedback:

- pricing is independent per book
- liquidity may be shared through an explicit `liquidityGroupId`
- quotes are available through an external view function
- swaps use a router/core function with standard ERC-20 `transferFrom`
- no Permit2
- no `tx.origin`, `block.coinbase`, `tx.gasprice`, or `gasleft()` behavior

## Development

Foundry project. Contract lives in `src/QuaySharedLiquidityAMM.sol`; deployment script in
`script/Deploy.s.sol`.

```bash
forge build          # compile (warnings are errors)
forge test           # unit + fuzz + invariant suites (test/)
forge fmt            # format
prek run             # pre-commit hooks: forge fmt --check && forge test
QUAY_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
```

Test layout:

```text
test/Admin.t.sol            groups, books, statuses, updaters, pause, ownership
test/Liquidity.t.sol        deposit/withdraw, protocol fee accounting
test/QuoteUpdate.t.sol      updater auth + quote validation rules
test/QuoteView.t.sol        quote math, decay, expiry, every invalid reason code
test/Swap.t.sol             settlement, slippage/nonce/deadline guards, hostile tokens
test/SharedLiquidity.t.sol  shared-group fillability vs. independent pricing
test/Fuzz.t.sol             property tests (round-trip no-profit, decay monotone, fees)
test/Invariant.t.sol        solvency: balances == inventory + fees under random actions
```

## Components

```text
QuaySharedLiquidityAMM.sol
  - book registry
  - liquidity groups
  - quote store
  - updater registry
  - external view quote functions
  - exact-input swap settlement
```

## Core semantics

A book is one pair and one quote state:

```text
bookId -> token0, token1, liquidityGroupId, protocolFeeBps, status
bookId -> bidPxX128, askPxX128, maxIn0, maxIn1, freshness/expiry/decay
```

A liquidity group is a shared balance bucket:

```text
liquidityGroupId -> token -> inventory
liquidityGroupId -> token -> inventoryNonce
```

Multiple books can reference the same `liquidityGroupId`. This means WETH/USDC and cbBTC/USDC can share the same USDC inventory, while their prices remain independent because bid/ask state is stored per book.

## Important caveat

If books share USDC, a WETH/USDC swap can reduce the available USDC balance for cbBTC/USDC. This can affect fillability, not pricing.

A fresh cbBTC quote after the WETH swap will still compute the same price from the cbBTC book's quote state, but it may return invalid if the shared USDC balance is insufficient. Routers can use `expectedInventoryNonceOut` to avoid race conditions.

## Price units

For a `token0/token1` book:

```text
bidPxX128 = token1 atoms per token0 atom * 2^128
askPxX128 = token1 atoms per token0 atom * 2^128
```

Examples:

```text
Sell token0 -> receive token1:
  amountOut = netAmountIn * decayedBidPxX128 / 2^128

Sell token1 -> receive token0:
  amountOut = netAmountIn * 2^128 / decayedAskPxX128
```

The quote is exact-input only for the hackathon version.

## Deployment flow

1. Deploy `QuaySharedLiquidityAMM(owner)`.
2. Create a liquidity group.
3. Create one or more books using that group.
4. Set updater EOAs for each book.
5. Deposit token inventory into the group.
6. Updater pushes quotes.
7. Aggregator calls `quoteExactInput` or `quoteBestExactInput`.
8. Aggregator calls `swapExactInputSingle` using standard ERC-20 allowance.

## No Permit2 flow

Before swapping, the caller must approve the Quay contract directly:

```text
IERC20(tokenIn).approve(quay, amountIn)
quay.swapExactInputSingle(params)
```

If an aggregator router calls Quay, the aggregator router must hold/receive the input token and approve Quay, or call after it has custody of the token from the previous leg.
