// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {BBOStrategy} from "src/strategies/BBOStrategy.sol";

/// @dev Usage:
///   QUAY_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
///
/// Deploys the venue plus the default BBO strategy module. If the broadcaster
/// is the owner, the module is registered and approved in the same run;
/// otherwise the owner must call registerStrategy + setStrategyApproval.
contract Deploy is Script {
    function run() external returns (QuaySharedLiquidityAMM amm, BBOStrategy bbo) {
        address owner = vm.envAddress("QUAY_OWNER");
        vm.startBroadcast();
        amm = new QuaySharedLiquidityAMM(owner);
        bbo = new BBOStrategy();
        if (msg.sender == owner) {
            amm.registerStrategy(address(bbo));
            amm.setStrategyApproval(address(bbo), true);
        }
        vm.stopBroadcast();
    }
}
