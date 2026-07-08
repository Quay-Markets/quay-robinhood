// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {IQuayStrategy} from "src/interfaces/IQuayStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StrategyTest is QuayTestBase {
    address internal author;

    function setUp() public override {
        super.setUp();
        author = makeAddr("author");
        vm.prank(protocolOwner);
        amm.setStrategyAuthor(author, true);
    }

    function _newModule() internal returns (address) {
        return address(new FixedDoubleStrategy());
    }

    // ------------------------------------------------------------------
    // Registry governance
    // ------------------------------------------------------------------

    function test_SetStrategyAuthor_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, maker));
        vm.prank(maker);
        amm.setStrategyAuthor(maker, true);

        vm.expectEmit(true, false, false, true, address(amm));
        emit QuaySharedLiquidityAMM.StrategyAuthorSet(maker, true);
        vm.prank(protocolOwner);
        amm.setStrategyAuthor(maker, true);
        assertTrue(amm.isStrategyAuthor(maker));
    }

    function test_RegisterStrategy_ByAuthor() public {
        address module = _newModule();
        vm.expectEmit(true, true, false, true, address(amm));
        emit QuaySharedLiquidityAMM.StrategyRegistered(module, author);
        vm.prank(author);
        amm.registerStrategy(module);

        (address a, uint64 at, QuaySharedLiquidityAMM.StrategyStatus st) = amm.strategies(module);
        assertEq(a, author);
        assertEq(at, START);
        assertEq(uint8(st), uint8(QuaySharedLiquidityAMM.StrategyStatus.Registered));
    }

    function test_RegisterStrategy_RevertStranger() public {
        address module = _newModule();
        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotStrategyAuthor.selector);
        amm.registerStrategy(module);
    }

    function test_RegisterStrategy_RevertNoCodeOrZero() public {
        vm.startPrank(author);
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidStrategy.selector);
        amm.registerStrategy(taker); // EOA, no code
        vm.expectRevert(QuaySharedLiquidityAMM.InvalidStrategy.selector);
        amm.registerStrategy(address(0));
        vm.stopPrank();
    }

    function test_RegisterStrategy_RevertDuplicate() public {
        vm.prank(author);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyAlreadyRegistered.selector);
        amm.registerStrategy(address(bbo)); // registered in setUp
    }

    function test_SetStrategyApproval_OnlyOwnerAndRegistered() public {
        address module = _newModule();
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyNotRegistered.selector);
        amm.setStrategyApproval(module, true);

        vm.prank(author);
        amm.registerStrategy(module);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, author));
        vm.prank(author);
        amm.setStrategyApproval(module, true);
    }

    function test_RetireStrategy_AuthorOnlyAndTerminal() public {
        address module = _newModule();
        vm.prank(author);
        amm.registerStrategy(module);

        vm.prank(taker);
        vm.expectRevert(QuaySharedLiquidityAMM.NotStrategyAuthor.selector);
        amm.retireStrategy(module);

        vm.prank(author);
        amm.retireStrategy(module);
        (,, QuaySharedLiquidityAMM.StrategyStatus st) = amm.strategies(module);
        assertEq(uint8(st), uint8(QuaySharedLiquidityAMM.StrategyStatus.Retired));

        // Terminal: neither re-approval nor re-retirement is possible.
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyRetiredError.selector);
        amm.setStrategyApproval(module, true);
        vm.prank(author);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyRetiredError.selector);
        amm.retireStrategy(module);
    }

    function test_CreateBook_RequiresApprovedStrategy() public {
        address module = _newModule();

        // None
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyNotApprovedError.selector);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, bytes32("X"), 0, module, updater);

        // Registered but not approved
        vm.prank(author);
        amm.registerStrategy(module);
        vm.prank(protocolOwner);
        vm.expectRevert(QuaySharedLiquidityAMM.StrategyNotApprovedError.selector);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, bytes32("X"), 0, module, updater);

        // Approved works
        vm.startPrank(protocolOwner);
        amm.setStrategyApproval(module, true);
        amm.createBook(address(cbbtc), address(usdc), GROUP_MAIN, bytes32("X"), 0, module, updater);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Kill-switch: block/retire stops quoting instantly, funds stay free
    // ------------------------------------------------------------------

    function test_BlockStrategy_KillsQuotesAndSwapsImmediately() public {
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);

        vm.prank(protocolOwner);
        amm.setStrategyApproval(address(bbo), false);

        // Every book on the blocked strategy stops quoting.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.StrategyNotApproved));
        r = amm.quoteExactInput(mathBook, address(math0), 1e18);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.StrategyNotApproved));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(wethBook, address(weth), address(usdc), 1e18, 0);
        weth.mint(taker, 1e18);
        vm.startPrank(taker);
        weth.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector,
                QuayTypes.QuoteReason.StrategyNotApproved
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();

        // Re-approval restores quoting.
        vm.prank(protocolOwner);
        amm.setStrategyApproval(address(bbo), true);
        assertTrue(amm.quoteExactInput(wethBook, address(weth), 1e18).valid);
    }

    function test_BlockedStrategy_FundsRemainWithdrawable() public {
        vm.prank(protocolOwner);
        amm.setStrategyApproval(address(bbo), false);

        // Maker can withdraw full inventory while the strategy is blocked.
        uint256 invWeth = amm.inventory(GROUP_MAIN, address(weth));
        uint256 invUsdc = amm.inventory(GROUP_MAIN, address(usdc));
        vm.startPrank(maker);
        amm.withdraw(GROUP_MAIN, address(weth), invWeth, maker);
        amm.withdraw(GROUP_MAIN, address(usdc), invUsdc, maker);
        vm.stopPrank();
        assertEq(weth.balanceOf(maker), invWeth);
        assertEq(usdc.balanceOf(maker), invUsdc);

        // Deposits and quote updates keep working too.
        _deposit(GROUP_MAIN, weth, 1e18);
        _pushWethQuote(2);
    }

    function test_RetiredStrategy_KillsQuoting() public {
        vm.prank(protocolOwner);
        amm.retireStrategy(address(bbo)); // owner may retire on behalf of author

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(wethBook, address(weth), 1e18);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.StrategyNotApproved));
    }

    // ------------------------------------------------------------------
    // Custom modules actually price
    // ------------------------------------------------------------------

    function _createBookWith(address module) internal returns (bytes32 bookId) {
        vm.prank(author);
        amm.registerStrategy(module);
        vm.startPrank(protocolOwner);
        amm.setStrategyApproval(module, true);
        bookId = amm.createBook(
            address(math0), address(math1), GROUP_MATH, bytes32("CUSTOM"), 0, module, updater
        );
        vm.stopPrank();
        _pushQuote(bookId, _mathQuote(1));
    }

    function test_CustomStrategyPricesSwaps() public {
        bytes32 bookId = _createBookWith(address(new FixedDoubleStrategy()));

        // FixedDoubleStrategy ignores the posted quote: out = 2x in / in = 2x out.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(math0), 5e18);
        assertTrue(r.valid);
        assertEq(r.amountOut, 10e18);

        uint256 out = _swapAs(taker, _swapParams(bookId, address(math0), address(math1), 5e18, 0));
        assertEq(out, 10e18);

        // The BBO book on the same pair and group is unaffected.
        assertEq(amm.quoteExactInput(mathBook, address(math0), 1e18).amountOut, 100e18);
    }

    function test_RevertingStrategy_DegradesToInvalidQuote() public {
        bytes32 bookId = _createBookWith(address(new RevertingStrategy()));

        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(math0), 1e18);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.StrategyError));

        QuaySharedLiquidityAMM.SwapExactInputSingleParams memory p =
            _swapParams(bookId, address(math0), address(math1), 1e18, 0);
        math0.mint(taker, 1e18);
        vm.startPrank(taker);
        math0.approve(address(amm), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                QuaySharedLiquidityAMM.QuoteInvalid.selector, QuayTypes.QuoteReason.StrategyError
            )
        );
        amm.swapExactInputSingle(p);
        vm.stopPrank();
    }

    function test_GasBurningStrategy_IsContainedByGasCap() public {
        bytes32 bookId = _createBookWith(address(new GasBurnStrategy()));

        // The module burns its whole stipend; the quoter survives and reports
        // StrategyError instead of reverting.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(math0), 1e18);
        assertFalse(r.valid);
        assertEq(uint8(r.reason), uint8(QuayTypes.QuoteReason.StrategyError));
    }

    function test_InventoryAwareStrategySeesAvailableOut() public {
        bytes32 bookId = _createBookWith(address(new EchoInventoryStrategy()));

        // EchoInventoryStrategy returns availableOut as the price diagnostic.
        QuaySharedLiquidityAMM.QuoteResult memory r =
            amm.quoteExactInput(bookId, address(math0), 1e18);
        assertEq(r.appliedPriceX128, amm.inventory(GROUP_MATH, address(math1)));
    }
}

/// @dev Ignores posted quote params: token0 -> token1 doubles, reverse halves.
contract FixedDoubleStrategy is IQuayStrategy {
    function quoteExactInput(
        bytes32,
        QuayTypes.QuoteState calldata,
        bool token0In,
        uint256,
        uint256 netAmountIn,
        uint256
    ) external pure returns (uint256, uint256, uint32, QuayTypes.QuoteReason) {
        uint256 amountOut = token0In ? netAmountIn * 2 : netAmountIn / 2;
        return (amountOut, 2 << 128, 0, QuayTypes.QuoteReason.OK);
    }
}

contract RevertingStrategy is IQuayStrategy {
    function quoteExactInput(
        bytes32,
        QuayTypes.QuoteState calldata,
        bool,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256, uint256, uint32, QuayTypes.QuoteReason) {
        revert("strategy broken");
    }
}

contract GasBurnStrategy is IQuayStrategy {
    function quoteExactInput(
        bytes32,
        QuayTypes.QuoteState calldata,
        bool,
        uint256,
        uint256,
        uint256
    ) external view returns (uint256, uint256, uint32, QuayTypes.QuoteReason) {
        // Burns the entire gas stipend: keccak never yields exactly zero in
        // practice, so this loop only ends by running out of gas.
        uint256 x = block.timestamp;
        while (x != 0) {
            x = uint256(keccak256(abi.encode(x)));
        }
        return (x, 0, 0, QuayTypes.QuoteReason.OK);
    }
}

/// @dev Proves modules receive read-only inventory context.
contract EchoInventoryStrategy is IQuayStrategy {
    function quoteExactInput(
        bytes32,
        QuayTypes.QuoteState calldata,
        bool,
        uint256,
        uint256 netAmountIn,
        uint256 availableOut
    ) external pure returns (uint256, uint256, uint32, QuayTypes.QuoteReason) {
        return (netAmountIn, availableOut, 0, QuayTypes.QuoteReason.OK);
    }
}
