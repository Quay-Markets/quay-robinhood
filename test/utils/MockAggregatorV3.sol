// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
