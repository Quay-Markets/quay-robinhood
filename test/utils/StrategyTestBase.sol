// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuayTypes} from "src/QuayTypes.sol";

/// @dev Shared plumbing for reference-strategy test suites: registers and
///      approves a module, opens a zero-fee math0/math1 book on it, and pushes
///      a heartbeat quote with unbounded size caps.
abstract contract StrategyTestBase is QuayTestBase {
    function _approveModule(address module) internal {
        vm.startPrank(protocolOwner);
        amm.registerStrategy(module);
        amm.setStrategyApproval(module, true);
        vm.stopPrank();
    }

    function _newMathBook(address module, bytes32 salt) internal returns (bytes32 bookId) {
        vm.prank(protocolOwner);
        bookId =
            amm.createBook(address(math0), address(math1), GROUP_MATH, salt, 0, module, updater);
    }

    /// @dev Heartbeat quote: mid in bidPxX128, ask == bid, no caps.
    function _midQuote(uint64 nonce, uint256 midPxX128)
        internal
        view
        returns (QuayTypes.QuoteState memory q)
    {
        q = _mathQuote(nonce);
        q.bidPxX128 = midPxX128;
        q.askPxX128 = midPxX128;
        q.maxIn0 = type(uint128).max;
        q.maxIn1 = type(uint128).max;
    }
}
