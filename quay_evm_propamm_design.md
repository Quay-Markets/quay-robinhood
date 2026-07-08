# Quay EVM propAMM design for Robinhood Chain

**Version:** v0.1 builder spec  
**Date:** 2026-07-08  
**Target chain:** Robinhood Chain mainnet, chain ID 4663  
**Primary goal:** Port the useful Quay/Solana propAMM model to EVM while making it easy for aggregators to reason about quote determinism, liquidity dependencies, pausing, stale quotes, and upgrades.

---

## 0. Executive decision

Build **QuayEVMCore as the canonical venue**, then add **Uniswap v4 hook adapter** as a distribution surface.

Do **not** make the Uniswap hook the only protocol state in V1. A hook-only design can work, but it creates routing and allowlist constraints and makes multi-book inventory management awkward. The recommended design is:

```text
Market-data sources / Alpaca / internal MM model
    ↓
Quay updater daemon
    ↓ signed or direct quote updates
QuayQuoteStore
    ↓
QuayEVMCore  ← canonical vaults, book inventory, quote validation, settlement
    ↓
QuayRouter / QuayQuoter / Aggregator adapters
    ↓
Users, aggregators, RFQ routers, Robinhood ecosystem routers

Optional distribution path:
Uniswap v4 PoolManager
    ↓
QuayV4HookAdapter
    ↓
QuayEVMCore
```

This means Quay competes with Uniswap only as a **liquidity source**, not necessarily as a full protocol replacement. The Uniswap hook adapter lets Quay liquidity be exposed inside Uniswap v4 routing, while direct QuayRouter integration lets 0x/1inch/Robinhood-style routers integrate Quay as a native source.

---

## 1. Why this architecture

### 1.1 Solana Quay model being ported

Current Quay/Solana separates:

```text
Strategy = pricing config / bytecode / userspace, no funds
MarketMaker = per-owner asset table and balances shared by strategies
Quotes = owner-updated packed quote blob
Swap = compute quote, check balances, settle vault transfers
Agg swap = best-of-N strategy selection
```

On EVM, the same conceptual split should be preserved, but the custom VM should not be the first implementation. EVM V1 should use explicit strategy modules and quote structs instead of an on-chain generic interpreter.

### 1.2 Why not hook-only

A Uniswap v4 hook can express custom pricing, including custom accounting / custom curves. However, a production propAMM needs:

```text
- explicit book registry
- clear quote view API
- deterministic SDK-compatible quote math
- book inventory isolation or disclosed shared-liquidity dependency groups
- upgrade/version events
- updater registry
- router-neutral pricing
- direct aggregator integration path
```

A hook-only design can hide these behind PoolManager interactions and can be harder for aggregators to index. It can also be blocked by hook allowlist constraints when custom accounting or custom hook data is used.

---

## 2. High-level contract system

### 2.1 Required contracts

```text
QuayFactory
  Creates books, deploys or registers core/version metadata, emits BookCreated.

QuayEVMCore
  Canonical settlement contract. Holds vaults/accounting, validates book status,
  reads latest quotes, computes amountOut, transfers ERC-20s, updates inventory.

QuayQuoteStore
  Stores latest quote per book. Supports direct updater calls and EIP-712 signed
  quote updates that anyone can relay.

QuayBookRegistry
  Stores book metadata: tokens, maker, status, liquidity mode, strategy module,
  dependency group, risk params, oracle params, updater list.

QuayQuoter
  Pure/view quoting facade for aggregators. Must not revert for normal invalid
  quote states; returns status codes and dependencies.

QuayRouter
  Direct swap entrypoint for aggregators and users.

QuayUpdaterRegistry
  Maintains active update EOAs per maker/book and emits updater changes.

QuayRiskLib / QuayPricingLib
  Internal libraries for deterministic quote math and risk checks.
```

### 2.2 Optional contracts

```text
QuayV4HookAdapter
  Non-upgradeable Uniswap v4 hook that maps v4 pools to Quay books and routes
  quote/settlement through QuayEVMCore.

QuayAggregatorAdapter0x / QuayAggregatorAdapter1inch
  Thin adapters if a specific aggregator wants a custom call shape.

QuayMulticallStateLens
  Read-only helper returning all state needed by the off-chain SDK in one call.
```

---

## 3. Core concepts

### 3.1 Book

A **Book** is a directed market for a pair. It is the EVM equivalent of a Quay Strategy plus an allocated inventory bucket.

```solidity
type BookId is bytes32;

enum BookStatus {
    Uninitialized,
    Active,
    PausedByMaker,
    PausedByAdmin,
    Stale,
    Migrated
}

enum LiquidityMode {
    IsolatedBook,
    SharedGroup_Disclosed
}

struct BookConfig {
    address maker;
    address token0;
    address token1;
    uint8 token0Decimals;
    uint8 token1Decimals;
    bytes32 liquidityGroupId;
    LiquidityMode liquidityMode;
    BookStatus status;
    address strategyModule;
    uint16 protocolFeeBps;
    uint16 maxOracleDeviationBps;
    uint32 freshSeconds;
    uint32 decaySeconds;
    uint32 maxStaleSeconds;
    address oracle0;
    address oracle1;
    bool stockToken0;
    bool stockToken1;
}
```

`token0/token1` ordering is canonical: `token0 < token1` by address unless the book is created with an explicit base/quote convention. For stock-token books, recommended convention is:

```text
token0 = stock token, e.g. AAPL
token1 = USDG
price = token1 atoms per token0 atom
```

### 3.2 Book inventory

For aggregator friendliness, V1 routed books should use **isolated book inventory** even if the actual ERC-20 vault is shared at the maker/token level.

```solidity
struct BookInventory {
    uint128 available0;
    uint128 available1;
    uint128 protocolFees0;
    uint128 protocolFees1;
    uint64 inventoryNonce;
}
```

Rules:

```text
- A book can only quote against its allocated available0/available1.
- Swapping WETH/USDC does not alter cbBTC/USDC price or available quote size
  unless both books explicitly share the same liquidityGroupId in SharedGroup mode.
- Public aggregator books default to IsolatedBook mode.
- SharedGroup_Disclosed is allowed later, but aggregators must be told that books
  with the same group ID have cross-book dependency.
```

This solves a key aggregator concern: a shared maker wallet can still fund many books, but the routeable state exposed to aggregators is not double-counted.

### 3.3 Quote state

The on-chain quote is a bounded, signed BBO-style quote. The proprietary model remains off-chain.

```solidity
struct QuoteState {
    uint64 nonce;
    uint64 updatedAt;
    uint64 freshUntil;
    uint64 validUntil;

    // price is token1 atoms per token0 atom in Q128.128 fixed point
    // bidPx: MM buys token0, user sells token0 for token1
    // askPx: MM sells token0, user sells token1 for token0
    uint256 bidPxX128;
    uint256 askPxX128;

    uint128 maxIn0;     // max exact input when user sells token0
    uint128 maxIn1;     // max exact input when user sells token1

    uint16 decayBpsPerSecond;
    uint16 maxDecayBps;
    uint32 flags;
    bytes32 sourceHash; // off-chain source batch hash, e.g. Alpaca/internal model ref
}
```

Quote invariants:

```text
- nonce strictly increases per book.
- updatedAt <= block.timestamp + maxClockSkew.
- freshUntil >= updatedAt.
- validUntil >= freshUntil.
- validUntil - updatedAt <= book.maxStaleSeconds.
- bidPxX128 < askPxX128.
- maxIn0/maxIn1 cannot exceed configured inventory caps.
- If an oracle is configured, quote mid must be within maxOracleDeviationBps.
```

### 3.4 Quote update path

Two update methods:

```solidity
function updateQuote(BookId bookId, QuoteState calldata q) external;

function updateQuoteWithSig(
    BookId bookId,
    QuoteState calldata q,
    bytes calldata updaterSig
) external;

function batchUpdateQuotes(
    BookId[] calldata bookIds,
    QuoteState[] calldata quotes,
    bytes[] calldata updaterSigs
) external;
```

`updateQuote` requires `msg.sender` to be an authorized updater for the book. `updateQuoteWithSig` lets any relayer submit a quote signed by an authorized updater using EIP-712.

EIP-712 domain:

```text
name: QuayQuoteStore
version: 1
chainId: Robinhood Chain chain ID
verifyingContract: QuayQuoteStore address
```

Typed data:

```text
QuoteUpdate(
  bytes32 bookId,
  uint64 nonce,
  uint64 updatedAt,
  uint64 freshUntil,
  uint64 validUntil,
  uint256 bidPxX128,
  uint256 askPxX128,
  uint128 maxIn0,
  uint128 maxIn1,
  uint16 decayBpsPerSecond,
  uint16 maxDecayBps,
  uint32 flags,
  bytes32 sourceHash
)
```

---

## 4. Pricing and quote behavior

### 4.1 Exact-input quote function

Required public quoter interface:

```solidity
struct QuoteResult {
    bool valid;
    uint8 statusCode;
    BookId bookId;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 protocolFeeAmount;
    uint64 quoteNonce;
    uint64 inventoryNonce;
    uint64 validUntil;
    bytes32 liquidityGroupId;
    bytes32 quoteHash;
    uint256 gasEstimate;
}

interface IQuayQuoter {
    function quoteExactInput(
        BookId bookId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (QuoteResult memory);

    function getBook(BookId bookId) external view returns (BookConfig memory, BookInventory memory, QuoteState memory);

    function getBooksForPair(address tokenA, address tokenB) external view returns (BookId[] memory);
}
```

The quoter should **not revert** for normal route-invalid states. It returns:

```text
valid = false
amountOut = 0
statusCode = reason
```

Status codes:

```text
0  OK
1  BOOK_NOT_FOUND
2  PAUSED_BY_MAKER
3  PAUSED_BY_ADMIN
4  STALE_QUOTE
5  EXPIRED_QUOTE
6  MAX_SIZE_EXCEEDED
7  INSUFFICIENT_LIQUIDITY
8  ORACLE_STALE
9  ORACLE_PAUSED
10 ORACLE_DEVIATION
11 UNSUPPORTED_TOKEN
12 INVALID_AMOUNT
13 MIGRATED
```

### 4.2 Quote math

For `token0 -> token1`:

```text
grossOut = amountIn * effectiveBidPxX128 / 2^128
```

For `token1 -> token0`:

```text
grossOut = amountIn * 2^128 / effectiveAskPxX128
```

Then:

```text
protocolFeeAmount = grossOut * protocolFeeBps / 10_000
amountOut = grossOut - protocolFeeAmount
```

Alternative fee mode is input-side fee to match Solana Quay. Choose one mode and never vary by router. Recommended EVM V1: **input-side fee** because it mirrors existing Quay and reduces output-side confusion.

Input-side fee version:

```text
feeIn = amountIn * protocolFeeBps / 10_000
netIn = amountIn - feeIn
rawOut = price(netIn)
amountOut = rawOut
```

Use input-side fee in implementation for Solana parity.

### 4.3 Price decay

A quote has three periods:

```text
updatedAt ───────── freshUntil ───────── validUntil ───────── invalid
          normal quote          decayed quote          no quote
```

If `block.timestamp <= freshUntil`:

```text
effectiveBid = bidPx
effectiveAsk = askPx
```

If `freshUntil < block.timestamp <= validUntil`:

```text
ageDecaySeconds = block.timestamp - freshUntil
decayBps = min(maxDecayBps, ageDecaySeconds * decayBpsPerSecond)
effectiveBid = bidPx * (10_000 - decayBps) / 10_000
effectiveAsk = askPx * (10_000 + decayBps) / 10_000
```

If `block.timestamp > validUntil`:

```text
quote invalid; amountOut = 0; statusCode = EXPIRED_QUOTE; swap reverts.
```

Recommended defaults:

```text
Crypto / stable pairs:
  freshSeconds = 2
  decaySeconds = 8
  maxStaleSeconds = 10

Stock-token / USDG pairs during active sessions:
  freshSeconds = 1 or 2
  decaySeconds = 4 to 8
  maxStaleSeconds = 5 to 10

Stock-token pairs during thin/off-hours sessions:
  either pause, or use stricter max size and wider spreads.
```

All values are per-book config and emitted in events. Aggregators should read them from `BookConfig` and should not hard-code the defaults.

### 4.4 Oracle guardrails for stock tokens

For Robinhood Stock Tokens, the updater can use Alpaca or another off-chain market-data source to compute fast quotes. The chain cannot verify Alpaca directly, so the on-chain contract must use Chainlink/Robinhood feeds as a sanity guard when configured.

Recommended rules:

```text
- Read Chainlink latestRoundData through configured feed.
- Reject if answer <= 0.
- Reject if updatedAt is older than oracleMaxAge, except for explicitly configured off-hours mode.
- For stock tokens, read token oraclePaused(); if true, quote invalid.
- If token exposes uiMultiplier/newUIMultiplier/effectiveAt, include multiplier state in off-chain daemon and risk monitoring.
- Reject if quote mid deviates from oracle reference by more than maxOracleDeviationBps.
```

Corporate action mode:

```text
- If oraclePaused() is true: status ORACLE_PAUSED, swaps revert.
- If multiplier update is pending: maker daemon should pause or publish tiny max size until new reference is confirmed.
- Emit BookStatusChanged or QuoteUpdated with flags indicating corporate-action guarded mode.
```

---

## 5. Swap behavior

### 5.1 Direct swap interface

```solidity
struct SwapExactInputParams {
    BookId bookId;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    address recipient;
    uint64 deadline;
    bytes32 expectedQuoteHash; // optional; zero means no exact quote hash check
}

interface IQuayRouter {
    function swapExactInputSingle(
        SwapExactInputParams calldata p
    ) external payable returns (uint256 amountOut);
}
```

Settlement:

```text
1. Check deadline.
2. Load book, quote, inventory.
3. Recompute quote using exactly the same library as QuayQuoter.
4. Require quote.valid.
5. Require amountOut >= minAmountOut.
6. If expectedQuoteHash != 0, require current quoteHash == expectedQuoteHash.
7. Transfer amountIn from taker/router to vault.
8. Transfer amountOut from vault to recipient.
9. Update book inventory and fee accounting.
10. Emit Swap.
```

### 5.2 Collision behavior

If another trade or quote update lands before a router transaction:

```text
- The current quote may change.
- The current inventory may change.
- swapExactInputSingle recomputes from current state.
- If amountOut < minAmountOut or current quoteHash mismatches expectedQuoteHash, it reverts.
```

This is the only intended source of quote/settlement mismatch, besides time decay or explicit quote updates.

### 5.3 No partial fills in V1

For aggregator simplicity:

```text
- exact-input swap either fills full amount or reverts.
- no partial fill.
- no hidden dynamic router-specific improvement.
```

Partial-fill support can be added later through a separate function and must not change behavior of `swapExactInputSingle`.

---

## 6. Liquidity model

### 6.1 V1 default: isolated book allocations

Even if the actual ERC-20 balance lives in one vault per maker/token, the routed accounting must isolate each book.

```text
MakerVault[maker][token] actual ERC-20 balance
BookInventory[bookId].available0/available1 allocated to a single book
```

Invariant:

```text
sum(book allocations for maker/token) + maker free balance + protocol fees <= vault token balance
```

A trade only mutates the inventory of its own book.

### 6.2 Optional later: disclosed shared liquidity groups

For capital efficiency, a future version may support shared books:

```text
WETH/USDC and cbBTC/USDC both share liquidityGroupId = X
```

Aggregator contract/API must then expose:

```text
- liquidityGroupId
- inventoryNonce
- dependencyGroupId
- list of affected books or a group-level nonce
```

Routers can treat same-group books as mutually dependent. Do not enable this for public routed books until aggregators explicitly support it.

---

## 7. Pause, halt, and freeze design

### 7.1 Statuses

```solidity
enum PauseReason {
    None,
    MakerPaused,
    AdminPaused,
    QuoteExpired,
    OracleStale,
    OraclePaused,
    Migration,
    RiskLimit
}
```

Book status lives in `BookConfig.status`. Quote-derived temporary invalidity is returned by `QuayQuoter` as a status code and does not have to write state.

### 7.2 Pause behavior

```text
Maker pause:
  book.status = PausedByMaker
  quote returns valid=false, amountOut=0, status=PAUSED_BY_MAKER
  swap reverts BookPaused

Admin pause:
  book.status = PausedByAdmin
  quote returns valid=false, amountOut=0, status=PAUSED_BY_ADMIN
  swap reverts BookPaused

Expired quote:
  book.status may remain Active
  quote returns valid=false, amountOut=0, status=EXPIRED_QUOTE
  swap reverts QuoteExpired
```

### 7.3 Events

```solidity
event BookStatusChanged(
    bytes32 indexed bookId,
    uint8 oldStatus,
    uint8 newStatus,
    uint8 reason,
    address indexed actor,
    uint64 timestamp
);
```

---

## 8. Aggregator-facing answer sheet

This section should be copy-pasted to aggregators after deployment, with addresses filled in.

| Aggregator question | Quay EVM answer | Mechanism |
|---|---|---|
| Are your books independent? Does WETH/USDC change cbBTC/USDC? | **V1 routed books are independent by default.** A swap mutates only the selected `bookId` inventory and nonce. Other books are unaffected unless explicitly created in `SharedGroup_Disclosed` mode. | `BookInventory` is per-book; `liquidityGroupId` discloses dependencies. |
| Is liquidity shared between books? Is same USDC used for WETH/USDC and cbBTC/USDC? | **No for V1 public routed books.** Underlying vaults may be per maker/token, but allocated book inventory is isolated and cannot be double-counted. Shared liquidity groups are a future explicit mode. | Allocation ledger enforces per-book available balances. |
| Can quoting return more `amountOut` than actual balance? | **No.** Quote checks `availableOut`, protocol fees, inventory buffers, max size, and actual vault sanity. If insufficient, it returns invalid/0; swap repeats the check and reverts on underflow or failed transfer. | `quoteExactInput` uses spendable inventory; `swap` recomputes. |
| How do you signal pausing of a pool? What is quoting behavior? | Book status is on-chain and evented. Quoter returns `valid=false`, `amountOut=0`, and a status code. Swap reverts. | `BookStatusChanged`, `BookConfig.status`, `QuoteResult.statusCode`. |
| Off-chain SDK to compute quotes from on-chain state? | **Yes.** TypeScript SDK must include state loader, pure quote math, swap calldata builder, and test vectors matching Solidity. | `QuayMulticallStateLens` + `@quay/evm-sdk`. |
| Price decay if no updates? Grace period? | **Yes.** Quote is normal until `freshUntil`, then spread widens until `validUntil`, then invalid. Defaults: fresh 1–2s, decay 4–8s, invalid after 5–10s depending on book. | `freshSeconds`, `decaySeconds`, `maxStaleSeconds`, `QuoteState`. |
| Does settled price depend on tx gas price or other oddities? | **No gas-price dependence.** No dependency on `tx.gasprice`, `block.basefee`, `block.coinbase`, `tx.origin`, or `gasleft()`. Settlement depends only on current on-chain state, quote timestamp/decay, amount, token direction, and prior state changes/collisions. | Forbidden-code policy + tests. |
| Do you inspect `tx.origin` or `block.coinbase`? | **No.** | Do not use in code; review and tests. |
| Do you use `gasleft()`? | **No.** | Do not use for pricing, branching, or settlement. |
| Do routers need to be whitelisted for optimal pricing? | **No.** Pricing is router-neutral. `msg.sender` and `recipient` do not affect price. | No router whitelist in quote math. |
| Is implementation upgradeable? How often? How notify? | **Core/quoter/hook should be immutable per version.** Router can be redeployed. Book strategy changes freeze the book and emit events. New core versions require migration events and published registry. | `ProtocolVersionDeployed`, `BookMigrated`, `StrategyModuleChanged`. |
| Pool creation event? | **Yes.** | `BookCreated`; hook path also emits `V4PoolBound`. |
| EOAs used for price updates? | Stored on-chain per book and exposed via view function/events. Deployment package must publish a JSON list. | `UpdaterSet`, `getUpdaters(bookId)`. |

---

## 9. Off-chain SDK requirements

Package names:

```text
@quay/evm-sdk
@quay/evm-abis
@quay/evm-test-vectors
```

SDK must provide:

```typescript
type LoadedBookState = {
  book: BookConfig;
  inventory: BookInventory;
  quote: QuoteState;
  blockTimestamp: bigint;
};

function quoteExactInputPure(
  state: LoadedBookState,
  tokenIn: Address,
  amountIn: bigint
): QuoteResult;

async function loadBookState(provider, bookId): Promise<LoadedBookState>;

async function getBooksForPair(provider, tokenA, tokenB): Promise<BookId[]>;

function buildSwapExactInputSingle(params: SwapExactInputParams): Hex;
```

Required SDK invariants:

```text
- SDK quote equals Solidity quote for every published test vector.
- SDK quote returns the same status codes as QuayQuoter.
- SDK never assumes token decimals; it loads them or uses registry metadata.
- SDK exposes dependency group and quote hash.
- SDK has no private endpoint dependency.
```

Test vectors:

```text
1. fresh token0 -> token1 quote
2. fresh token1 -> token0 quote
3. decayed quote
4. expired quote
5. paused book
6. max size exceeded
7. insufficient liquidity
8. oracle stale
9. oracle paused
10. collision/recompute with inventory nonce changed
```

---

## 10. Uniswap v4 hook adapter

### 10.1 Purpose

The hook adapter is a distribution adapter, not the canonical AMM.

```text
Uniswap v4 route → QuayV4HookAdapter → QuayEVMCore
```

### 10.2 Design constraints

```text
- Hook should be non-upgradeable.
- Hook should not require custom hookData for normal routing.
- PoolKey maps deterministically to bookId.
- If custom accounting / delta flags are used, submit the hook for Uniswap routing allowlist if required.
- Hook must not inspect router identity for pricing.
- Hook must use the same quote library/state as QuayQuoter.
```

### 10.3 Pool binding

```solidity
event V4PoolBound(
    bytes32 indexed poolId,
    bytes32 indexed bookId,
    address indexed hook,
    address token0,
    address token1
);
```

Binding rules:

```text
- Only one active v4 pool binding per book per fee/tickSpacing unless explicitly allowed.
- The v4 pool tokens must match book token0/token1.
- If the book is paused/migrated, hook quote returns invalid/reverts settlement.
```

### 10.4 Hook behavior

For custom-accounting implementation:

```text
beforeSwap:
  identify bookId from PoolKey
  compute quote from QuayCore/QuayQuoter state
  reject invalid quote
  return deltas to replace native v4 curve behavior

settlement/unlock callback:
  ensure input is paid to QuayCore/vault
  ensure output is made available to swapper through PoolManager accounting
  call QuayCore settlement primitive or consume a core authorization
```

Exact Uniswap v4 accounting details should be implemented against the current v4-core and v4-periphery libraries, with invariant tests against PoolManager.

---

## 11. Stock-token market-making daemon

### 11.1 Responsibilities

```text
- Subscribe to market data: Alpaca, internal feeds, CEX/OTC references as permitted.
- Read Robinhood Chain RPC state: book inventory, quotes, Chainlink feeds, token oraclePaused, multiplier events.
- Compute bid/ask/max size per stock-token/USDG book.
- Enforce risk limits off-chain before signing quote.
- Submit direct updates or signed EIP-712 updates.
- Pause books during corporate actions, stale data, exchange halts, abnormal volatility, or inventory exhaustion.
- Publish update signer list and monitoring dashboard.
```

### 11.2 Quote generation

```text
mid = market reference price adjusted for token multiplier
spread = baseSpread + volatilitySpread + inventorySpread + staleDataSpread
bid = mid * (1 - spreadBidBps / 10_000)
ask = mid * (1 + spreadAskBps / 10_000)
maxIn0/maxIn1 = min(inventory cap, risk cap, market data quality cap)
validUntil = now + maxStaleSeconds
freshUntil = now + freshSeconds
```

### 11.3 Failure modes

```text
Market data disconnected:
  stop updates; quote decays then expires.

Chainlink stale or paused:
  update quote with pause flag or set BookStatus PausedByMaker.

Corporate action pending:
  pause or publish dust max size until multiplier/reference is confirmed.

Inventory low:
  max size reduced or quote invalid due to insufficient liquidity.
```

---

## 12. Upgrade and version policy

### 12.1 Recommended policy

```text
- QuayEVMCore: immutable per version.
- QuayQuoter: immutable per version.
- QuayQuoteStore: immutable per version if possible.
- QuayV4HookAdapter: immutable.
- QuayRouter: stateless, redeployable.
- Strategy modules: immutable and versioned.
```

Avoid proxies for the core and hook. Aggregators prefer stable, inspectable implementations.

### 12.2 Migration flow

```text
1. Deploy new version contracts.
2. Emit ProtocolVersionDeployed.
3. Publish JSON registry update.
4. For each book, maker/admin calls proposeMigration.
5. Book enters Paused/Migrating status.
6. Inventory migrates or book is recreated.
7. Emit BookMigrated(oldBookId, newBookId).
8. Keep old quoter available for historical state until no active books remain.
```

Events:

```solidity
event ProtocolVersionDeployed(uint256 indexed version, address core, address quoter, address router);
event BookMigrated(bytes32 indexed oldBookId, bytes32 indexed newBookId, address newCore);
event StrategyModuleChanged(bytes32 indexed bookId, address oldModule, address newModule, uint64 effectiveAt);
```

---

## 13. Events

Minimum event set:

```solidity
event BookCreated(
    bytes32 indexed bookId,
    address indexed maker,
    address indexed token0,
    address token1,
    bytes32 liquidityGroupId,
    uint8 liquidityMode,
    address strategyModule,
    uint16 protocolFeeBps
);

event BookStatusChanged(
    bytes32 indexed bookId,
    uint8 oldStatus,
    uint8 newStatus,
    uint8 reason,
    address indexed actor,
    uint64 timestamp
);

event QuoteUpdated(
    bytes32 indexed bookId,
    uint64 nonce,
    uint64 updatedAt,
    uint64 freshUntil,
    uint64 validUntil,
    uint256 bidPxX128,
    uint256 askPxX128,
    uint128 maxIn0,
    uint128 maxIn1,
    bytes32 sourceHash
);

event UpdaterSet(
    bytes32 indexed bookId,
    address indexed updater,
    bool active
);

event LiquidityAllocated(
    bytes32 indexed bookId,
    address indexed token,
    uint256 amount,
    uint64 inventoryNonce
);

event LiquidityWithdrawn(
    bytes32 indexed bookId,
    address indexed token,
    uint256 amount,
    uint64 inventoryNonce
);

event Swap(
    bytes32 indexed bookId,
    address indexed sender,
    address indexed recipient,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint64 quoteNonce,
    uint64 inventoryNonceAfter
);

event V4PoolBound(
    bytes32 indexed poolId,
    bytes32 indexed bookId,
    address indexed hook,
    address token0,
    address token1
);
```

---

## 14. Security requirements

### 14.1 Determinism requirements

Quote and settlement must not use:

```text
- tx.origin
- block.coinbase
- tx.gasprice
- block.basefee
- gasleft()
- router whitelist checks
- recipient-dependent pricing
- msg.sender-dependent pricing, except access control for admin/updater-only functions
```

Quote and settlement may use:

```text
- block.timestamp for quote decay/expiry only
- current book inventory
- current quote state
- current book config
- current oracle state if configured
```

### 14.2 Token restrictions

V1 should support only explicit allowlisted ERC-20s.

Reject or do not list:

```text
- fee-on-transfer tokens
- rebasing tokens
- ERC-777-like callback-sensitive tokens
- tokens with transfer hooks that can alter exact balance assumptions
- non-canonical stock-token clones
```

For Robinhood Stock Tokens, use the canonical token contract registry and Chainlink feed mapping.

### 14.3 Reentrancy and settlement

```text
- Use nonReentrant on swap and inventory mutation functions.
- Recompute quote inside swap; do not trust off-chain amountOut.
- Use SafeERC20 and balance-delta checks for deposits.
- Update internal accounting after successful transfers, or use checks-effects-interactions with rollback-safe external calls.
- Never call untrusted strategy contracts during settlement in V1.
- Strategy modules should be libraries or allowlisted immutable contracts with no external side effects.
```

### 14.4 Oracle checks

```text
- latestRoundData answer must be positive.
- updatedAt must be within configured freshness bound.
- answeredInRound/round validation if applicable to feed interface.
- for stock tokens, oraclePaused() must be false.
- quote midpoint must be within maxOracleDeviationBps.
```

---

## 15. Build phases

### Phase 1: Direct Quay venue MVP

```text
Contracts:
  QuayFactory
  QuayBookRegistry
  QuayQuoteStore
  QuayEVMCore
  QuayQuoter
  QuayRouter
  QuayMulticallStateLens

Features:
  one maker
  isolated books only
  exact-input swaps
  QuoteState BBO strategy
  updater registry
  pause/status events
  TypeScript SDK

Markets:
  WETH/USDG first
  one stock-token/USDG market after oracle guards are tested
```

### Phase 2: Aggregator package

```text
Deliverables:
  ABI package
  TypeScript SDK
  quote test vectors
  deployment JSON registry
  event indexing schema
  sample integration code
  public docs answering aggregator questionnaire
```

### Phase 3: Uniswap v4 hook adapter

```text
Contracts:
  QuayV4HookAdapter

Goals:
  route Quay through Uniswap v4 PoolManager
  no custom hookData requirement for normal swaps
  non-upgradeable hook
  allowlist submission if needed
```

### Phase 4: Advanced market-maker features

```text
- multiple makers per pair
- aggregator best-of-N direct router
- shared liquidity groups with explicit dependency disclosure
- exact-output quotes
- RFQ-compatible firm quote endpoint
- maker dashboards and automated risk pause
```

---

## 16. Open implementation choices

These should be finalized before coding:

```text
1. Fee mode: input-side fee for Solana parity or output-side fee for some EVM UX.
   Recommendation: input-side fee.

2. Book ID derivation:
   Recommendation: keccak256(chainId, core, maker, token0, token1, salt).

3. Core upgradeability:
   Recommendation: immutable core, versioned redeploys.

4. Hook implementation depth:
   Recommendation: build direct core first, hook adapter second.

5. Shared liquidity:
   Recommendation: disable for routed V1; use isolated allocations.

6. Exact-output support:
   Recommendation: add after exact-input MVP.
```

---

## 17. Minimal builder checklist

A building agent should implement the following first:

```text
[ ] Solidity structs/enums/interfaces from sections 3–5.
[ ] Book creation with BookCreated event.
[ ] ERC-20 deposit, allocate, withdraw for isolated book inventory.
[ ] Updater registry and EIP-712 quote update.
[ ] Quote validation and decay math in a pure library.
[ ] QuayQuoter view wrapper returning QuoteResult, not reverting on normal invalid states.
[ ] QuayRouter swapExactInputSingle with recompute + minOut + quoteHash check.
[ ] Pause/admin/maker status controls and events.
[ ] Oracle guard interface for Chainlink + stock token oraclePaused.
[ ] Foundry tests for all aggregator questionnaire cases.
[ ] TypeScript SDK with pure quote math and test vectors.
[ ] Deployment registry JSON.
```

