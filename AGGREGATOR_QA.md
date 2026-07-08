# Aggregator Q&A for Quay shared-liquidity V1

## Are your books independent? Does swapping WETH/USDC change cbBTC/USDC price?

Pricing is independent per book. A WETH/USDC swap does not mutate the cbBTC/USDC quote state and does not change the cbBTC/USDC price formula.

Liquidity can be shared. Therefore, a WETH/USDC swap may change shared USDC availability and reduce the maximum fillable size for cbBTC/USDC. It does not change cbBTC/USDC price.

## Is liquidity shared between books?

Yes, optionally and explicitly. V1 shared liquidity is per `(makerId, token)`. For example, all books owned by maker `1` that output USDC can use `tradable[1][USDC]`.

Every quote returns `liquidityGroupId` and `availableOut`. Books with the same output-token liquidity group share inventory.

## Can your quoting function return more amountOut than you actually have balance for?

No. The quote function checks computed output against `availableLiquidity(makerId, tokenOut)`. If insufficient, it returns `valid=false`, `amountOut=0`, and status `INSUFFICIENT_LIQUIDITY`. Swap recomputes the quote on-chain and reverts if state changed.

## How do you signal pausing of a pool? What is quoting behavior?

Pausing is signaled by:

- `BookStatusChanged(bookId, status, version)` event;
- on-chain `books(bookId).status`;
- quote result `valid=false`, `amountOut=0`, status `BOOK_PAUSED`.

Maker-wide pause is signaled by `MakerStatusChanged`; quote result status is `MAKER_PAUSED`.

Protocol-wide pause is signaled by `ProtocolPausedSet`; quote result status is `PROTOCOL_PAUSED`.

## Do you have an off-chain SDK we could use to compute quotes from on-chain state?

Yes. The SDK fetches:

- `books(bookId)`;
- `quotes(bookId)`;
- `makers(makerId)`;
- `tradable(makerId, tokenOut)` or `availableLiquidity(makerId, tokenOut)`;
- optional oracle state if the book has an oracle feed.

The SDK uses the same Q128 math and decay formula as Solidity.

## Do you also have an external view quote function?

Yes. The primary function is:

```solidity
quoteExactInput(bytes32 bookId, address tokenIn, uint256 amountIn)
```

There is also:

```solidity
batchQuoteExactInput(bytes32[] bookIds, address tokenIn, uint256 amountIn)
quoteBestExactInput(address tokenIn, address tokenOut, uint256 amountIn)
```

`quoteBestExactInput` scans the registered books for the pair. Aggregators can also call `getBooksForPair` + `batchQuoteExactInput` when they want to control candidate selection.

## Do you have a price decay mechanism if no updates are pushed?

Yes. Quote is fresh until `freshUntil`, then decays until `validUntil`, then becomes invalid.

During decay:

```text
bid decreases
ask increases
```

Recommended hackathon defaults:

```text
freshUntil = updatedAt + 2 seconds
validUntil = updatedAt + 8 seconds
decayBpsPerSecond = 5 to 20 bps
maxDecayBps = 50 to 100 bps
```

For volatile stock tokens, use shorter windows.

## Does quoted or settled price depend on transaction gas price?

No. The quote does not read gas price, base fee, priority fee, `tx.origin`, `block.coinbase`, or `gasleft()`.

The settled amount can differ from a prior off-chain quote only because:

- block timestamp moved into the decay window or past expiry;
- the quote nonce changed;
- shared output liquidity was consumed by another swap;
- the oracle sanity check changed;
- the router used a different amount or book.

Routers should use `minAmountOut`, `deadline`, and optionally `expectedQuoteNonce`.

## Do you inspect tx.origin or block.coinbase?

No.

## Do you use gasleft()?

No.

## Do routers need to be whitelisted to get optimal pricing?

No. Pricing is router-neutral. `msg.sender`, `recipient`, and router identity do not affect price.

Only quote updater EOAs are permissioned.

## Is your pool implementation upgradeable?

Hackathon V1 should not be upgradeable. Deploy immutable core.

If a new version is deployed, notify aggregators with:

- new deployment manifest;
- `BookCreated` events on the new core;
- off-chain registry update;
- old books set to `RETIRED` or `PAUSED`.

## Do you have a pool/book creation event?

Yes:

```solidity
event BookCreated(...);
```

It includes book id, maker id, token pair, pair key, and liquidity group ids.

## Please list the EOAs used for price updates.

Updater addresses are on-chain per book through:

```solidity
mapping(bytes32 bookId => mapping(address updater => bool allowed)) isUpdater;
event UpdaterSet(bytes32 indexed bookId, address indexed updater, bool allowed);
```

The exact EOA list is deployment-specific and should be published in the deployment manifest after deploy.

## How does the router move funds?

No Permit2. `swapExactInputSingle` pulls tokenIn from `msg.sender` using standard ERC-20 `transferFrom`.

Aggregator routers should hold the input token and approve the Quay core contract, then call `swapExactInputSingle`. User-direct swaps work by approving Quay directly and calling `swapExactInputSingle`.
