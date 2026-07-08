// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MockERC20} from "test/utils/MockERC20.sol";

/// @dev Burns `feeBps` of every wallet-to-wallet transfer, so the recipient
///      receives less than the requested amount.
contract FeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps;

    constructor(uint256 feeBps_) MockERC20("FeeToken", "FEE", 18) {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
