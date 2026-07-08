// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";

/// @dev Usage:
///   QUAY_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract Deploy is Script {
    function run() external returns (QuaySharedLiquidityAMM amm) {
        address owner = vm.envAddress("QUAY_OWNER");
        vm.startBroadcast();
        amm = new QuaySharedLiquidityAMM(owner);
        vm.stopBroadcast();
    }
}
