// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "test/utils/MockERC20.sol";

/// @dev Smoke-test helper: deploys a mock 18-dec stock token and a mock 6-dec
///      settlement token, minting inventory to the broadcaster and (optional
///      TAKER env) trading balance to a taker.
contract DeployMocks is Script {
    function run() external returns (address stock, address cash) {
        vm.startBroadcast();
        MockERC20 mStock = new MockERC20("Mock AAPL", "mAAPL", 18);
        MockERC20 mCash = new MockERC20("Mock USDG", "mUSDG", 6);
        mStock.mint(msg.sender, 10_000e18);
        mCash.mint(msg.sender, 2_000_000e6);

        address taker = vm.envOr("TAKER", address(0));
        if (taker != address(0)) {
            mCash.mint(taker, 100_000e6);
        }
        vm.stopBroadcast();
        return (address(mStock), address(mCash));
    }
}
