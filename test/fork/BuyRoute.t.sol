// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MicroV4Swapper, IPoolManager} from "src/ops/MicroV4Swapper.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @dev Fork-only debugging/verification of the Robinhood Chain Uniswap v4
///      buy route. Skipped unless FORK_URL is set:
///      FORK_URL=$(cat ../quay-demo/rpc.txt) forge test --match-contract BuyRouteFork -vvvv
contract BuyRouteForkTest is Test {
    IUniversalRouter constant ROUTER = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    function test_MicroSwapperFullRoute() public {
        // Own swapper straight to the PoolManager: ETH -> USDG -> AAPL.
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0);
        vm.createSelectFork(forkUrl);

        MicroV4Swapper swapper =
            new MicroV4Swapper(IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951));
        address me = makeAddr("micro-buyer");
        vm.deal(me, 1 ether);
        vm.startPrank(me);

        uint256 usdgOut = swapper.swapExactInSingle{value: 5600000000000000}(
            MicroV4Swapper.PoolKey(address(0), USDG, 500, 10, address(0)),
            true,
            5600000000000000,
            9800000
        );
        emit log_named_uint("USDG out", usdgOut);
        assertGt(usdgOut, 9800000);

        IERC20(USDG).approve(address(swapper), 5000000);
        uint256 aaplOut = swapper.swapExactInSingle(
            MicroV4Swapper.PoolKey(USDG, AAPL, 500, 10, address(0)),
            true,
            5000000,
            15500000000000000
        );
        emit log_named_uint("AAPL out", aaplOut);
        assertGt(aaplOut, 15500000000000000);
        assertEq(IERC20(AAPL).balanceOf(me), aaplOut);
        vm.stopPrank();
    }

    function test_UsdgToAaplAlone() public {
        // Isolation: USDG -> AAPL as the FIRST router interaction in the tx,
        // funded from a whale instead of a prior router swap.
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0);
        vm.createSelectFork(forkUrl);

        address whale = 0x2d4d2A025b10C09BDbd794B4FCe4F7ea8C7d7bB4;
        address me = makeAddr("solo-buyer");
        vm.deal(me, 1 ether);
        vm.prank(whale);
        IERC20(USDG).transfer(me, 10_000_000); // 10 USDG

        vm.startPrank(me);
        IERC20(USDG).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(USDG, address(ROUTER), type(uint160).max, type(uint48).max);
        _swap(PoolKey(USDG, AAPL, 500, 10, address(0)), 5000000, 15500000000000000, USDG, 0);
        emit log_named_uint("AAPL", IERC20(AAPL).balanceOf(me));
        assertGt(IERC20(AAPL).balanceOf(me), 15500000000000000);
        vm.stopPrank();
    }

    function test_BuyRoute() public {
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0);
        vm.createSelectFork(forkUrl);

        address me = makeAddr("buyer");
        vm.deal(me, 1 ether);
        vm.startPrank(me);

        // 1. ETH -> USDG
        _swap(
            PoolKey(address(0), USDG, 500, 10, address(0)),
            5600000000000000,
            9800000,
            address(0),
            5600000000000000
        );
        uint256 usdg = IERC20(USDG).balanceOf(me);
        emit log_named_uint("USDG", usdg);
        assertGt(usdg, 9800000);

        // 2. USDG -> AAPL
        IERC20(USDG).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(USDG, address(ROUTER), type(uint160).max, type(uint48).max);
        _swap(PoolKey(USDG, AAPL, 500, 10, address(0)), 5000000, 15500000000000000, USDG, 0);
        uint256 aapl = IERC20(AAPL).balanceOf(me);
        emit log_named_uint("AAPL", aapl);
        assertGt(aapl, 15500000000000000);
        vm.stopPrank();
    }

    function _swap(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minOut,
        address currencyIn,
        uint256 msgValue
    ) internal {
        bytes memory actions = abi.encodePacked(bytes1(0x06), bytes1(0x0c), bytes1(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, true, amountIn, minOut, ""));
        params[1] = abi.encode(currencyIn, uint256(amountIn));
        params[2] = abi.encode(key.currency1, uint256(minOut));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        ROUTER.execute{value: msgValue}(
            abi.encodePacked(bytes1(0x10)), inputs, block.timestamp + 120
        );
    }
}
