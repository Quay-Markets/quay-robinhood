// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MockERC20} from "test/utils/MockERC20.sol";

interface ITransferHook {
    function onTokenTransfer(address from, address to, uint256 value) external;
}

/// @dev ERC-777-style token that invokes a hook on every wallet-to-wallet
///      transfer, letting tests attempt reentrancy against the AMM.
contract ReentrantERC20 is MockERC20 {
    address public hook;

    constructor() MockERC20("ReentrantToken", "RTK", 18) {}

    function setHook(address hook_) external {
        hook = hook_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hook != address(0) && from != address(0) && to != address(0)) {
            ITransferHook(hook).onTokenTransfer(from, to, value);
        }
    }
}
