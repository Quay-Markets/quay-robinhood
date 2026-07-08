// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

/// @dev Core solvency invariant: for every token, the contract's ERC-20
///      balance exactly equals the sum of all group inventories plus accrued
///      protocol fees — no value can be created or leaked by any sequence of
///      deposits, withdrawals, quote updates, swaps, and time travel.
contract InvariantTest is Test {
    QuayHandler internal handler;
    QuaySharedLiquidityAMM internal amm;

    function setUp() public {
        vm.warp(1_700_000_000);
        amm = new QuaySharedLiquidityAMM(address(this));
        handler = new QuayHandler(amm);

        amm.createLiquidityGroup(handler.GROUP1(), address(handler));
        amm.createLiquidityGroup(handler.GROUP2(), address(handler));
        handler.createBooks(address(this));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = QuayHandler.depositLiquidity.selector;
        selectors[1] = QuayHandler.withdrawLiquidity.selector;
        selectors[2] = QuayHandler.collectFees.selector;
        selectors[3] = QuayHandler.pushQuote.selector;
        selectors[4] = QuayHandler.swap.selector;
        selectors[5] = QuayHandler.warpAhead.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BalancesCoverInventoryAndFees() public view {
        for (uint256 i = 0; i < 3; i++) {
            MockERC20 token = handler.tokens(i);
            uint256 accounted = amm.inventory(handler.GROUP1(), address(token))
                + amm.inventory(handler.GROUP2(), address(token))
                + amm.protocolFees(handler.GROUP1(), address(token))
                + amm.protocolFees(handler.GROUP2(), address(token));
            assertEq(token.balanceOf(address(amm)), accounted, "balance != inventory + fees");
        }
    }

    function invariant_QuoteNoncesNeverDecrease() public view {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 bookId = handler.books(i);
            assertGe(amm.getQuoteState(bookId).nonce, handler.lastSeenNonce(bookId));
        }
    }
}

contract QuayHandler is Test {
    uint256 internal constant Q128 = 1 << 128;

    bytes32 public constant GROUP1 = keccak256("G1");
    bytes32 public constant GROUP2 = keccak256("G2");

    QuaySharedLiquidityAMM public immutable amm;
    MockERC20[3] private _tokens;
    bytes32[3] private _books;
    mapping(bytes32 bookId => uint64) public lastSeenNonce;

    address internal trader = makeAddr("trader");

    constructor(QuaySharedLiquidityAMM amm_) {
        amm = amm_;
        _tokens[0] = new MockERC20("TokenA", "TKA", 18);
        _tokens[1] = new MockERC20("TokenB", "TKB", 6);
        _tokens[2] = new MockERC20("TokenC", "TKC", 8);
    }

    function tokens(uint256 i) external view returns (MockERC20) {
        return _tokens[i];
    }

    function books(uint256 i) external view returns (bytes32) {
        return _books[i];
    }

    /// @dev Called once from setUp by the protocol owner.
    function createBooks(address protocolOwner) external {
        vm.startPrank(protocolOwner);
        _books[0] = amm.createBook(
            address(_tokens[0]), address(_tokens[1]), GROUP1, bytes32("B0"), 30, address(this)
        );
        _books[1] = amm.createBook(
            address(_tokens[2]), address(_tokens[1]), GROUP1, bytes32("B1"), 0, address(this)
        );
        _books[2] = amm.createBook(
            address(_tokens[0]), address(_tokens[2]), GROUP2, bytes32("B2"), 100, address(this)
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Fuzzed actions
    // ------------------------------------------------------------------

    function depositLiquidity(uint256 tokenSeed, uint256 groupSeed, uint256 amount) external {
        MockERC20 token = _tokens[tokenSeed % 3];
        bytes32 group = groupSeed % 2 == 0 ? GROUP1 : GROUP2;
        amount = bound(amount, 1, 1e30);
        token.mint(address(this), amount);
        token.approve(address(amm), amount);
        amm.deposit(group, address(token), amount);
    }

    function withdrawLiquidity(uint256 tokenSeed, uint256 groupSeed, uint256 amount) external {
        MockERC20 token = _tokens[tokenSeed % 3];
        bytes32 group = groupSeed % 2 == 0 ? GROUP1 : GROUP2;
        uint256 inv = amm.inventory(group, address(token));
        if (inv == 0) return;
        amount = bound(amount, 1, inv);
        amm.withdraw(group, address(token), amount, address(this));
    }

    function collectFees(uint256 tokenSeed, uint256 groupSeed) external {
        MockERC20 token = _tokens[tokenSeed % 3];
        bytes32 group = groupSeed % 2 == 0 ? GROUP1 : GROUP2;
        uint256 fees = amm.protocolFees(group, address(token));
        if (fees == 0) return;
        vm.prank(amm.owner());
        amm.withdrawProtocolFees(group, address(token), fees, address(this));
    }

    function pushQuote(uint256 bookSeed, uint256 bidRaw, uint256 spreadRaw, uint256 maxInRaw)
        external
    {
        bytes32 bookId = _books[bookSeed % 3];
        uint64 nonce = amm.getQuoteState(bookId).nonce + 1;
        uint256 bid = bound(bidRaw, Q128 / 1e9, 1e9 * Q128);
        uint256 ask = bid + bound(spreadRaw, 0, bid);
        uint128 maxIn = uint128(bound(maxInRaw, 1e6, 1e30));

        amm.updateQuote(
            bookId,
            QuaySharedLiquidityAMM.QuoteState({
                nonce: nonce,
                updatedAt: 0,
                freshUntil: uint64(block.timestamp) + 2,
                validUntil: uint64(block.timestamp) + 10,
                decayBpsPerSecond: 100,
                maxDecayBps: 500,
                bidPxX128: bid,
                askPxX128: ask,
                maxIn0: maxIn,
                maxIn1: maxIn,
                sourceHash: bytes32(bidRaw)
            })
        );
        lastSeenNonce[bookId] = nonce;
    }

    function swap(uint256 bookSeed, bool sellToken0, uint256 amountIn) external {
        bytes32 bookId = _books[bookSeed % 3];
        QuaySharedLiquidityAMM.Book memory b = amm.getBook(bookId);
        address tokenIn = sellToken0 ? b.token0 : b.token1;
        address tokenOut = sellToken0 ? b.token1 : b.token0;
        amountIn = bound(amountIn, 1, 1e30);

        QuaySharedLiquidityAMM.QuoteResult memory q = amm.quoteExactInput(bookId, tokenIn, amountIn);
        if (!q.valid) return;

        MockERC20(tokenIn).mint(trader, amountIn);
        vm.startPrank(trader);
        MockERC20(tokenIn).approve(address(amm), amountIn);
        amm.swapExactInputSingle(
            QuaySharedLiquidityAMM.SwapExactInputSingleParams({
                bookId: bookId,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: q.amountOut,
                recipient: trader,
                deadline: 0,
                expectedQuoteNonce: 0,
                expectedInventoryNonceOut: 0
            })
        );
        vm.stopPrank();
    }

    function warpAhead(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 15));
    }
}
