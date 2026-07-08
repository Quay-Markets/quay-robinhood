// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {QuayTestBase} from "test/utils/QuayTestBase.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {QuayTypes} from "src/QuayTypes.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract QuoteUpdateSigTest is QuayTestBase {
    address internal signer;
    uint256 internal signerKey;
    address internal relayer;

    function setUp() public override {
        super.setUp();
        (signer, signerKey) = makeAddrAndKey("signer");
        relayer = makeAddr("relayer");
        vm.prank(maker);
        amm.setUpdater(wethBook, signer, true);
    }

    function _sign(bytes32 bookId, QuayTypes.QuoteState memory q, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, amm.hashQuoteUpdate(bookId, q));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // Digest scheme (pins the exact hashing an off-chain SDK must produce)
    // ------------------------------------------------------------------

    function test_DigestMatchesManualEip712Computation() public view {
        QuayTypes.QuoteState memory q = _wethQuote(2);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("QuaySharedLiquidityAMM")),
                keccak256(bytes("1")),
                block.chainid,
                address(amm)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                amm.QUOTE_UPDATE_TYPEHASH(),
                wethBook,
                q.nonce,
                q.freshUntil,
                q.validUntil,
                q.decayBpsPerSecond,
                q.maxDecayBps,
                q.bidPxX128,
                q.askPxX128,
                q.maxIn0,
                q.maxIn1,
                q.sourceHash
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        assertEq(amm.hashQuoteUpdate(wethBook, q), expected);
    }

    // ------------------------------------------------------------------
    // updateQuoteWithSig
    // ------------------------------------------------------------------

    function test_RelayedUpdateBySignedUpdater() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        bytes memory sig = _sign(wethBook, q, signerKey);

        vm.prank(relayer); // arbitrary submitter
        amm.updateQuoteWithSig(wethBook, q, sig);

        QuayTypes.QuoteState memory s = amm.getQuoteState(wethBook);
        assertEq(s.nonce, 2);
        assertEq(s.bidPxX128, q.bidPxX128);
        assertEq(s.updatedAt, uint64(block.timestamp));
    }

    function test_RevertSignerNotUpdater() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        QuayTypes.QuoteState memory q = _wethQuote(2);
        bytes memory sig = _sign(wethBook, q, strangerKey);

        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
    }

    function test_RevertTamperedQuote() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        bytes memory sig = _sign(wethBook, q, signerKey);

        q.bidPxX128 += 1; // relayer tampers after signing
        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
    }

    function test_RevertSignatureForOtherBook() public {
        vm.prank(maker);
        amm.setUpdater(mathBook, signer, true);

        QuayTypes.QuoteState memory q = _mathQuote(2);
        bytes memory sig = _sign(mathBook, q, signerKey);

        // Same payload replayed against a different book recovers a different
        // digest, so the signer check fails.
        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
    }

    function test_RevertReplay() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        bytes memory sig = _sign(wethBook, q, signerKey);

        vm.startPrank(relayer);
        amm.updateQuoteWithSig(wethBook, q, sig);
        vm.expectRevert(QuaySharedLiquidityAMM.StaleQuoteNonce.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
        vm.stopPrank();
    }

    function test_RevertDeactivatedSigner() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        bytes memory sig = _sign(wethBook, q, signerKey);

        vm.prank(maker);
        amm.setUpdater(wethBook, signer, false);

        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.NotUpdater.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
    }

    function test_RevertMalformedSignature() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        amm.updateQuoteWithSig(wethBook, q, hex"deadbe");
    }

    function test_SignedQuoteStillValidated() public {
        QuayTypes.QuoteState memory q = _wethQuote(2);
        q.maxIn0 = 0; // invalid payload, signed correctly
        bytes memory sig = _sign(wethBook, q, signerKey);

        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.BadQuote.selector);
        amm.updateQuoteWithSig(wethBook, q, sig);
    }

    // ------------------------------------------------------------------
    // batchUpdateQuotesWithSig
    // ------------------------------------------------------------------

    function test_BatchRelayedUpdates() public {
        vm.prank(maker);
        amm.setUpdater(mathBook, signer, true);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = wethBook;
        ids[1] = mathBook;
        QuayTypes.QuoteState[] memory quotes = new QuayTypes.QuoteState[](2);
        quotes[0] = _wethQuote(2);
        quotes[1] = _mathQuote(2);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ids[0], quotes[0], signerKey);
        sigs[1] = _sign(ids[1], quotes[1], signerKey);

        vm.prank(relayer);
        amm.batchUpdateQuotesWithSig(ids, quotes, sigs);

        assertEq(amm.getQuoteState(wethBook).nonce, 2);
        assertEq(amm.getQuoteState(mathBook).nonce, 2);
    }

    function test_BatchRevertLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        QuayTypes.QuoteState[] memory quotes = new QuayTypes.QuoteState[](1);
        bytes[] memory sigs = new bytes[](2);

        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.ArrayLengthMismatch.selector);
        amm.batchUpdateQuotesWithSig(ids, quotes, sigs);

        quotes = new QuayTypes.QuoteState[](2);
        sigs = new bytes[](1);
        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.ArrayLengthMismatch.selector);
        amm.batchUpdateQuotesWithSig(ids, quotes, sigs);
    }

    function test_BatchIsAtomic() public {
        vm.prank(maker);
        amm.setUpdater(mathBook, signer, true);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = wethBook;
        ids[1] = mathBook;
        QuayTypes.QuoteState[] memory quotes = new QuayTypes.QuoteState[](2);
        quotes[0] = _wethQuote(2);
        quotes[1] = _mathQuote(1); // stale nonce -> second update fails
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ids[0], quotes[0], signerKey);
        sigs[1] = _sign(ids[1], quotes[1], signerKey);

        vm.prank(relayer);
        vm.expectRevert(QuaySharedLiquidityAMM.StaleQuoteNonce.selector);
        amm.batchUpdateQuotesWithSig(ids, quotes, sigs);

        // First book's update was rolled back with the batch.
        assertEq(amm.getQuoteState(wethBook).nonce, 1);
    }
}
