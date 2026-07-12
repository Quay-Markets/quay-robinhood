// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {MicroV4Swapper, IPoolManager} from "src/ops/MicroV4Swapper.sol";

/// @dev Robinhood Chain ops: buy small AAPL + USDG inventory on Uniswap v4
///      with the broadcaster's ETH and deposit everything into the venue's
///      liquidity group. Swaps go through our own MicroV4Swapper straight to
///      the PoolManager — the chain's unverified UniversalRouter build
///      reverts on ERC-20-input v4 swaps (see test/fork/BuyRoute.t.sol).
///
/// Verified live pools (hookless): ETH/USDG and USDG/AAPL, both fee 500/ts 10.
///
/// Env: QUAY_VENUE, GROUP_NAME, ETH_IN, USDG_FOR_AAPL, MIN_USDG_OUT, MIN_AAPL_OUT
contract BuyInventory is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    function run() external {
        QuaySharedLiquidityAMM venue = QuaySharedLiquidityAMM(vm.envAddress("QUAY_VENUE"));
        bytes32 groupId = keccak256(bytes(vm.envString("GROUP_NAME")));
        uint128 ethIn = uint128(vm.envUint("ETH_IN"));
        uint128 usdgForAapl = uint128(vm.envUint("USDG_FOR_AAPL"));
        uint128 minUsdgOut = uint128(vm.envUint("MIN_USDG_OUT"));
        uint128 minAaplOut = uint128(vm.envUint("MIN_AAPL_OUT"));

        vm.startBroadcast();
        address me = msg.sender;
        MicroV4Swapper swapper = new MicroV4Swapper(POOL_MANAGER);

        uint256 usdgOut = swapper.swapExactInSingle{value: ethIn}(
            MicroV4Swapper.PoolKey(address(0), USDG, 500, 10, address(0)), true, ethIn, minUsdgOut
        );
        console.log("USDG bought: %s", usdgOut);

        IERC20(USDG).approve(address(swapper), usdgForAapl);
        uint256 aaplOut = swapper.swapExactInSingle(
            MicroV4Swapper.PoolKey(USDG, AAPL, 500, 10, address(0)), true, usdgForAapl, minAaplOut
        );
        console.log("AAPL bought: %s", aaplOut);

        uint256 aaplBal = IERC20(AAPL).balanceOf(me);
        uint256 usdgBal = IERC20(USDG).balanceOf(me);
        IERC20(AAPL).approve(address(venue), aaplBal);
        IERC20(USDG).approve(address(venue), usdgBal);
        venue.deposit(groupId, AAPL, aaplBal);
        venue.deposit(groupId, USDG, usdgBal);
        vm.stopBroadcast();

        console.log("Group inventory now:");
        console.log("  AAPL: %s", venue.inventory(groupId, AAPL));
        console.log("  USDG: %s", venue.inventory(groupId, USDG));
    }
}
