// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {FeeOnTransferERC20} from "test/utils/FeeOnTransferERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityTest is QuayTestBase {
    function test_Deposit() public {
        uint256 invBefore = amm.inventory(GROUP_MAIN, address(weth));
        uint64 nonceBefore = amm.inventoryNonce(GROUP_MAIN, address(weth));

        weth.mint(maker, 5e18);
        vm.startPrank(maker);
        weth.approve(address(amm), 5e18);
        vm.expectEmit(true, true, true, true, address(amm));
        emit QuaySharedLiquidityAMM.LiquidityDeposited(
            GROUP_MAIN, address(weth), maker, 5e18, invBefore + 5e18, nonceBefore + 1
        );
        amm.deposit(GROUP_MAIN, address(weth), 5e18);
        vm.stopPrank();

        assertEq(amm.inventory(GROUP_MAIN, address(weth)), invBefore + 5e18);
        assertEq(amm.inventoryNonce(GROUP_MAIN, address(weth)), nonceBefore + 1);
        assertEq(weth.balanceOf(address(amm)), invBefore + 5e18);
    }

    function test_Deposit_ProtocolOwnerAllowed() public {
        usdc.mint(protocolOwner, 100e6);
        vm.startPrank(protocolOwner);
        usdc.approve(address(amm), 100e6);
        amm.deposit(GROUP_MAIN, address(usdc), 100e6);
        vm.stopPrank();
        assertEq(amm.inventory(GROUP_MAIN, address(usdc)), 500_000e6 + 100e6);
    }

    function test_Deposit_RevertStranger() public {
        usdc.mint(taker, 100e6);
        vm.startPrank(taker);
        usdc.approve(address(amm), 100e6);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.deposit(GROUP_MAIN, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_Deposit_RevertMissingGroup() public {
        vm.prank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidGroup.selector);
        amm.deposit(keccak256("nope"), address(usdc), 100e6);
    }

    function test_Deposit_RevertZeroTokenOrAmount() public {
        vm.startPrank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.deposit(GROUP_MAIN, address(0), 1);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.deposit(GROUP_MAIN, address(usdc), 0);
        vm.stopPrank();
    }

    function test_Deposit_RevertFeeOnTransferToken() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(100); // 1% transfer fee
        fot.mint(maker, 10e18);
        vm.startPrank(maker);
        fot.approve(address(amm), 10e18);
        vm.expectRevert(QuaySharedLiquidityAMM.NonStandardToken.selector);
        amm.deposit(GROUP_MAIN, address(fot), 10e18);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        uint64 nonceBefore = amm.inventoryNonce(GROUP_MAIN, address(usdc));

        vm.expectEmit(true, true, true, true, address(amm));
        emit QuaySharedLiquidityAMM.LiquidityWithdrawn(
            GROUP_MAIN, address(usdc), recipient, 1000e6, 499_000e6, nonceBefore + 1
        );
        vm.prank(maker);
        amm.withdraw(GROUP_MAIN, address(usdc), 1000e6, recipient);

        assertEq(amm.inventory(GROUP_MAIN, address(usdc)), 499_000e6);
        assertEq(usdc.balanceOf(recipient), 1000e6);
        assertEq(amm.inventoryNonce(GROUP_MAIN, address(usdc)), nonceBefore + 1);
    }

    function test_Withdraw_RevertOverInventory() public {
        vm.prank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InsufficientInventory.selector);
        amm.withdraw(GROUP_MAIN, address(usdc), 500_000e6 + 1, maker);
    }

    function test_Withdraw_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.withdraw(GROUP_MAIN, address(usdc), 1, taker);
    }

    function test_Withdraw_RevertZeroArgs() public {
        vm.startPrank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.withdraw(GROUP_MAIN, address(0), 1, maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.withdraw(GROUP_MAIN, address(usdc), 1, address(0));
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.withdraw(GROUP_MAIN, address(usdc), 0, maker);
        vm.stopPrank();
    }

    function test_Withdraw_CannotTouchProtocolFees() public {
        // Accrue input-side fees in WETH via a swap.
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 10e18, 0));
        uint256 fees = amm.protocolFees(GROUP_MAIN, address(weth));
        assertGt(fees, 0);

        uint256 inv = amm.inventory(GROUP_MAIN, address(weth));
        vm.prank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InsufficientInventory.selector);
        amm.withdraw(GROUP_MAIN, address(weth), inv + 1, maker);

        // Full inventory withdrawal still leaves the fee balance in the contract.
        vm.prank(maker);
        amm.withdraw(GROUP_MAIN, address(weth), inv, maker);
        assertEq(weth.balanceOf(address(amm)), fees);
    }

    function test_WithdrawProtocolFees() public {
        _swapAs(taker, _swapParams(wethBook, address(weth), address(usdc), 10e18, 0));
        uint256 fees = amm.protocolFees(GROUP_MAIN, address(weth));
        assertEq(fees, (10e18 * uint256(FEE_BPS)) / 10_000);

        vm.expectEmit(true, true, true, true, address(amm));
        emit QuaySharedLiquidityAMM.ProtocolFeesWithdrawn(
            GROUP_MAIN, address(weth), recipient, fees
        );
        vm.prank(protocolOwner);
        amm.withdrawProtocolFees(GROUP_MAIN, address(weth), fees, recipient);

        assertEq(amm.protocolFees(GROUP_MAIN, address(weth)), 0);
        assertEq(weth.balanceOf(recipient), fees);
    }

    function test_WithdrawProtocolFees_RevertNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.withdrawProtocolFees(GROUP_MAIN, address(weth), 1, maker);
    }

    function test_WithdrawProtocolFees_RevertOverAccrued() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InsufficientInventory.selector);
        amm.withdrawProtocolFees(GROUP_MAIN, address(weth), 1, recipient);
    }
}
