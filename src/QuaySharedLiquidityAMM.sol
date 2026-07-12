// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {QuayTypes} from "src/QuayTypes.sol";

/// @title QuaySharedLiquidityAMM
/// @notice Standalone propAMM venue with:
///         - independent per-book pricing
///         - optional shared liquidity groups
///         - external view quotes for aggregators
///         - standard ERC-20 transferFrom settlement, no Permit2
///
/// Price convention for each book:
///   token0/token1 book, price is token1 atoms per token0 atom, scaled by Q128.
///   - bidPxX128: taker sells token0, receives token1.
///   - askPxX128: taker sells token1, receives token0.
///   askPxX128 must be >= bidPxX128.
///
/// Shared-liquidity semantics:
///   Price state is per book and never reads other books.
///   Inventory can be shared through liquidityGroupId.
///   A swap in another book can affect whether a later quote is fillable,
///   but it cannot mutate this book's bid/ask/quote nonce.
///
/// Determinism guarantees for aggregators:
///   No tx.origin, block.coinbase, tx.gasprice, block.basefee, or gasleft().
///   block.timestamp is used only for quote freshness/decay/expiry.
///   Pricing never depends on msg.sender or recipient.
contract QuaySharedLiquidityAMM is Ownable2Step, Pausable, ReentrancyGuard, EIP712, QuayTypes {
    using SafeERC20 for IERC20;

    /// @dev Gas stipend for strategy staticcalls. Generous for pricing math but
    ///      bounds what a misbehaving module can burn per quote.
    uint256 internal constant STRATEGY_GAS_CAP = 1_000_000;

    /// @notice EIP-712 type for relayed quote updates. `updatedAt` is excluded
    ///         because the contract always stamps it with block.timestamp.
    bytes32 public constant QUOTE_UPDATE_TYPEHASH = keccak256(
        "QuoteUpdate(bytes32 bookId,uint64 nonce,uint64 freshUntil,uint64 validUntil,uint32 decayBpsPerSecond,uint32 maxDecayBps,uint256 bidPxX128,uint256 askPxX128,uint128 maxIn0,uint128 maxIn1,bytes32 sourceHash)"
    );

    enum BookStatus {
        Uninitialized,
        Active,
        Paused,
        Closed
    }

    /// @notice Lifecycle of a strategy module.
    ///         Only Approved strategies can quote or back new books. Blocking
    ///         or retiring a strategy stops quoting/swaps on its books
    ///         immediately but never touches liquidity: group owners can
    ///         always withdraw their inventory.
    enum StrategyStatus {
        None, // never registered
        Registered, // submitted by an author, awaiting owner approval
        Approved, // live
        Blocked, // disabled by the protocol owner; owner may re-approve
        Retired // permanently withdrawn by its author
    }

    struct StrategyInfo {
        address author;
        uint64 registeredAt;
        StrategyStatus status;
        /// @dev extcodehash at registration; lets reviewers pin the audited
        ///      bytecode. Modules must be non-upgradeable — a proxy keeps its
        ///      codehash while swapping implementations, so proxies are
        ///      rejected at review time.
        bytes32 codehash;
    }

    struct LiquidityGroup {
        address owner;
        bool exists;
        bool paused;
        uint64 createdAt;
    }

    struct Book {
        address token0;
        address token1;
        address strategyModule;
        bytes32 liquidityGroupId;
        uint16 protocolFeeBps;
        BookStatus status;
        uint64 createdAt;
    }

    struct QuoteResult {
        bool valid;
        QuoteReason reason;
        bytes32 bookId;
        bytes32 liquidityGroupId;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 netAmountIn;
        uint256 feeAmount;
        uint256 amountOut;
        uint256 availableOut;
        uint256 appliedPriceX128;
        uint32 appliedDecayBps;
        uint64 quoteNonce;
        uint64 updatedAt;
        uint64 freshUntil;
        uint64 validUntil;
        uint64 inventoryNonceOut;
    }

    /// @notice Optional per-book price guardrail against a Chainlink-style feed.
    /// @dev refPxX128 = feed answer * priceScale, where priceScale is chosen at
    ///      config time as Q128 * 10^token1Decimals / (10^feedDecimals * 10^token0Decimals)
    ///      so the reference lands in the book's token1-atoms-per-token0-atom units.
    struct OracleConfig {
        address feed; // address(0) disables the guard
        uint32 maxAge; // max seconds since the feed's updatedAt
        uint16 maxDeviationBps; // allowed |quote mid - ref| relative to ref
        uint256 priceScale;
    }

    struct SwapExactInputSingleParams {
        bytes32 bookId;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint64 deadline;
        /// @dev Optional. 0 means do not check.
        uint64 expectedQuoteNonce;
        /// @dev Optional. 0 means do not check. Useful when liquidity is shared.
        uint64 expectedInventoryNonceOut;
    }

    mapping(bytes32 liquidityGroupId => LiquidityGroup) public liquidityGroups;
    mapping(bytes32 bookId => Book) public books;
    mapping(bytes32 bookId => QuoteState) public quoteStates;

    /// @notice Tradable inventory allocated to a liquidity group.
    mapping(bytes32 liquidityGroupId => mapping(address token => uint256)) public inventory;

    /// @notice Input-side protocol fees held separately from tradable inventory.
    mapping(bytes32 liquidityGroupId => mapping(address token => uint256)) public protocolFees;

    /// @notice Incremented when inventory for a group/token mutates.
    mapping(bytes32 liquidityGroupId => mapping(address token => uint64)) public inventoryNonce;

    mapping(bytes32 bookId => OracleConfig) public oracleConfigs;

    /// @notice Addresses allowed to register new strategy modules.
    mapping(address author => bool) public isStrategyAuthor;

    /// @notice Owner-curated ERC-20 allowlist; books can only be created on
    ///         allowed tokens.
    mapping(address token => bool) public isTokenAllowed;
    mapping(address module => StrategyInfo) public strategies;

    mapping(bytes32 bookId => mapping(address updater => bool)) public isUpdater;
    mapping(bytes32 bookId => mapping(address updater => bool)) private updaterSeen;
    mapping(bytes32 bookId => address[]) private updaterList;

    mapping(bytes32 pairKey => bytes32[]) private booksByPair;
    bytes32[] public allBookIds;

    event LiquidityGroupCreated(bytes32 indexed liquidityGroupId, address indexed groupOwner);
    event LiquidityGroupPaused(bytes32 indexed liquidityGroupId, bool paused);

    event BookCreated(
        bytes32 indexed bookId,
        address indexed token0,
        address indexed token1,
        bytes32 liquidityGroupId,
        uint16 protocolFeeBps,
        address strategyModule,
        BookStatus status
    );

    event BookStatusChanged(
        bytes32 indexed bookId, BookStatus oldStatus, BookStatus newStatus, address indexed actor
    );
    event UpdaterSet(bytes32 indexed bookId, address indexed updater, bool active);
    event QuoteUpdateSkipped(bytes32 indexed bookId, uint256 index);
    event BookOracleSet(
        bytes32 indexed bookId,
        address indexed feed,
        uint32 maxAge,
        uint16 maxDeviationBps,
        uint256 priceScale
    );
    event StrategyAuthorSet(address indexed author, bool allowed);
    event StrategyRegistered(
        address indexed module, address indexed author, bytes32 indexed codehash
    );
    event TokenAllowedSet(address indexed token, bool allowed);
    event StrategyStatusChanged(
        address indexed module,
        StrategyStatus oldStatus,
        StrategyStatus newStatus,
        address indexed actor
    );

    event QuoteUpdated(
        bytes32 indexed bookId,
        address indexed updater,
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

    event LiquidityDeposited(
        bytes32 indexed liquidityGroupId,
        address indexed token,
        address indexed from,
        uint256 amount,
        uint256 inventoryAfter,
        uint64 inventoryNonceAfter
    );

    event LiquidityWithdrawn(
        bytes32 indexed liquidityGroupId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 inventoryAfter,
        uint64 inventoryNonceAfter
    );

    event ProtocolFeesWithdrawn(
        bytes32 indexed liquidityGroupId, address indexed token, address indexed to, uint256 amount
    );

    event Swap(
        bytes32 indexed bookId,
        bytes32 indexed liquidityGroupId,
        address indexed sender,
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 feeAmount,
        uint256 amountOut,
        uint64 quoteNonce,
        uint64 inventoryNonceOutAfter
    );

    error InvalidAddress();
    error InvalidGroup();
    error InvalidBook();
    error BookClosed();
    error NotGroupOwner();
    error NotUpdater();
    error NotSelf();
    error BadFee();
    error BadQuote();
    error BadOracleConfig();
    error ArrayLengthMismatch();
    error NotStrategyAuthor();
    error InvalidStrategy();
    error StrategyAlreadyRegistered();
    error StrategyNotRegistered();
    error StrategyNotApprovedError();
    error StrategyRetiredError();
    error StrategyApprovedError();
    error TokenNotAllowed();
    error StaleQuoteNonce();
    error DeadlineExpired();
    error QuoteInvalid(QuoteReason reason);
    error WrongTokenOut();
    error Slippage();
    error QuoteNonceMismatch();
    error InventoryNonceMismatch();
    error InsufficientInventory();
    error NonStandardToken();

    constructor(address owner_) Ownable(owner_) EIP712("QuaySharedLiquidityAMM", "1") {}

    // ---------------------------------------------------------------------
    // Admin / setup
    // ---------------------------------------------------------------------

    /// @notice Protocol-wide emergency stop. Blocks quoting and swaps.
    ///         Deposits and withdrawals stay enabled so makers can manage funds.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Strategy registry
    //
    // Three-tier governance: the owner curates who may author modules,
    // authors register immutable modules, and the owner approves each one
    // before it can quote. Blocking (owner) or retiring (author) a module
    // instantly invalidates quotes and swaps on every book that uses it,
    // but never touches liquidity: group owners can always withdraw.
    // ------------------------------------------------------------------

    function setStrategyAuthor(address author, bool allowed) external onlyOwner {
        if (author == address(0)) revert InvalidAddress();
        isStrategyAuthor[author] = allowed;
        emit StrategyAuthorSet(author, allowed);
    }

    /// @notice Submit an immutable strategy module for approval.
    function registerStrategy(address module) external {
        if (!isStrategyAuthor[msg.sender] && msg.sender != owner()) revert NotStrategyAuthor();
        if (module == address(0) || module.code.length == 0) revert InvalidStrategy();
        if (strategies[module].status != StrategyStatus.None) revert StrategyAlreadyRegistered();
        strategies[module] = StrategyInfo({
            author: msg.sender,
            registeredAt: uint64(block.timestamp),
            status: StrategyStatus.Registered,
            codehash: module.codehash
        });
        emit StrategyRegistered(module, msg.sender, module.codehash);
        emit StrategyStatusChanged(
            module, StrategyStatus.None, StrategyStatus.Registered, msg.sender
        );
    }

    /// @notice Owner approval switch. `approved = false` blocks the strategy:
    ///         every book using it stops quoting until re-approved.
    function setStrategyApproval(address module, bool approved) external onlyOwner {
        StrategyInfo storage s = strategies[module];
        if (s.status == StrategyStatus.None) revert StrategyNotRegistered();
        if (s.status == StrategyStatus.Retired) revert StrategyRetiredError();
        StrategyStatus old = s.status;
        s.status = approved ? StrategyStatus.Approved : StrategyStatus.Blocked;
        emit StrategyStatusChanged(module, old, s.status, msg.sender);
    }

    /// @notice Authors (or the owner) can permanently withdraw a module. Terminal.
    ///         An Approved module cannot be retired directly: live books rely
    ///         on it, so the owner must Block it first (giving books time to
    ///         migrate) before retirement.
    function retireStrategy(address module) external {
        StrategyInfo storage s = strategies[module];
        if (s.status == StrategyStatus.None) revert StrategyNotRegistered();
        if (msg.sender != s.author && msg.sender != owner()) revert NotStrategyAuthor();
        if (s.status == StrategyStatus.Retired) revert StrategyRetiredError();
        if (s.status == StrategyStatus.Approved) revert StrategyApprovedError();
        StrategyStatus old = s.status;
        s.status = StrategyStatus.Retired;
        emit StrategyStatusChanged(module, old, StrategyStatus.Retired, msg.sender);
    }

    // ------------------------------------------------------------------
    // Token allowlist — only canonical, hook-free, exact-transfer ERC-20s
    // may back books (design doc §14.2; also blocks fake stock-token
    // contracts on Robinhood Chain).
    // ------------------------------------------------------------------

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0) || token.code.length == 0) revert InvalidAddress();
        isTokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    function createLiquidityGroup(bytes32 liquidityGroupId, address groupOwner) external onlyOwner {
        if (liquidityGroupId == bytes32(0) || groupOwner == address(0)) revert InvalidAddress();
        if (liquidityGroups[liquidityGroupId].exists) revert InvalidGroup();

        liquidityGroups[liquidityGroupId] = LiquidityGroup({
            owner: groupOwner, exists: true, paused: false, createdAt: uint64(block.timestamp)
        });

        emit LiquidityGroupCreated(liquidityGroupId, groupOwner);
    }

    function createBook(
        address token0,
        address token1,
        bytes32 liquidityGroupId,
        bytes32 salt,
        uint16 protocolFeeBps,
        address strategyModule,
        address initialUpdater
    ) external onlyOwner returns (bytes32 bookId) {
        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            revert InvalidAddress();
        }
        if (!isTokenAllowed[token0] || !isTokenAllowed[token1]) revert TokenNotAllowed();
        if (!liquidityGroups[liquidityGroupId].exists) revert InvalidGroup();
        if (protocolFeeBps > BPS) revert BadFee();
        if (strategies[strategyModule].status != StrategyStatus.Approved) {
            revert StrategyNotApprovedError();
        }

        bookId = keccak256(
            abi.encodePacked(
                "QUAY_BOOK_V1", block.chainid, address(this), token0, token1, liquidityGroupId, salt
            )
        );
        if (books[bookId].status != BookStatus.Uninitialized) revert InvalidBook();

        books[bookId] = Book({
            token0: token0,
            token1: token1,
            strategyModule: strategyModule,
            liquidityGroupId: liquidityGroupId,
            protocolFeeBps: protocolFeeBps,
            status: BookStatus.Active,
            createdAt: uint64(block.timestamp)
        });

        allBookIds.push(bookId);
        booksByPair[_pairKey(token0, token1)].push(bookId);

        if (initialUpdater != address(0)) {
            _setUpdater(bookId, initialUpdater, true);
        }

        emit BookCreated(
            bookId,
            token0,
            token1,
            liquidityGroupId,
            protocolFeeBps,
            strategyModule,
            BookStatus.Active
        );
    }

    /// @notice Change book status. Closed is terminal: a closed book can never be reopened.
    function setBookStatus(bytes32 bookId, BookStatus newStatus)
        external
        onlyBookGroupOwnerOrProtocol(bookId)
    {
        if (newStatus == BookStatus.Uninitialized) revert InvalidBook();
        Book storage b = books[bookId];
        if (b.status == BookStatus.Uninitialized) revert InvalidBook();
        if (b.status == BookStatus.Closed) revert BookClosed();
        BookStatus old = b.status;
        b.status = newStatus;
        emit BookStatusChanged(bookId, old, newStatus, msg.sender);
    }

    function setLiquidityGroupPaused(bytes32 liquidityGroupId, bool paused_)
        external
        onlyGroupOwnerOrProtocol(liquidityGroupId)
    {
        liquidityGroups[liquidityGroupId].paused = paused_;
        emit LiquidityGroupPaused(liquidityGroupId, paused_);
    }

    function setUpdater(bytes32 bookId, address updater, bool active)
        external
        onlyBookGroupOwnerOrProtocol(bookId)
    {
        _setUpdater(bookId, updater, active);
    }

    /// @notice Attach or detach a reference-price guard for a book.
    ///         While attached, quoting requires a fresh, positive feed answer
    ///         and the quote's EFFECTIVE executed price (derived from actual
    ///         input/output, so decay and strategy skew are included) must stay
    ///         within maxDeviationBps of the scaled reference.
    ///         Protocol-owner only: the guard is a venue-level safety promise
    ///         to aggregators, so makers cannot loosen or disable it.
    function setBookOracle(
        bytes32 bookId,
        address feed,
        uint32 maxAge,
        uint16 maxDeviationBps,
        uint256 priceScale
    ) external onlyOwner {
        if (books[bookId].status == BookStatus.Uninitialized) {
            revert InvalidBook();
        }
        if (feed != address(0)) {
            bool badParams = maxAge == 0 || priceScale == 0 || maxDeviationBps == 0
                || maxDeviationBps > BPS || feed.code.length == 0;
            if (badParams) revert BadOracleConfig();
        }
        oracleConfigs[bookId] = OracleConfig({
            feed: feed, maxAge: maxAge, maxDeviationBps: maxDeviationBps, priceScale: priceScale
        });
        emit BookOracleSet(bookId, feed, maxAge, maxDeviationBps, priceScale);
    }

    function _setUpdater(bytes32 bookId, address updater, bool active) internal {
        if (updater == address(0)) revert InvalidAddress();
        if (books[bookId].status == BookStatus.Uninitialized) revert InvalidBook();
        isUpdater[bookId][updater] = active;
        if (!updaterSeen[bookId][updater]) {
            updaterSeen[bookId][updater] = true;
            updaterList[bookId].push(updater);
        }
        emit UpdaterSet(bookId, updater, active);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    function deposit(bytes32 liquidityGroupId, address token, uint256 amount)
        external
        nonReentrant
        onlyGroupOwnerOrProtocol(liquidityGroupId)
    {
        if (token == address(0) || amount == 0) revert InvalidAddress();
        _safeTransferFromExact(token, msg.sender, address(this), amount);
        inventory[liquidityGroupId][token] += amount;
        uint64 nonce = _bumpInventoryNonce(liquidityGroupId, token);
        emit LiquidityDeposited(
            liquidityGroupId, token, msg.sender, amount, inventory[liquidityGroupId][token], nonce
        );
    }

    /// @notice Group-owner only: the protocol owner must never be able to
    ///         move maker inventory (protocol fees have their own path).
    function withdraw(bytes32 liquidityGroupId, address token, uint256 amount, address to)
        external
        nonReentrant
        onlyGroupOwner(liquidityGroupId)
    {
        if (token == address(0) || to == address(0) || amount == 0) {
            revert InvalidAddress();
        }
        uint256 bal = inventory[liquidityGroupId][token];
        if (amount > bal) revert InsufficientInventory();
        inventory[liquidityGroupId][token] = bal - amount;
        uint64 nonce = _bumpInventoryNonce(liquidityGroupId, token);
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(
            liquidityGroupId, token, to, amount, inventory[liquidityGroupId][token], nonce
        );
    }

    function withdrawProtocolFees(
        bytes32 liquidityGroupId,
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0) || amount == 0) {
            revert InvalidAddress();
        }
        uint256 fees = protocolFees[liquidityGroupId][token];
        if (amount > fees) revert InsufficientInventory();
        protocolFees[liquidityGroupId][token] = fees - amount;
        IERC20(token).safeTransfer(to, amount);
        emit ProtocolFeesWithdrawn(liquidityGroupId, token, to, amount);
    }

    // ---------------------------------------------------------------------
    // Quote updates
    // ---------------------------------------------------------------------

    /// @notice Direct quote update by an authorized updater EOA.
    function updateQuote(bytes32 bookId, QuoteState calldata q) external {
        if (!isUpdater[bookId][msg.sender]) revert NotUpdater();
        _validateAndStoreQuote(bookId, q, msg.sender);
    }

    /// @notice Relay a quote update signed (EIP-712) by an authorized updater.
    ///         Anyone can submit; replay is blocked by the strictly increasing
    ///         per-book quote nonce and the domain separator.
    function updateQuoteWithSig(bytes32 bookId, QuoteState calldata q, bytes calldata signature)
        external
    {
        address signer = ECDSA.recover(hashQuoteUpdate(bookId, q), signature);
        if (!isUpdater[bookId][signer]) revert NotUpdater();
        _validateAndStoreQuote(bookId, q, signer);
    }

    /// @notice Relay several signed quote updates in one transaction.
    ///         Atomic: any invalid entry reverts the whole batch. Use this
    ///         when all quotes come from one maker's daemon.
    function batchUpdateQuotesWithSig(
        bytes32[] calldata bookIds,
        QuoteState[] calldata quotes,
        bytes[] calldata signatures
    ) external {
        if (bookIds.length != quotes.length || bookIds.length != signatures.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < bookIds.length; i++) {
            address signer = ECDSA.recover(hashQuoteUpdate(bookIds[i], quotes[i]), signatures[i]);
            if (!isUpdater[bookIds[i]][signer]) revert NotUpdater();
            _validateAndStoreQuote(bookIds[i], quotes[i], signer);
        }
    }

    /// @notice Best-effort batch relay for a shared cranker submitting quotes
    ///         signed by MANY independent makers: entries that fail (stale
    ///         nonce, bad signer, closed book, ...) are skipped instead of
    ///         reverting the batch, so one maker's bad quote cannot block the
    ///         others. Authority stays per-book via each maker's EIP-712
    ///         signature — the submitting account needs no trust at all.
    function tryBatchUpdateQuotesWithSig(
        bytes32[] calldata bookIds,
        QuoteState[] calldata quotes,
        bytes[] calldata signatures
    ) external returns (bool[] memory applied) {
        if (bookIds.length != quotes.length || bookIds.length != signatures.length) {
            revert ArrayLengthMismatch();
        }
        applied = new bool[](bookIds.length);
        for (uint256 i = 0; i < bookIds.length; i++) {
            // External self-call so each entry's validation reverts are
            // contained; other entries' state is unaffected. The callee is
            // this contract itself, so no third party can reenter between
            // the call and the skip event.
            // slither-disable-next-line reentrancy-events,calls-loop
            try this.updateQuoteWithSig(bookIds[i], quotes[i], signatures[i]) {
                applied[i] = true;
            } catch {
                emit QuoteUpdateSkipped(bookIds[i], i);
            }
        }
    }

    /// @notice Cheapest shared-infra path: no signatures at all. Makers who
    ///         opt into a venue-operated cranker authorize its account via
    ///         setUpdater(bookId, cranker, true) — revocable per book at any
    ///         time — and the cranker batches their quotes directly. Entries
    ///         where msg.sender is not (or no longer) an authorized updater,
    ///         or that fail validation, are skipped and evented, so makers
    ///         joining/leaving the shared account never block each other.
    ///         Run as many cranker accounts as throughput needs: overlapping
    ///         submissions degrade to stale-nonce skips, never reverts.
    function tryBatchUpdateQuotes(bytes32[] calldata bookIds, QuoteState[] calldata quotes)
        external
        returns (bool[] memory applied)
    {
        if (bookIds.length != quotes.length) revert ArrayLengthMismatch();
        applied = new bool[](bookIds.length);
        for (uint256 i = 0; i < bookIds.length; i++) {
            if (!isUpdater[bookIds[i]][msg.sender]) {
                emit QuoteUpdateSkipped(bookIds[i], i);
                continue;
            }
            // External self-call so each entry's validation reverts are
            // contained. Callee is this contract itself: no third-party
            // reentry between the call and the skip event.
            // slither-disable-next-line reentrancy-events,calls-loop
            try this.selfStoreQuote(bookIds[i], quotes[i], msg.sender) {
                applied[i] = true;
            } catch {
                emit QuoteUpdateSkipped(bookIds[i], i);
            }
        }
    }

    /// @notice Internal mechanics of tryBatchUpdateQuotes, exposed only so a
    ///         self-call can contain per-entry reverts. Callable by the venue
    ///         itself exclusively; authorization was checked by the caller.
    function selfStoreQuote(bytes32 bookId, QuoteState calldata q, address updater) external {
        if (msg.sender != address(this)) revert NotSelf();
        _validateAndStoreQuote(bookId, q, updater);
    }

    /// @notice EIP-712 digest an updater must sign for updateQuoteWithSig.
    ///         q.updatedAt is not part of the digest; the contract stamps it.
    function hashQuoteUpdate(bytes32 bookId, QuoteState calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_UPDATE_TYPEHASH,
                    bookId,
                    q.nonce,
                    q.freshUntil,
                    q.validUntil,
                    q.decayBpsPerSecond,
                    q.maxDecayBps,
                    q.bidPxX128,
                    q.askPxX128,
                    q.maxIn0,
                    q.maxIn1,
                    q.sourceHash
                )
            )
        );
    }

    function _validateAndStoreQuote(bytes32 bookId, QuoteState calldata q, address updater)
        internal
    {
        BookStatus st = books[bookId].status;
        if (st == BookStatus.Uninitialized) revert InvalidBook();
        // Closed is terminal: no more quote events. Paused books may keep
        // streaming so prices are warm when the maker unpauses.
        if (st == BookStatus.Closed) revert BookClosed();
        if (q.bidPxX128 == 0 || q.askPxX128 < q.bidPxX128) revert BadQuote();
        if (q.freshUntil > q.validUntil) revert BadQuote();
        if (q.validUntil < block.timestamp) revert BadQuote();
        if (q.maxDecayBps > MAX_DECAY_BPS) revert BadQuote();
        if (q.nonce <= quoteStates[bookId].nonce) revert StaleQuoteNonce();
        if (q.maxIn0 == 0 || q.maxIn1 == 0) revert BadQuote();

        QuoteState storage s = quoteStates[bookId];
        s.nonce = q.nonce;
        s.updatedAt = uint64(block.timestamp);
        s.freshUntil = q.freshUntil;
        s.validUntil = q.validUntil;
        s.decayBpsPerSecond = q.decayBpsPerSecond;
        s.maxDecayBps = q.maxDecayBps;
        s.bidPxX128 = q.bidPxX128;
        s.askPxX128 = q.askPxX128;
        s.maxIn0 = q.maxIn0;
        s.maxIn1 = q.maxIn1;
        s.sourceHash = q.sourceHash;

        emit QuoteUpdated(
            bookId,
            updater,
            s.nonce,
            s.updatedAt,
            s.freshUntil,
            s.validUntil,
            s.bidPxX128,
            s.askPxX128,
            s.maxIn0,
            s.maxIn1,
            s.sourceHash
        );
    }

    // ---------------------------------------------------------------------
    // Aggregator-facing views
    // ---------------------------------------------------------------------

    function quoteExactInput(bytes32 bookId, address tokenIn, uint256 amountIn)
        external
        view
        returns (QuoteResult memory)
    {
        return _quoteExactInput(bookId, tokenIn, amountIn);
    }

    function quoteBestExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (QuoteResult memory best)
    {
        bytes32[] storage ids = booksByPair[_pairKey(tokenIn, tokenOut)];
        best.reason = QuoteReason.BookMissing;
        best.tokenIn = tokenIn;
        best.tokenOut = tokenOut;
        best.amountIn = amountIn;

        for (uint256 i = 0; i < ids.length; i++) {
            QuoteResult memory r = _quoteExactInput(ids[i], tokenIn, amountIn);
            if (r.valid && r.tokenOut == tokenOut && r.amountOut > best.amountOut) {
                best = r;
            }
        }
    }

    function batchQuoteExactInput(bytes32[] calldata bookIds, address tokenIn, uint256 amountIn)
        external
        view
        returns (QuoteResult[] memory results)
    {
        results = new QuoteResult[](bookIds.length);
        for (uint256 i = 0; i < bookIds.length; i++) {
            results[i] = _quoteExactInput(bookIds[i], tokenIn, amountIn);
        }
    }

    /// @notice Paginated variant of quoteBestExactInput for pairs with many
    ///         books; scans ids[start .. start+limit). Serious routers should
    ///         instead pick candidates off-chain via getBooksForPair +
    ///         getBookStates + batchQuoteExactInput.
    function quoteBestExactInputPaged(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 start,
        uint256 limit
    ) external view returns (QuoteResult memory best) {
        bytes32[] storage ids = booksByPair[_pairKey(tokenIn, tokenOut)];
        best.reason = QuoteReason.BookMissing;
        best.tokenIn = tokenIn;
        best.tokenOut = tokenOut;
        best.amountIn = amountIn;

        uint256 end = start + limit;
        if (end > ids.length) end = ids.length;
        for (uint256 i = start; i < end; i++) {
            QuoteResult memory r = _quoteExactInput(ids[i], tokenIn, amountIn);
            if (r.valid && r.tokenOut == tokenOut && r.amountOut > best.amountOut) {
                best = r;
            }
        }
    }

    function getBooksForPair(address tokenA, address tokenB)
        external
        view
        returns (bytes32[] memory)
    {
        return booksByPair[_pairKey(tokenA, tokenB)];
    }

    function getAllBookIds() external view returns (bytes32[] memory) {
        return allBookIds;
    }

    /// @notice Historical list: every updater ever set for the book,
    ///         including deactivated ones. Use getActiveUpdaters for the
    ///         "which EOAs push prices" aggregator question.
    function getUpdaters(bytes32 bookId) external view returns (address[] memory) {
        return updaterList[bookId];
    }

    /// @notice Currently authorized updater EOAs for a book.
    function getActiveUpdaters(bytes32 bookId) external view returns (address[] memory active) {
        address[] storage all = updaterList[bookId];

        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (isUpdater[bookId][all[i]]) count++;
        }

        active = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (isUpdater[bookId][all[i]]) {
                active[j++] = all[i];
            }
        }
    }

    function getQuoteState(bytes32 bookId) external view returns (QuoteState memory) {
        return quoteStates[bookId];
    }

    function getBook(bytes32 bookId) external view returns (Book memory) {
        return books[bookId];
    }

    /// @notice Minimal aggregator-shaped quote: token addresses + amount in,
    ///         amount out back. Scans every book for the pair and returns the
    ///         best fillable quote (0 if none). Pair with swapExactInputSingle
    ///         on the returned bookId; funds move via plain ERC-20
    ///         transferFrom — no Permit2.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, bytes32 bookId)
    {
        QuoteResult memory best = quoteBestExactInput(tokenIn, tokenOut, amountIn);
        if (best.valid) return (best.amountOut, best.bookId);
        return (0, bytes32(0));
    }

    /// @notice Everything an off-chain SDK needs to price a book, in one call.
    struct BookStateView {
        Book book;
        QuoteState quote;
        OracleConfig oracle;
        StrategyStatus strategyStatus;
        bool groupPaused;
        bool protocolPaused;
        uint256 inventory0;
        uint256 inventory1;
        uint64 inventoryNonce0;
        uint64 inventoryNonce1;
    }

    function getBookState(bytes32 bookId) public view returns (BookStateView memory v) {
        Book storage b = books[bookId];
        v.book = b;
        v.quote = quoteStates[bookId];
        v.oracle = oracleConfigs[bookId];
        v.strategyStatus = strategies[b.strategyModule].status;
        v.groupPaused = liquidityGroups[b.liquidityGroupId].paused;
        v.protocolPaused = paused();
        v.inventory0 = inventory[b.liquidityGroupId][b.token0];
        v.inventory1 = inventory[b.liquidityGroupId][b.token1];
        v.inventoryNonce0 = inventoryNonce[b.liquidityGroupId][b.token0];
        v.inventoryNonce1 = inventoryNonce[b.liquidityGroupId][b.token1];
    }

    function getBookStates(bytes32[] calldata bookIds)
        external
        view
        returns (BookStateView[] memory views)
    {
        views = new BookStateView[](bookIds.length);
        for (uint256 i = 0; i < bookIds.length; i++) {
            views[i] = getBookState(bookIds[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Swaps: standard ERC-20 transferFrom, no Permit2
    // ---------------------------------------------------------------------

    function swapExactInputSingle(SwapExactInputSingleParams calldata p)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (p.deadline != 0 && block.timestamp > p.deadline) revert DeadlineExpired();
        if (p.recipient == address(0)) revert InvalidAddress();

        QuoteResult memory q = _quoteExactInput(p.bookId, p.tokenIn, p.amountIn);
        if (!q.valid) revert QuoteInvalid(q.reason);
        if (q.tokenOut != p.tokenOut) revert WrongTokenOut();
        if (q.amountOut < p.minAmountOut) revert Slippage();
        if (p.expectedQuoteNonce != 0 && q.quoteNonce != p.expectedQuoteNonce) {
            revert QuoteNonceMismatch();
        }
        if (p.expectedInventoryNonceOut != 0 && q.inventoryNonceOut != p.expectedInventoryNonceOut)
        {
            revert InventoryNonceMismatch();
        }

        bytes32 groupId = q.liquidityGroupId;

        _safeTransferFromExact(p.tokenIn, msg.sender, address(this), p.amountIn);

        // Update internal accounting before the output transfer. ReentrancyGuard
        // prevents callback-style reentry from non-standard tokens.
        inventory[groupId][p.tokenIn] += q.netAmountIn;
        protocolFees[groupId][p.tokenIn] += q.feeAmount;
        inventory[groupId][p.tokenOut] -= q.amountOut;

        _bumpInventoryNonce(groupId, p.tokenIn);
        uint64 outNonce = _bumpInventoryNonce(groupId, p.tokenOut);

        IERC20(p.tokenOut).safeTransfer(p.recipient, q.amountOut);

        emit Swap(
            p.bookId,
            groupId,
            msg.sender,
            p.recipient,
            p.tokenIn,
            p.tokenOut,
            p.amountIn,
            q.feeAmount,
            q.amountOut,
            q.quoteNonce,
            outNonce
        );

        amountOut = q.amountOut;
    }

    // ---------------------------------------------------------------------
    // Internal quote math
    // ---------------------------------------------------------------------

    function _quoteExactInput(bytes32 bookId, address tokenIn, uint256 amountIn)
        internal
        view
        returns (QuoteResult memory r)
    {
        r = _quoteExactInputNoInventoryCheck(bookId, tokenIn, amountIn);
        if (!r.valid) return r;

        uint256 available = inventory[r.liquidityGroupId][r.tokenOut];
        r.availableOut = available;
        if (r.amountOut > available) {
            r.valid = false;
            r.reason = QuoteReason.InsufficientLiquidity;
            r.amountOut = 0;
            return r;
        }
    }

    function _quoteExactInputNoInventoryCheck(bytes32 bookId, address tokenIn, uint256 amountIn)
        internal
        view
        returns (QuoteResult memory r)
    {
        r.bookId = bookId;
        r.tokenIn = tokenIn;
        r.amountIn = amountIn;

        if (paused()) return _invalid(r, QuoteReason.ProtocolPaused);

        Book storage b = books[bookId];
        if (b.status == BookStatus.Uninitialized) return _invalid(r, QuoteReason.BookMissing);
        if (b.status != BookStatus.Active) return _invalid(r, QuoteReason.BookNotActive);

        LiquidityGroup storage g = liquidityGroups[b.liquidityGroupId];
        if (!g.exists) return _invalid(r, QuoteReason.GroupMissing);
        if (g.paused) return _invalid(r, QuoteReason.GroupPaused);

        r.liquidityGroupId = b.liquidityGroupId;

        bool token0In;
        if (tokenIn == b.token0) {
            token0In = true;
            r.tokenOut = b.token1;
        } else if (tokenIn == b.token1) {
            token0In = false;
            r.tokenOut = b.token0;
        } else {
            return _invalid(r, QuoteReason.WrongToken);
        }

        if (amountIn == 0) return _invalid(r, QuoteReason.AmountZero);

        QuoteState storage q = quoteStates[bookId];
        if (q.nonce == 0) return _invalid(r, QuoteReason.QuoteMissing);
        if (block.timestamp > q.validUntil) return _invalid(r, QuoteReason.QuoteExpired);

        if (strategies[b.strategyModule].status != StrategyStatus.Approved) {
            return _invalid(r, QuoteReason.StrategyNotApproved);
        }

        // Oracle guard, part 1: resolve the reference price up front so a
        // dead/stale feed fails fast, before the strategy runs.
        uint256 refPxX128 = 0;
        {
            OracleConfig storage oc = oracleConfigs[bookId];
            if (oc.feed != address(0)) {
                QuoteReason oracleReason;
                (refPxX128, oracleReason) = _oracleReference(oc);
                if (oracleReason != QuoteReason.OK) return _invalid(r, oracleReason);
            }
        }

        r.quoteNonce = q.nonce;
        r.updatedAt = q.updatedAt;
        r.freshUntil = q.freshUntil;
        r.validUntil = q.validUntil;
        r.inventoryNonceOut = inventoryNonce[b.liquidityGroupId][r.tokenOut];

        r.feeAmount = Math.mulDiv(amountIn, uint256(b.protocolFeeBps), uint256(BPS));
        r.netAmountIn = amountIn - r.feeAmount;

        // Pricing is delegated to the book's approved strategy module via a
        // gas-capped staticcall: it cannot write state or move funds, and a
        // reverting module degrades to an invalid quote instead of bricking
        // the quoter.
        // slither-disable-next-line calls-loop
        try IQuayStrategy(b.strategyModule).quoteExactInput{gas: STRATEGY_GAS_CAP}(
            bookId, q, token0In, amountIn, r.netAmountIn, inventory[b.liquidityGroupId][r.tokenOut]
        ) returns (
            uint256 amountOut,
            uint256 appliedPriceX128,
            uint32 appliedDecayBps,
            QuoteReason strategyReason
        ) {
            if (strategyReason != QuoteReason.OK) {
                return _invalid(r, strategyReason);
            }
            r.amountOut = amountOut;
            r.appliedPriceX128 = appliedPriceX128;
            r.appliedDecayBps = appliedDecayBps;
        } catch {
            return _invalid(r, QuoteReason.StrategyError);
        }

        if (r.amountOut == 0) return _invalid(r, QuoteReason.ZeroOutput);

        // Oracle guard, part 2: bound the EFFECTIVE executed price, derived in
        // the core from actual net input and output. This covers quote decay
        // and any strategy-level skew — the module's self-reported
        // appliedPriceX128 is diagnostics only, never trusted for safety.
        if (refPxX128 != 0) {
            uint256 effectivePxX128 = token0In
                ? Math.mulDiv(r.amountOut, Q128, r.netAmountIn)
                : Math.mulDiv(r.netAmountIn, Q128, r.amountOut);
            uint16 dev = oracleConfigs[bookId].maxDeviationBps;
            uint256 minPx = Math.mulDiv(refPxX128, uint256(BPS) - dev, uint256(BPS));
            uint256 maxPx = Math.mulDiv(refPxX128, uint256(BPS) + dev, uint256(BPS));
            if (effectivePxX128 < minPx || effectivePxX128 > maxPx) {
                return _invalid(r, QuoteReason.OracleDeviation);
            }
        }

        r.valid = true;
        r.reason = QuoteReason.OK;
    }

    /// @dev Reads the feed and returns the scaled reference price. Returns a
    ///      QuoteReason instead of reverting so the quoter stays non-reverting.
    ///      Rejects zero/future feed timestamps; staleness uses subtraction to
    ///      avoid any addition overflow.
    function _oracleReference(OracleConfig storage oc)
        internal
        view
        returns (uint256 refPxX128, QuoteReason)
    {
        // roundId/startedAt/answeredInRound are unused by design; staleness is
        // enforced through updatedAt + maxAge instead of round accounting.
        // slither-disable-next-line unused-return,calls-loop
        try AggregatorV3Interface(oc.feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 feedUpdatedAt, uint80
        ) {
            if (answer <= 0) return (0, QuoteReason.OracleInvalid);
            if (feedUpdatedAt == 0 || feedUpdatedAt > block.timestamp) {
                return (0, QuoteReason.OracleInvalid);
            }
            if (block.timestamp - feedUpdatedAt > oc.maxAge) {
                return (0, QuoteReason.OracleStale);
            }

            // casting to 'uint256' is safe: answer > 0 was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 unsignedAnswer = uint256(answer);
            if (unsignedAnswer > type(uint256).max / oc.priceScale) {
                return (0, QuoteReason.OracleInvalid);
            }
            refPxX128 = unsignedAnswer * oc.priceScale;
            if (refPxX128 == 0) return (0, QuoteReason.OracleInvalid);
            return (refPxX128, QuoteReason.OK);
        } catch {
            return (0, QuoteReason.OracleInvalid);
        }
    }

    function _invalid(QuoteResult memory r, QuoteReason reason)
        internal
        pure
        returns (QuoteResult memory)
    {
        r.valid = false;
        r.reason = reason;
        r.amountOut = 0;
        return r;
    }

    function _safeTransferFromExact(address token, address from, address to, uint256 amount)
        internal
    {
        uint256 beforeBal = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        uint256 received = IERC20(token).balanceOf(to) - beforeBal;
        if (received != amount) revert NonStandardToken();
    }

    function _bumpInventoryNonce(bytes32 liquidityGroupId, address token)
        internal
        returns (uint64 nonce)
    {
        nonce = inventoryNonce[liquidityGroupId][token] + 1;
        inventoryNonce[liquidityGroupId][token] = nonce;
    }

    function _pairKey(address a, address b) internal pure returns (bytes32) {
        return uint160(a) < uint160(b)
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    modifier onlyGroupOwner(bytes32 liquidityGroupId) {
        LiquidityGroup storage g = liquidityGroups[liquidityGroupId];
        if (!g.exists) revert InvalidGroup();
        if (msg.sender != g.owner) revert NotGroupOwner();
        _;
    }

    modifier onlyGroupOwnerOrProtocol(bytes32 liquidityGroupId) {
        LiquidityGroup storage g = liquidityGroups[liquidityGroupId];
        if (!g.exists) revert InvalidGroup();
        if (msg.sender != g.owner && msg.sender != owner()) revert NotGroupOwner();
        _;
    }

    modifier onlyBookGroupOwnerOrProtocol(bytes32 bookId) {
        Book storage b = books[bookId];
        if (b.status == BookStatus.Uninitialized) revert InvalidBook();
        LiquidityGroup storage g = liquidityGroups[b.liquidityGroupId];
        if (!g.exists) revert InvalidGroup();
        if (msg.sender != g.owner && msg.sender != owner()) revert NotGroupOwner();
        _;
    }
}
