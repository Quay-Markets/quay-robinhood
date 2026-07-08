// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdminTest is QuayTestBase {
    bytes32 internal constant NEW_GROUP = keccak256("NEW_GROUP");

    // ------------------------------------------------------------------
    // Liquidity groups
    // ------------------------------------------------------------------

    function test_CreateLiquidityGroup() public {
        vm.expectEmit(true, true, false, true, address(amm));
        emit QuaySharedLiquidityAMM.LiquidityGroupCreated(NEW_GROUP, maker);

        vm.prank(protocolOwner);
        amm.createLiquidityGroup(NEW_GROUP, maker);

        (address owner_, bool exists, bool paused, uint64 createdAt) =
            amm.liquidityGroups(NEW_GROUP);
        assertEq(owner_, maker);
        assertTrue(exists);
        assertFalse(paused);
        assertEq(createdAt, START);
    }

    function test_CreateLiquidityGroup_RevertNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.createLiquidityGroup(NEW_GROUP, maker);
    }

    function test_CreateLiquidityGroup_RevertZeroId() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.createLiquidityGroup(bytes32(0), maker);
    }

    function test_CreateLiquidityGroup_RevertZeroOwner() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.createLiquidityGroup(NEW_GROUP, address(0));
    }

    function test_CreateLiquidityGroup_RevertDuplicate() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidGroup.selector);
        amm.createLiquidityGroup(GROUP_MAIN, maker);
    }

    function test_SetLiquidityGroupPaused_ByGroupOwnerAndProtocol() public {
        vm.prank(maker);
        amm.setLiquidityGroupPaused(GROUP_MAIN, true);
        (,, bool paused,) = amm.liquidityGroups(GROUP_MAIN);
        assertTrue(paused);

        vm.prank(protocolOwner);
        amm.setLiquidityGroupPaused(GROUP_MAIN, false);
        (,, paused,) = amm.liquidityGroups(GROUP_MAIN);
        assertFalse(paused);
    }

    function test_SetLiquidityGroupPaused_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.setLiquidityGroupPaused(GROUP_MAIN, true);
    }

    function test_SetLiquidityGroupPaused_RevertMissingGroup() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidGroup.selector);
        amm.setLiquidityGroupPaused(NEW_GROUP, true);
    }

    // ------------------------------------------------------------------
    // Books
    // ------------------------------------------------------------------

    function test_CreateBook() public {
        vm.prank(protocolOwner);
        bytes32 bookId = amm.createBook(
            address(cbbtc), address(usdc), GROUP_MAIN, bytes32("BTCUSDC"), 10, updater
        );

        QuaySharedLiquidityAMM.Book memory b = amm.getBook(bookId);
        assertEq(b.token0, address(cbbtc));
        assertEq(b.token1, address(usdc));
        assertEq(b.liquidityGroupId, GROUP_MAIN);
        assertEq(b.protocolFeeBps, 10);
        assertEq(uint8(b.status), uint8(QuaySharedLiquidityAMM.BookStatus.Active));
        assertEq(b.createdAt, START);

        assertTrue(amm.isUpdater(bookId, updater));

        // Registered in pair index, both orderings.
        bytes32[] memory ids = amm.getBooksForPair(address(cbbtc), address(usdc));
        assertEq(ids.length, 1);
        assertEq(ids[0], bookId);
        ids = amm.getBooksForPair(address(usdc), address(cbbtc));
        assertEq(ids.length, 1);
        assertEq(ids[0], bookId);

        bytes32[] memory all = amm.getAllBookIds();
        assertEq(all.length, 3); // WETH book + math book from setUp + this one
        assertEq(all[2], bookId);
    }

    function test_CreateBook_RevertNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, 0, 10, updater);
    }

    function test_CreateBook_RevertBadTokens() public {
        vm.startPrank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.createBook(address(0), address(usdc), GROUP_MAIN, 0, 10, updater);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.createBook(address(cbbtc), address(0), GROUP_MAIN, 0, 10, updater);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.createBook(address(usdc), address(usdc), GROUP_MAIN, 0, 10, updater);
        vm.stopPrank();
    }

    function test_CreateBook_RevertMissingGroup() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidGroup.selector);
        amm.createBook(address(cbbtc), address(usdc), NEW_GROUP, 0, 10, updater);
    }

    function test_CreateBook_RevertFeeTooHigh() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.BadFee.selector);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, 0, 10_001, updater);
    }

    function test_CreateBook_RevertDuplicateSalt() public {
        vm.startPrank(protocolOwner);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, bytes32("S"), 10, updater);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidBook.selector);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, bytes32("S"), 10, updater);
        vm.stopPrank();
    }

    function test_CreateBook_NoInitialUpdater() public {
        vm.prank(protocolOwner);
        bytes32 bookId =
            amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, 0, 10, address(0));
        assertEq(amm.getUpdaters(bookId).length, 0);
    }

    // ------------------------------------------------------------------
    // Book status
    // ------------------------------------------------------------------

    function test_SetBookStatus_MakerAndProtocol() public {
        vm.expectEmit(true, false, false, true, address(amm));
        emit QuaySharedLiquidityAMM.BookStatusChanged(
            wethBook,
            QuaySharedLiquidityAMM.BookStatus.Active,
            QuaySharedLiquidityAMM.BookStatus.Paused,
            maker
        );
        vm.prank(maker);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
        assertEq(
            uint8(amm.getBook(wethBook).status), uint8(QuaySharedLiquidityAMM.BookStatus.Paused)
        );

        vm.prank(protocolOwner);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Active);
        assertEq(
            uint8(amm.getBook(wethBook).status), uint8(QuaySharedLiquidityAMM.BookStatus.Active)
        );
    }

    function test_SetBookStatus_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Paused);
    }

    function test_SetBookStatus_RevertUnknownBook() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidBook.selector);
        amm.setBookStatus(bytes32("nope"), QuaySharedLiquidityAMM.BookStatus.Paused);
    }

    function test_SetBookStatus_RevertToUninitialized() public {
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidBook.selector);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Uninitialized);
    }

    function test_SetBookStatus_ClosedIsTerminal() public {
        vm.startPrank(protocolOwner);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Closed);
        vm.expectRevert(QuaySharedLiquidityAMM.BookClosed.selector);
        amm.setBookStatus(wethBook, QuaySharedLiquidityAMM.BookStatus.Active);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Updaters
    // ------------------------------------------------------------------

    function test_SetUpdater_AddAndRemove() public {
        address second = makeAddr("second");

        vm.prank(maker);
        amm.setUpdater(wethBook, second, true);
        assertTrue(amm.isUpdater(wethBook, second));

        vm.prank(protocolOwner);
        amm.setUpdater(wethBook, second, false);
        assertFalse(amm.isUpdater(wethBook, second));

        // List keeps history without duplicates.
        vm.prank(maker);
        amm.setUpdater(wethBook, second, true);
        address[] memory list = amm.getUpdaters(wethBook);
        assertEq(list.length, 2);
        assertEq(list[0], updater);
        assertEq(list[1], second);
    }

    function test_SetUpdater_RevertStranger() public {
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotGroupOwner.selector);
        amm.setUpdater(wethBook, taker, true);
    }

    function test_SetUpdater_RevertZeroAddress() public {
        vm.prank(maker);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidAddress.selector);
        amm.setUpdater(wethBook, address(0), true);
    }

    // ------------------------------------------------------------------
    // Protocol pause
    // ------------------------------------------------------------------

    function test_Pause_BlocksQuotesAndSwaps() public {
        vm.prank(protocolOwner);
        amm.pause();

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuaySharedLiquidityAMM.QuoteReason.ProtocolPaused));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        weth.mint(taker, 1e18);
        vm.startPrank(taker);
        weth.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector,
                QuaySharedLiquidityAMM.QuoteReason.ProtocolPaused
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();

        // Withdrawals stay live so makers can pull funds during an emergency.
        vm.prank(maker);
        amm.withdraw(GROUP_MAIN, address(weth), 1e18, maker);

        vm.prank(protocolOwner);
        amm.unpause();
        r = amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertTrue(r.valid);
    }

    function test_Pause_RevertNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.pause();
    }

    // ------------------------------------------------------------------
    // Ownership
    // ------------------------------------------------------------------

    function test_OwnershipTransferIsTwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(protocolOwner);
        amm.transferOwnership(newOwner);
        assertEq(amm.owner(), protocolOwner); // unchanged until accepted

        vm.prank(newOwner);
        amm.acceptOwnership();
        assertEq(amm.owner(), newOwner);
    }
}
