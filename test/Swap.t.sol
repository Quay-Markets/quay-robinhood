// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {FeeOnTransferERC20} from "test/utils/FeeOnTransferERC20.sol";
import {ReentrantERC20, ITransferHook} from "test/utils/ReentrantERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SwapTest is QuayTestBase {
    function test_Swap_SellToken0() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), 1e18);

        uint256 invWethBefore = amm.inventory(GROUP_MAIN, address(weth));
        uint256 invUsdcBefore = amm.inventory(GROUP_MAIN, address(usdc));
        uint64 inNonceBefore = amm.inventoryNonce(GROUP_MAIN, address(weth));
        uint64 outNonceBefore = amm.inventoryNonce(GROUP_MAIN, address(usdc));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, q.amountOut);

        weth.mint(taker, 1e18);
        vm.startPrank(taker);
        weth.approve(address(amm), 1e18);
        vm.expectEmit(true, true, true, true, address(amm));
        emit QuaySharedLiquidityAMM.Swap(
            wethBook,
            GROUP_MAIN,
            taker,
            recipient,
            address(weth),
            address(usdc),
            1e18,
            q.feeAmount,
            q.amountOut,
            q.quoteNonce,
            outNonceBefore + 1
        );
        uint256 out = amm.swapExactInputSingle(p);
        vm.stopPrank();

        assertEq(out, q.amountOut);
        assertEq(weth.balanceOf(taker), 0);
        assertEq(usdc.balanceOf(recipient), q.amountOut);

        // Inventory: input grows by net, fee accrues separately, output shrinks.
        assertEq(amm.inventory(GROUP_MAIN, address(weth)), invWethBefore + q.netAmountIn);
        assertEq(amm.protocolFees(GROUP_MAIN, address(weth)), q.feeAmount);
        assertEq(amm.inventory(GROUP_MAIN, address(usdc)), invUsdcBefore - q.amountOut);
        assertEq(amm.inventoryNonce(GROUP_MAIN, address(weth)), inNonceBefore + 1);
        assertEq(amm.inventoryNonce(GROUP_MAIN, address(usdc)), outNonceBefore + 1);

        // Contract balances always cover inventory + fees.
        assertEq(
            weth.balanceOf(address(amm)),
            amm.inventory(GROUP_MAIN, address(weth)) + amm.protocolFees(GROUP_MAIN, address(weth))
        );
        assertEq(usdc.balanceOf(address(amm)), amm.inventory(GROUP_MAIN, address(usdc)));
    }

    function test_Swap_SellToken1() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(usdc), 2001e6);
        uint256 out = _swapAs(
            taker, _swapParams(wethBook, address(usdc), address(weth), 2001e6, q.amountOut)
        );
        assertEq(out, q.amountOut);
        assertApproxEqAbs(out, 997e15, 1);
        assertEq(weth.balanceOf(recipient), out);
    }

    function test_Swap_MatchesQuoteExactly() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(mathBook, address(math0), 3e18);
        uint256 out = _swapAs(taker, _swapParams(mathBook, address(math0), address(math1), 3e18, 0));
        assertEq(out, q.amountOut);
        assertEq(out, 300e18);
    }

    function test_Swap_DecayedQuoteGivesDecayedAmount() public {
        vm.warp(START + FRESH_SECONDS + 3); // 300 bps decay
        uint256 out = _swapAs(taker, _swapParams(mathBook, address(math0), address(math1), 1e18, 0));
        assertEq(out, 97e18);
    }

    function test_Swap_RecipientCanBeSender() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(mathBook, address(math0), address(math1), 1e18, 0);
        p.recipient = taker;
        _swapAs(taker, p);
        assertEq(math1.balanceOf(taker), 100e18);
    }

    function test_Swap_NonceGuardsPassWhenMatching() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        p.expectedQuoteNonce = q.quoteNonce;
        p.expectedInventoryNonceOut = q.inventoryNonceOut;
        uint256 out = _swapAs(taker, p);
        assertEq(out, q.amountOut);
    }

    // ------------------------------------------------------------------
    // Reverts
    // ------------------------------------------------------------------

    function test_Swap_RevertDeadlineExpired() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        p.deadline = uint64(block.timestamp) - 1;
        vm.expectRevert(QuaySharedLiquidityAMM.DeadlineExpired.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_DeadlineNowOrZeroAllowed() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(mathBook, address(math0), address(math1), 1e18, 0);
        p.deadline = uint64(block.timestamp);
        _swapAs(taker, p);

        p.deadline = 0; // 0 disables the check
        _swapAs(taker, p);
    }

    function test_Swap_RevertZeroRecipient() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        p.recipient = address(0);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertQuoteInvalid() public {
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector,
                QuaySharedLiquidityAMM.QuoteReason.BookNotActive
            )
        );
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertExpiredQuote() public {
        vm.warp(START + VALID_SECONDS + 1);
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector,
                QuaySharedLiquidityAMM.QuoteReason.QuoteExpired
            )
        );
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertWrongTokenOut() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(weth), 1e18, 0);
        vm.expectRevert(QuaySharedLiquidityAMM.WrongTokenOut.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertSlippage() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, q.amountOut + 1);
        vm.expectRevert(QuaySharedLiquidityAMM.Slippage.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertQuoteNonceMismatch() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        p.expectedQuoteNonce = 99;
        vm.expectRevert(QuaySharedLiquidityAMM.QuoteNonceMismatch.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertInventoryNonceMismatch() public {
        QuaySharedLiquidityAMM.QuoteResult memory q =
            amm.quoteExactInput(wethBook, address(weth), 1e18);

        // A deposit lands between quote and swap, bumping the USDC nonce.
        _deposit(GROUP_MAIN, usdc, 1e6);

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        p.expectedInventoryNonceOut = q.inventoryNonceOut;
        vm.expectRevert(QuaySharedLiquidityAMM.InventoryNonceMismatch.selector);
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    function test_Swap_RevertNoAllowance() public {
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        weth.mint(taker, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(amm), 0, 1e18
            )
        );
        vm.prank(taker);
        amm.swapExactInputSingle(p);
    }

    // ------------------------------------------------------------------
    // Hostile tokens
    // ------------------------------------------------------------------

    function test_Swap_RevertFeeOnTransferInput() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(100); // 1% fee
        bytes32 groupId = keccak256("FOT_GROUP");
        vm.startPrank(protocolOwner);
        amm.createLiquidityGroup(groupId, maker);
        bytes32 bookId =
            amm.createBook(address(fot), address(usdc), groupId, bytes32("FOT"), 0, updater);
        vm.stopPrank();

        // Only USDC inventory is needed to quote FOT -> USDC.
        usdc.mint(maker, 100_000e6);
        vm.startPrank(maker);
        usdc.approve(address(amm), 100_000e6);
        amm.deposit(groupId, address(usdc), 100_000e6);
        vm.stopPrank();

        QuaySharedLiquidityAMM.QuoteState memory q = _wethQuote(1);
        q.bidPxX128 = Q128; // 1:1
        q.askPxX128 = Q128;
        _pushQuote(bookId, q);

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(bookId, address(fot), address(usdc), 1e6, 0);
        fot.mint(taker, 1e6);
        vm.startPrank(taker);
        fot.approve(address(amm), 1e6);
        vm.expectRevert(QuaySharedLiquidityAMM.NonStandardToken.selector);
        amm.swapExactInputSingle(p);
        vm.stopPrank();
    }

    function test_Swap_ReentrancyBlocked() public {
        ReentrantERC20 rtk = new ReentrantERC20();
        bytes32 groupId = keccak256("RTK_GROUP");
        vm.startPrank(protocolOwner);
        amm.createLiquidityGroup(groupId, maker);
        bytes32 bookId =
            amm.createBook(address(weth), address(rtk), groupId, bytes32("RTK"), 0, updater);
        vm.stopPrank();

        rtk.mint(maker, 1_000e18);
        vm.startPrank(maker);
        rtk.approve(address(amm), 1_000e18);
        amm.deposit(groupId, address(rtk), 1_000e18);
        vm.stopPrank();

        QuaySharedLiquidityAMM.QuoteState memory q = _wethQuote(1);
        q.bidPxX128 = Q128; // 1 RTK per WETH atom
        q.askPxX128 = Q128;
        _pushQuote(bookId, q);

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(bookId, address(weth), address(rtk), 1e18, 0);
        ReentrancyAttacker attacker = new ReentrancyAttacker(amm, p);
        weth.mint(address(attacker), 2e18);

        // Arm the token: the RTK payout to the recipient triggers a nested swap.
        rtk.setHook(address(attacker));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack();

        // Disarmed, the same swap succeeds.
        rtk.setHook(address(0));
        attacker.attack();
        assertEq(rtk.balanceOf(recipient), 1e18);
    }
}

contract ReentrancyAttacker is ITransferHook {
    QuaySharedLiquidityAMM private immutable amm;
    QuaySharedLiquidityAMM.SwapExactInputSingleParams private params;

    constructor(
        QuaySharedLiquidityAMM amm_,
        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory params_
    ) {
        amm = amm_;
        params = params_;
    }

    function attack() external {
        MockLikeIERC20(params.tokenIn).approve(address(amm), params.amountIn);
        amm.swapExactInputSingle(params);
    }

    function onTokenTransfer(address, address, uint256) external {
        amm.swapExactInputSingle(params);
    }
}

interface MockLikeIERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}
