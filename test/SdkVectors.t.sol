// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";

/// @dev Regenerates sdk/test-vectors.json on every test run. Each vector is a
///      full input snapshot (book, quote, inventory, time) plus the venue's
///      exact QuoteResult; the TypeScript SDK's vitest suite replays the
///      inputs through its pure quote math and must match every output field
///      bit-for-bit. This is the SDK <-> Solidity parity contract.
contract SdkVectorsTest is QuayTestBase {
    string[] internal vecs;

    function _capture(string memory name, bytes32 bookId, address tokenIn, uint256 amountIn)
        internal
    {
        QuaySharedLiquidityAMM.BookStateView memory v = amm.getBookState(bookId);
        QuaySharedLiquidityAMM.QuoteResult memory r = amm.quoteExactInput(bookId, tokenIn, amountIn);
        bool token0In = tokenIn == v.book.token0;

        string memory s = string.concat(
            '{"name":"',
            name,
            '","kind":"bbo","token0In":',
            token0In ? "true" : "false",
            ',"amountIn":"',
            vm.toString(amountIn),
            '","nowSec":"',
            vm.toString(block.timestamp),
            '","protocolFeeBps":"',
            vm.toString(v.book.protocolFeeBps),
            '","availableOut":"',
            vm.toString(token0In ? v.inventory1 : v.inventory0),
            '","quote":',
            _quoteJson(v.quote),
            ',"config":{},"expected":',
            _resultJson(r),
            "}"
        );
        vecs.push(s);
    }

    function _quoteJson(QuayTypes.QuoteState memory q) internal pure returns (string memory) {
        return string.concat(
            '{"nonce":"',
            vm.toString(q.nonce),
            '","updatedAt":"',
            vm.toString(q.updatedAt),
            '","freshUntil":"',
            vm.toString(q.freshUntil),
            '","validUntil":"',
            vm.toString(q.validUntil),
            '","decayBpsPerSecond":"',
            vm.toString(q.decayBpsPerSecond),
            '","maxDecayBps":"',
            vm.toString(q.maxDecayBps),
            '","bidPxX128":"',
            vm.toString(q.bidPxX128),
            '","askPxX128":"',
            vm.toString(q.askPxX128),
            '","maxIn0":"',
            vm.toString(q.maxIn0),
            '","maxIn1":"',
            vm.toString(q.maxIn1),
            '"}'
        );
    }

    function _resultJson(QuaySharedLiquidityAMM.QuoteResult memory r)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"valid":',
            r.valid ? "true" : "false",
            ',"reason":"',
            vm.toString(uint256(uint8(r.reason))),
            '","amountOut":"',
            vm.toString(r.amountOut),
            '","feeAmount":"',
            vm.toString(r.feeAmount),
            '","netAmountIn":"',
            vm.toString(r.netAmountIn),
            '","appliedPriceX128":"',
            vm.toString(r.appliedPriceX128),
            '","appliedDecayBps":"',
            vm.toString(uint256(r.appliedDecayBps)),
            '"}'
        );
    }

    function test_GenerateVectors() public {
        _capture("bbo_fresh_sell0", mathBook, address(math0), 1e18);
        _capture("bbo_fresh_sell1", mathBook, address(math1), 200e18);
        _capture("bbo_fee_sell0", wethBook, address(weth), 1e18);
        _capture("bbo_fee_sell1", wethBook, address(usdc), 2001e6);
        _capture("bbo_size_exceeded", wethBook, address(weth), 101e18);
        _capture("bbo_zero_output", wethBook, address(weth), 1);

        vm.warp(START + FRESH_SECONDS + 3); // 300 bps decay
        _capture("bbo_decayed_sell0", mathBook, address(math0), 1e18);
        _capture("bbo_decayed_sell1", mathBook, address(math1), 206e18);
        vm.warp(START + VALID_SECONDS); // capped decay, last valid second
        _capture("bbo_decay_capped", mathBook, address(math0), 1e18);
        vm.warp(START + VALID_SECONDS + 1);
        _capture("bbo_expired", mathBook, address(math0), 1e18);

        string memory json = "[";
        for (uint256 i = 0; i < vecs.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", vecs[i]);
        }
        json = string.concat(json, "]");
        vm.writeFile("sdk/test-vectors.json", json);
        assertGt(vecs.length, 8);
    }
}
