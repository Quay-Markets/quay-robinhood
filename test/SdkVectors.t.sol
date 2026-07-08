// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StrategyTestBase} from "test/utils/StrategyTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {SolFiStrategy} from "src/strategies/SolFiStrategy.sol";
import {HumidiFiStrategy} from "src/strategies/HumidiFiStrategy.sol";
import {BisonFiStrategy} from "src/strategies/BisonFiStrategy.sol";

/// @dev Regenerates sdk/test-vectors.json on every test run. Each vector is a
///      full input snapshot (book, quote, inventory, strategy config, time)
///      plus the venue's exact QuoteResult; the TypeScript SDK's vitest suite
///      replays the inputs through its pure quote math and must match every
///      output field bit-for-bit. This is the SDK <-> Solidity parity contract.
contract SdkVectorsTest is StrategyTestBase {
    string[] internal vecs;

    SolFiStrategy internal solfi;
    HumidiFiStrategy internal humidifi;
    BisonFiStrategy internal bisonfi;
    bytes32 internal solfiBook;
    bytes32 internal humidifiBook;
    bytes32 internal bisonfiBook;

    uint256 internal constant MID = 100;

    function setUp() public override {
        super.setUp();

        solfi = new SolFiStrategy(amm);
        humidifi = new HumidiFiStrategy(amm);
        bisonfi = new BisonFiStrategy(amm);
        _approveModule(address(solfi));
        _approveModule(address(humidifi));
        _approveModule(address(bisonfi));
        solfiBook = _newMathBook(address(solfi), bytes32("V_SOLFI"));
        humidifiBook = _newMathBook(address(humidifi), bytes32("V_HUMIDIFI"));
        bisonfiBook = _newMathBook(address(bisonfi), bytes32("V_BISONFI"));

        // SolFi: long-lived quote so the 25s ramp fits inside validUntil.
        QuayTypes.QuoteState memory q = _midQuote(1, MID * Q128);
        q.freshUntil = uint64(block.timestamp) + 300;
        q.validUntil = uint64(block.timestamp) + 300;
        _pushQuote(solfiBook, q);
        _pushQuote(humidifiBook, _midQuote(1, MID * Q128));
        _pushQuote(bisonfiBook, _midQuote(1, MID * Q128));

        vm.startPrank(maker);
        solfi.setConfig(
            solfiBook,
            SolFiStrategy.Config({
                exists: true,
                rampSeconds: 25,
                maxAgeSeconds: 200,
                feePpm7: 77_000,
                c1Fresh: 10_000_000,
                c1Stale: 9_950_531,
                c0Fresh: 10_000_000,
                c0Stale: 10_100_000
            })
        );
        humidifi.setConfig(
            humidifiBook,
            HumidiFiStrategy.Config({
                exists: true,
                circuitBreaker: 0,
                baseSpread: 62_116,
                sqrtDiv: 55_743,
                linDiv: 25_000_000,
                kickSpread: 594,
                maxSpread: 400_000,
                kickThreshold: 5_500_000_000
            })
        );
        bisonfi.setConfig(
            bisonfiBook,
            BisonFiStrategy.Config({
                exists: true,
                basePerSecond: 128,
                maxAgeSeconds: 5,
                defaultPick: 786,
                maxRatioPpm: 700_000
            })
        );
        BisonFiStrategy.Tier[] memory ladder = new BisonFiStrategy.Tier[](2);
        ladder[0] =
            BisonFiStrategy.Tier({thresholdRatioPpm: 100_000, slopePpm: 5154, offsetPpm: 50});
        ladder[1] =
            BisonFiStrategy.Tier({thresholdRatioPpm: 300_000, slopePpm: 1000, offsetPpm: -20});
        bisonfi.setSideConfig(bisonfiBook, 0, 183, 128, ladder);
        bisonfi.setSideConfig(bisonfiBook, 1, 134, 0, new BisonFiStrategy.Tier[](0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Vector capture
    // ------------------------------------------------------------------

    function _capture(
        string memory name,
        string memory kind,
        bytes32 bookId,
        address tokenIn,
        uint256 amountIn,
        string memory cfg
    ) internal {
        QuaySharedLiquidityAMM.BookStateView memory v = amm.getBookState(bookId);
        QuaySharedLiquidityAMM.QuoteResult memory r = amm.quoteExactInput(bookId, tokenIn, amountIn);
        bool token0In = tokenIn == v.book.token0;

        string memory s = string.concat(
            '{"name":"',
            name,
            '","kind":"',
            kind,
            '","token0In":',
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
            ',"config":',
            cfg,
            ',"expected":',
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

    function _solfiCfg() internal view returns (string memory) {
        (, uint32 ramp, uint32 maxAge, uint32 fee, uint64 c1F, uint64 c1S, uint64 c0F, uint64 c0S) =
            solfi.configs(solfiBook);
        return string.concat(
            '{"rampSeconds":"',
            vm.toString(ramp),
            '","maxAgeSeconds":"',
            vm.toString(maxAge),
            '","feePpm7":"',
            vm.toString(fee),
            '","c1Fresh":"',
            vm.toString(c1F),
            '","c1Stale":"',
            vm.toString(c1S),
            '","c0Fresh":"',
            vm.toString(c0F),
            '","c0Stale":"',
            vm.toString(c0S),
            '"}'
        );
    }

    function _humidifiCfg() internal view returns (string memory) {
        (
            ,
            uint8 breaker,
            uint64 base,
            uint64 sqrtDiv,
            uint64 linDiv,
            uint64 kickSpread,
            uint64 maxSpread,
            uint128 kickThreshold
        ) = humidifi.configs(humidifiBook);
        return string.concat(
            '{"circuitBreaker":"',
            vm.toString(breaker),
            '","baseSpread":"',
            vm.toString(base),
            '","sqrtDiv":"',
            vm.toString(sqrtDiv),
            '","linDiv":"',
            vm.toString(linDiv),
            '","kickSpread":"',
            vm.toString(kickSpread),
            '","maxSpread":"',
            vm.toString(maxSpread),
            '","kickThreshold":"',
            vm.toString(kickThreshold),
            '"}'
        );
    }

    function _bisonfiCfg(uint8 side) internal view returns (string memory) {
        (, uint32 basePerSecond, uint32 maxAge, uint32 defaultPick, uint32 maxRatio) =
            bisonfi.configs(bisonfiBook);
        (uint32 field, uint32 floorValue, BisonFiStrategy.Tier[] memory ladder) =
            bisonfi.getSideConfig(bisonfiBook, side);
        string memory tiers = "[";
        for (uint256 i = 0; i < ladder.length; i++) {
            tiers = string.concat(
                tiers,
                i == 0 ? "" : ",",
                '{"thresholdRatioPpm":"',
                vm.toString(ladder[i].thresholdRatioPpm),
                '","slopePpm":"',
                vm.toString(ladder[i].slopePpm),
                '","offsetPpm":"',
                vm.toString(ladder[i].offsetPpm),
                '"}'
            );
        }
        tiers = string.concat(tiers, "]");
        return string.concat(
            '{"basePerSecond":"',
            vm.toString(basePerSecond),
            '","maxAgeSeconds":"',
            vm.toString(maxAge),
            '","defaultPick":"',
            vm.toString(defaultPick),
            '","maxRatioPpm":"',
            vm.toString(maxRatio),
            '","field":"',
            vm.toString(field),
            '","floorValue":"',
            vm.toString(floorValue),
            '","ladder":',
            tiers,
            "}"
        );
    }

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    function test_GenerateVectors() public {
        string memory bboCfg = "{}";

        // --- BBO: fee-free math book + 30bps WETH/USDC book ---
        _capture("bbo_fresh_sell0", "bbo", mathBook, address(math0), 1e18, bboCfg);
        _capture("bbo_fresh_sell1", "bbo", mathBook, address(math1), 200e18, bboCfg);
        _capture("bbo_fee_sell0", "bbo", wethBook, address(weth), 1e18, bboCfg);
        _capture("bbo_fee_sell1", "bbo", wethBook, address(usdc), 2001e6, bboCfg);
        _capture("bbo_size_exceeded", "bbo", wethBook, address(weth), 101e18, bboCfg);
        _capture("bbo_zero_output", "bbo", wethBook, address(weth), 1, bboCfg);

        vm.warp(START + FRESH_SECONDS + 3); // 300 bps decay
        _capture("bbo_decayed_sell0", "bbo", mathBook, address(math0), 1e18, bboCfg);
        _capture("bbo_decayed_sell1", "bbo", mathBook, address(math1), 206e18, bboCfg);
        vm.warp(START + VALID_SECONDS); // capped decay, last valid second
        _capture("bbo_decay_capped", "bbo", mathBook, address(math0), 1e18, bboCfg);
        vm.warp(START + VALID_SECONDS + 1);
        _capture("bbo_expired", "bbo", mathBook, address(math0), 1e18, bboCfg);
        vm.warp(START);

        // --- SolFi: slot-decay ramp ---
        _capture("solfi_fresh_sell1", "solfi", solfiBook, address(math1), 1e12, _solfiCfg());
        _capture("solfi_fresh_sell0", "solfi", solfiBook, address(math0), 1e12, _solfiCfg());
        vm.warp(START + 7);
        _capture("solfi_ramp7_sell1", "solfi", solfiBook, address(math1), 1e12, _solfiCfg());
        _capture("solfi_ramp7_sell0", "solfi", solfiBook, address(math0), 1e12, _solfiCfg());
        vm.warp(START + 25);
        _capture("solfi_stale_sell1", "solfi", solfiBook, address(math1), 1e12, _solfiCfg());
        vm.warp(START + 60);
        _capture("solfi_plateau_sell0", "solfi", solfiBook, address(math0), 123456789, _solfiCfg());
        vm.warp(START + 200);
        _capture("solfi_gate_expired", "solfi", solfiBook, address(math1), 1e12, _solfiCfg());
        vm.warp(START);

        // --- HumidiFi: mainnet-shaped constants ---
        _capture(
            "humidifi_small_sell0", "humidifi", humidifiBook, address(math0), 4e10, _humidifiCfg()
        );
        _capture(
            "humidifi_small_sell1", "humidifi", humidifiBook, address(math1), 1e14, _humidifiCfg()
        );
        _capture(
            "humidifi_kick_boundary",
            "humidifi",
            humidifiBook,
            address(math0),
            5_500_000_000,
            _humidifiCfg()
        );
        _capture(
            "humidifi_below_kick",
            "humidifi",
            humidifiBook,
            address(math0),
            5_499_999_999,
            _humidifiCfg()
        );
        _capture("humidifi_capped", "humidifi", humidifiBook, address(math0), 1e16, _humidifiCfg());

        // --- BisonFi: June haircut + ladder ---
        _capture(
            "bisonfi_fresh_sell0", "bisonfi", bisonfiBook, address(math0), 1e12, _bisonfiCfg(0)
        );
        _capture(
            "bisonfi_fresh_sell1", "bisonfi", bisonfiBook, address(math1), 1e14, _bisonfiCfg(1)
        );
        vm.warp(START + 2);
        _capture(
            "bisonfi_aged2_sell0", "bisonfi", bisonfiBook, address(math0), 1e12, _bisonfiCfg(0)
        );
        vm.warp(START + 5);
        _capture("bisonfi_stale_gate", "bisonfi", bisonfiBook, address(math0), 1e12, _bisonfiCfg(0));
        vm.warp(START);
        _capture(
            "bisonfi_tier1_active", "bisonfi", bisonfiBook, address(math0), 2e24, _bisonfiCfg(0)
        );
        _capture(
            "bisonfi_tier2_negative", "bisonfi", bisonfiBook, address(math0), 4e24, _bisonfiCfg(0)
        );
        _capture(
            "bisonfi_ratio_rejected", "bisonfi", bisonfiBook, address(math0), 8e24, _bisonfiCfg(0)
        );

        // --- Assemble and write ---
        string memory json = "[";
        for (uint256 i = 0; i < vecs.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", vecs[i]);
        }
        json = string.concat(json, "]");
        vm.writeFile("sdk/test-vectors.json", json);
        assertGt(vecs.length, 25);
    }
}
