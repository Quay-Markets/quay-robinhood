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

# static analysis (slither.config.json excludes timestamp/incorrect-equality/
# calls-loop: quote decay is timestamp-driven by design, enum sentinels use
# strict equality, and the batch/best-of view quoters loop over trusted feeds)
uvx --python 3.12 --from slither-analyzer --with 'cbor2<6' slither .
```

Test layout:

```text
test/Admin.t.sol            groups, books, statuses, updaters, pause, ownership
test/Liquidity.t.sol        deposit/withdraw, protocol fee accounting
test/QuoteUpdate.t.sol      updater auth + quote validation rules
test/QuoteView.t.sol        quote math, decay, expiry, every invalid reason code
test/Swap.t.sol             settlement, slippage/nonce/deadline guards, hostile tokens
test/SharedLiquidity.t.sol  shared-group fillability vs. independent pricing
test/QuoteUpdateSig.t.sol   EIP-712 relayed quote updates (digest pinning, replay, batch)
test/Oracle.t.sol           per-book reference-price guardrails
test/Strategy.t.sol         strategy registry governance, kill-switch, custom modules
test/Fuzz.t.sol             property tests (round-trip no-profit, decay monotone, fees)
test/Invariant.t.sol        solvency: balances == inventory + fees under random actions
```

## Strategy modules

Pricing is delegated per book to an immutable strategy module implementing
`IQuayStrategy` (`src/interfaces/IQuayStrategy.sol`). The venue core keeps
custody, inventory accounting, nonces, pause logic, quote expiry, the oracle
guard, and settlement; the module only turns (quote params, direction, net
input, available inventory) into an output amount, via a gas-capped staticcall
so it can never write state, move funds, or brick the quoter (a reverting or
gas-burning module degrades to a `StrategyError` quote reason).

`src/strategies/BBOStrategy.sol` is the default: posted bid/ask with linear
staleness decay and per-side size caps.

Reference ports of the Solana prop-AMM pricing models researched in
quay-monorepo `onchain/vm/research/` (structural ports — same curve shapes and
rejection semantics, EVM-native fixed point):

```text
SolFiStrategy      slot-decay quote model (Y_AXIS_FORMULA_PINNED.md): posted
                   mid + per-side C multiplier interpolating fresh -> stale
                   over a ramp window (toxicity defense), linear 1e-7 fee,
                   hard freshness gate; the account's splines are dormant on
                   the calibrated path and are not ported
HumidiFiStrategy   keeper-pushed mid (QuoteState.bidPxX128), taker-adverse
                   spread applied as (1e8 - s)/1e8 in one fused division
                   (authoritative simulator convention); optional fitted
                   sqrt/linear penalty + input-threshold kick, 40bps cap,
                   circuit breaker
BisonFiStrategy    June re-RE model: fused haircut (pick + age*base)*100/256
                   in ppb with the sd=0 field-drop discount, per-side
                   field/floor + defaultPick fallback, signed additive tier
                   ladder on the fill ratio out/availableOut (negative offsets
                   may improve price, matching the binary), optional ratio
                   gate, hard staleness gate
```

These extend `ConfigurableStrategy`: slow-moving curve parameters are stored
per book in the module (settable only by the book's group owner, evented),
while the fast path (mid, size caps, freshness) flows through updateQuote.

Governance is three-tier and enforced at quote time:

```text
setStrategyAuthor(author, allowed)      owner curates who may submit modules
registerStrategy(module)                author submits an immutable module
setStrategyApproval(module, approved)   owner approves; false = Blocked
retireStrategy(module)                  author (or owner) withdraws it, terminal
```

Only Approved strategies can quote or back new books. Blocking or retiring a
strategy instantly invalidates quotes (`StrategyNotApproved`) and reverts swaps
on every book that uses it — but never locks liquidity: deposits, withdrawals,
and quote updates keep working, so makers can always pull their inventory.

## Signed quote updates

Updaters can push quotes directly (`updateQuote`) or sign an EIP-712 `QuoteUpdate`
payload that anyone may relay (`updateQuoteWithSig`, `batchUpdateQuotesWithSig`).
Domain: `name = "QuaySharedLiquidityAMM"`, `version = "1"`. The digest to sign is
exactly `hashQuoteUpdate(bookId, quote)`; `updatedAt` is excluded because the
contract stamps it with `block.timestamp`. Replay is blocked by the strictly
increasing per-book quote nonce.

## Oracle guardrails

`setBookOracle(bookId, feed, maxAge, maxDeviationBps, priceScale)` attaches an
optional Chainlink-style sanity guard to a book. While attached, quoting requires
a positive feed answer no older than `maxAge`, and the undecayed quote midpoint
must stay within `maxDeviationBps` of `answer * priceScale`. Pick `priceScale`
off-chain as `2^128 * 10^token1Decimals / (10^feedDecimals * 10^token0Decimals)`
so the reference lands in the book's price units. Violations surface as
`OracleInvalid`, `OracleStale`, or `OracleDeviation` quote reasons; swaps revert.

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
