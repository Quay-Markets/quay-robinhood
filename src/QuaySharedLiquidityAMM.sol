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
contract QuaySharedLiquidityAMM is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    uint256 public constant Q128 = 1 << 128;
    uint16 public constant BPS = 10_000;
    uint32 public constant MAX_DECAY_BPS = 9999;

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

    enum QuoteReason {
        OK,
        BookMissing,
        BookNotActive,
        GroupMissing,
        GroupPaused,
        WrongToken,
        AmountZero,
        QuoteMissing,
        QuoteExpired,
        BadPrices,
        SizeExceeded,
        ZeroOutput,
        InsufficientLiquidity,
        ProtocolPaused,
        OracleInvalid,
        OracleStale,
        OracleDeviation
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
        bytes32 liquidityGroupId;
        uint16 protocolFeeBps;
        BookStatus status;
        uint64 createdAt;
    }

    struct QuoteState {
        uint64 nonce;
        uint64 updatedAt;
        uint64 freshUntil;
        uint64 validUntil;
        uint32 decayBpsPerSecond;
        uint32 maxDecayBps;
        uint256 bidPxX128;
        uint256 askPxX128;
        uint128 maxIn0;
        uint128 maxIn1;
        bytes32 sourceHash;
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
        BookStatus status
    );

    event BookStatusChanged(
        bytes32 indexed bookId, BookStatus oldStatus, BookStatus newStatus, address indexed actor
    );
    event UpdaterSet(bytes32 indexed bookId, address indexed updater, bool active);
    event BookOracleSet(
        bytes32 indexed bookId,
        address indexed feed,
        uint32 maxAge,
        uint16 maxDeviationBps,
        uint256 priceScale
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
    error BadFee();
    error BadQuote();
    error BadOracleConfig();
    error ArrayLengthMismatch();
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
        address initialUpdater
    ) external onlyOwner returns (bytes32 bookId) {
        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            revert InvalidAddress();
        }
        if (!liquidityGroups[liquidityGroupId].exists) revert InvalidGroup();
        if (protocolFeeBps > BPS) revert BadFee();

        bookId = keccak256(
            abi.encodePacked(
                "QUAY_BOOK_V1", block.chainid, address(this), token0, token1, liquidityGroupId, salt
            )
        );
        if (books[bookId].status != BookStatus.Uninitialized) revert InvalidBook();

        books[bookId] = Book({
            token0: token0,
            token1: token1,
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
            bookId, token0, token1, liquidityGroupId, protocolFeeBps, BookStatus.Active
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
    ///         whose scaled price is within maxDeviationBps of the quote mid.
    function setBookOracle(
        bytes32 bookId,
        address feed,
        uint32 maxAge,
        uint16 maxDeviationBps,
        uint256 priceScale
    ) external onlyBookGroupOwnerOrProtocol(bookId) {
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

    function withdraw(bytes32 liquidityGroupId, address token, uint256 amount, address to)
        external
        nonReentrant
        onlyGroupOwnerOrProtocol(liquidityGroupId)
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
        _validateAndStoreQuote(bookId, q);
    }

    /// @notice Relay a quote update signed (EIP-712) by an authorized updater.
    ///         Anyone can submit; replay is blocked by the strictly increasing
    ///         per-book quote nonce and the domain separator.
    function updateQuoteWithSig(bytes32 bookId, QuoteState calldata q, bytes calldata signature)
        external
    {
        address signer = ECDSA.recover(hashQuoteUpdate(bookId, q), signature);
        if (!isUpdater[bookId][signer]) revert NotUpdater();
        _validateAndStoreQuote(bookId, q);
    }

    /// @notice Relay several signed quote updates in one transaction.
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
            _validateAndStoreQuote(bookIds[i], quotes[i]);
        }
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

    function _validateAndStoreQuote(bytes32 bookId, QuoteState calldata q) internal {
        if (books[bookId].status == BookStatus.Uninitialized) revert InvalidBook();
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
        external
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

    /// @notice Diagnostic quote that ignores the inventory check when liquidity is
    ///         insufficient, so SDKs can still display the theoretical price.
    ///         A result can therefore be valid=true while availableOut < amountOut;
    ///         it must never be used to build a swap.
    function quotePriceOnly(bytes32 bookId, address tokenIn, uint256 amountIn)
        external
        view
        returns (QuoteResult memory r)
    {
        r = _quoteExactInput(bookId, tokenIn, amountIn);
        if (r.reason == QuoteReason.InsufficientLiquidity) {
            r = _quoteExactInputNoInventoryCheck(bookId, tokenIn, amountIn);
            r.availableOut = inventory[r.liquidityGroupId][r.tokenOut];
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

    function getUpdaters(bytes32 bookId) external view returns (address[] memory) {
        return updaterList[bookId];
    }

    function getQuoteState(bytes32 bookId) external view returns (QuoteState memory) {
        return quoteStates[bookId];
    }

    function getBook(bytes32 bookId) external view returns (Book memory) {
        return books[bookId];
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
        if (q.bidPxX128 == 0 || q.askPxX128 < q.bidPxX128) {
            return _invalid(r, QuoteReason.BadPrices);
        }

        OracleConfig storage oc = oracleConfigs[bookId];
        if (oc.feed != address(0)) {
            QuoteReason oracleReason = _checkOracle(oc, q);
            if (oracleReason != QuoteReason.OK) return _invalid(r, oracleReason);
        }

        if (token0In && amountIn > uint256(q.maxIn0)) return _invalid(r, QuoteReason.SizeExceeded);
        if (!token0In && amountIn > uint256(q.maxIn1)) {
            return _invalid(r, QuoteReason.SizeExceeded);
        }

        r.quoteNonce = q.nonce;
        r.updatedAt = q.updatedAt;
        r.freshUntil = q.freshUntil;
        r.validUntil = q.validUntil;
        r.inventoryNonceOut = inventoryNonce[b.liquidityGroupId][r.tokenOut];

        r.appliedDecayBps = _appliedDecayBps(q);
        r.feeAmount = Math.mulDiv(amountIn, uint256(b.protocolFeeBps), uint256(BPS));
        r.netAmountIn = amountIn - r.feeAmount;

        if (token0In) {
            // User sells token0 at the bid. Decay worsens by lowering bid.
            uint256 decay = uint256(r.appliedDecayBps);
            uint256 bid = Math.mulDiv(q.bidPxX128, uint256(BPS) - decay, uint256(BPS));
            r.appliedPriceX128 = bid;
            r.amountOut = Math.mulDiv(r.netAmountIn, bid, Q128);
        } else {
            // User sells token1 at the ask. Decay worsens by raising ask.
            uint256 decay = uint256(r.appliedDecayBps);
            uint256 ask = Math.mulDiv(q.askPxX128, uint256(BPS) + decay, uint256(BPS));
            r.appliedPriceX128 = ask;
            r.amountOut = Math.mulDiv(r.netAmountIn, Q128, ask);
        }

        if (r.amountOut == 0) return _invalid(r, QuoteReason.ZeroOutput);

        r.valid = true;
        r.reason = QuoteReason.OK;
    }

    /// @dev Compares the undecayed quote midpoint against the scaled feed price.
    ///      Returns a QuoteReason instead of reverting so the quoter stays
    ///      non-reverting for aggregators.
    function _checkOracle(OracleConfig storage oc, QuoteState storage q)
        internal
        view
        returns (QuoteReason)
    {
        // roundId/startedAt/answeredInRound are unused by design; staleness is
        // enforced through updatedAt + maxAge instead of round accounting.
        // slither-disable-next-line unused-return,calls-loop
        try AggregatorV3Interface(oc.feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 feedUpdatedAt, uint80
        ) {
            if (answer <= 0) return QuoteReason.OracleInvalid;
            if (block.timestamp > feedUpdatedAt + oc.maxAge) return QuoteReason.OracleStale;

            // casting to 'uint256' is safe: answer > 0 was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 unsignedAnswer = uint256(answer);
            if (unsignedAnswer > type(uint256).max / oc.priceScale) {
                return QuoteReason.OracleInvalid;
            }
            uint256 refPxX128 = unsignedAnswer * oc.priceScale;
            if (refPxX128 == 0) return QuoteReason.OracleInvalid;

            // Half-then-add avoids overflow; the at-most-1 rounding loss is
            // negligible against Q128 price magnitudes.
            uint256 midPxX128 = q.bidPxX128 / 2 + q.askPxX128 / 2;
            uint256 deviation =
                midPxX128 > refPxX128 ? midPxX128 - refPxX128 : refPxX128 - midPxX128;
            if (deviation > Math.mulDiv(refPxX128, oc.maxDeviationBps, BPS)) {
                return QuoteReason.OracleDeviation;
            }
            return QuoteReason.OK;
        } catch {
            return QuoteReason.OracleInvalid;
        }
    }

    function _appliedDecayBps(QuoteState storage q) internal view returns (uint32) {
        if (block.timestamp <= q.freshUntil) return 0;
        uint256 elapsed = block.timestamp - q.freshUntil;
        uint256 decay = elapsed * q.decayBpsPerSecond;
        if (decay > q.maxDecayBps) decay = q.maxDecayBps;
        // casting to 'uint32' is safe: decay is capped at q.maxDecayBps, a uint32
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(decay);
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
