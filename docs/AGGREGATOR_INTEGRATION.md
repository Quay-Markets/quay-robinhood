# Aggregator integration answers

## Integration approach

Quay supports both requested approaches:

1. SDK-style quote computation from on-chain state.
2. External view quoter function.

Recommended view functions:

```solidity
function quoteExactInput(bytes32 bookId, address tokenIn, uint256 amountIn)
    external view returns (QuoteResult memory);

function quoteBestExactInput(address tokenIn, address tokenOut, uint256 amountIn)
    external view returns (QuoteResult memory);

function getBooksForPair(address tokenA, address tokenB)
    external view returns (bytes32[] memory);
```

Recommended swap function:

```solidity
function swapExactInputSingle(SwapExactInputSingleParams calldata p)
    external returns (uint256 amountOut);
```

Settlement uses standard ERC-20 `transferFrom(msg.sender, address(this), amountIn)`.
Permit2 is not used.

## Answers to the questionnaire

### Are your books independent?

Pricing is independent per book. `bookId` owns its own quote state: bid, ask, max sizes, expiry, nonce, and decay.

A WETH/USDC swap does not update the cbBTC/USDC bid/ask, quote nonce, or decay state.

### Is liquidity shared between books?

Liquidity can be shared explicitly by assigning multiple books to the same `liquidityGroupId`.

If WETH/USDC and cbBTC/USDC share a USDC group, a WETH/USDC swap can consume USDC and therefore affect whether a cbBTC/USDC quote is fillable. It does not change the cbBTC/USDC price formula.

Routers should read `liquidityGroupId` and `inventoryNonceOut` from `QuoteResult`. Passing `expectedInventoryNonceOut` into `swapExactInputSingle` lets the router fail fast on shared-liquidity race conditions.

### Can your quoting function return more amountOut than you actually have balance for?

No. `quoteExactInput` checks current group inventory for the output token. If the computed amountOut is larger than available inventory, it returns:

```text
valid = false
reason = InsufficientLiquidity
amountOut = 0
```

For diagnostics only, `quotePriceOnly` can compute the price-only amount without inventory checks. Aggregators should use `quoteExactInput`, not `quotePriceOnly`, for executable routing.

### How do you signal pausing of a pool? What is quote behavior?

Pause is signaled by:

```solidity
event BookStatusChanged(...)
event LiquidityGroupPaused(...)
```

and readable state:

```solidity
books(bookId).status
liquidityGroups(liquidityGroupId).paused
```

When paused, `quoteExactInput` returns `valid=false`, `amountOut=0`, with reason `BookNotActive` or `GroupPaused`. Swap reverts with `QuoteInvalid(reason)`.

### Do you have an off-chain SDK?

The package includes `sdk/quote.ts`, which mirrors Solidity quote math.

SDK fetch path:

```text
getBooksForPair(tokenIn, tokenOut)
books(bookId)
quoteStates(bookId)
liquidityGroups(groupId)
inventory(groupId, tokenOut)
inventoryNonce(groupId, tokenOut)
```

Then compute the same quote as `quoteExactInput`.

### Price decay mechanism and grace period

Yes.

Each quote has:

```text
updatedAt
freshUntil
validUntil
decayBpsPerSecond
maxDecayBps
```

Behavior:

```text
block.timestamp <= freshUntil:
  no decay

freshUntil < block.timestamp <= validUntil:
  bid decays downward, ask decays upward

block.timestamp > validUntil:
  invalid quote
```

Suggested hackathon defaults:

```text
freshUntil = now + 2 seconds
validUntil = now + 10 seconds
decayBpsPerSecond = 5 to 25 bps
maxDecayBps = 100 to 300 bps
```

### Does price depend on gas price or odd transaction fields?

No.

Quay does not inspect:

```text
tx.origin
tx.gasprice
block.basefee
block.coinbase
gasleft()
```

Settled price depends only on:

```text
book quote state
amountIn
token side
protocol fee
current timestamp for decay/expiry
current output inventory
optional nonce guards
```

The main race is normal trade collision, especially when liquidity is shared.

### Do routers need to be whitelisted for optimal pricing?

No. Pricing is router-neutral. `msg.sender` does not affect price.

### Is implementation upgradeable?

Hackathon version: no. It is immutable.

Production recommendation: deploy immutable versions and publish a registry. If a book migrates, emit `BookStatusChanged(Closed)` on old book and `BookCreated` on new book.

### Do you have pool/book creation event?

Yes:

```solidity
event BookCreated(...)
```

### Please list price-update EOAs

Updaters are on-chain:

```solidity
function getUpdaters(bytes32 bookId) external view returns (address[] memory);
function isUpdater(bytes32 bookId, address updater) external view returns (bool);
```

Changes are emitted through:

```solidity
event UpdaterSet(bytes32 indexed bookId, address indexed updater, bool active);
```
