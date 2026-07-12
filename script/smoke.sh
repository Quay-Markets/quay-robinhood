#!/usr/bin/env bash
# End-to-end smoke test on an Anvil fork of Robinhood Chain:
#   1. deploy venue + BBO strategy through real RPC
#   2. bootstrap an AAPL/USDG book on the REAL mainnet token addresses
#   3. bootstrap a mock market with inventory, run the quote daemon for a few
#      ticks (fixed price), and settle a real swap against its quote
#
# Usage: script/smoke.sh [fork-rpc-url]
#        (defaults to the URL in ../quay-demo/rpc.txt if present)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8547
RPC="http://127.0.0.1:${PORT}"
FORK_URL="${1:-$(cat ../quay-demo/rpc.txt 2>/dev/null || true)}"
[ -n "$FORK_URL" ] || { echo "no fork URL (arg or ../quay-demo/rpc.txt)"; exit 1; }

# Anvil's canonical dev accounts.
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADDR0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ADDR1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

AAPL=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168

cleanup() { kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "== starting anvil fork of Robinhood Chain =="
anvil --fork-url "$FORK_URL" --port "$PORT" --silent &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 0.5
done
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
echo "   chain id: $CHAIN_ID"

returns() { jq -r ".returns.\"$2\".value" "broadcast/$1/$CHAIN_ID/run-latest.json"; }

echo "== 1. deploying venue + BBOStrategy =="
QUAY_OWNER=$ADDR0 forge script script/Deploy.s.sol --rpc-url "$RPC" \
  --private-key "$PK0" --broadcast --skip-simulation -q >/dev/null
VENUE=$(returns Deploy.s.sol amm)
BBO=$(returns Deploy.s.sol bbo)
echo "   venue: $VENUE"
echo "   bbo:   $BBO"

echo "== 2. bootstrapping REAL AAPL/USDG book (mainnet token addresses) =="
QUAY_VENUE=$VENUE TOKEN0=$AAPL TOKEN1=$USDG STRATEGY=$BBO UPDATER=$ADDR0 \
  GROUP_NAME=smoke-real MARKET_SALT=AAPL_USDG_V1 \
  forge script script/SetupMarket.s.sol --rpc-url "$RPC" \
  --private-key "$PK0" --broadcast --skip-simulation -q >/dev/null
REAL_BOOK=$(returns SetupMarket.s.sol bookId)
echo "   bookId: $REAL_BOOK"
STATUS=$(cast call "$VENUE" "getBook(bytes32)((address,address,address,bytes32,uint16,uint8,uint64))" "$REAL_BOOK" --rpc-url "$RPC")
echo "$STATUS" | grep -qi "${AAPL#0x}" || { echo "FAIL: real book not registered"; exit 1; }
echo "   OK — real stock token accepted by allowlist + book registry"

echo "== 3. mock market with inventory =="
TAKER=$ADDR1 forge script script/DeployMocks.s.sol --rpc-url "$RPC" \
  --private-key "$PK0" --broadcast --skip-simulation -q >/dev/null
MSTOCK=$(returns DeployMocks.s.sol stock)
MCASH=$(returns DeployMocks.s.sol cash)
QUAY_VENUE=$VENUE TOKEN0=$MSTOCK TOKEN1=$MCASH STRATEGY=$BBO UPDATER=$ADDR0 \
  GROUP_NAME=smoke-mock MARKET_SALT=MOCK_V1 \
  DEPOSIT0=1000000000000000000000 DEPOSIT1=500000000000 \
  forge script script/SetupMarket.s.sol --rpc-url "$RPC" \
  --private-key "$PK0" --broadcast --skip-simulation -q >/dev/null
MOCK_BOOK=$(returns SetupMarket.s.sol bookId)
echo "   bookId: $MOCK_BOOK  (1,000 mAAPL + 500,000 mUSDG deposited)"

echo "== 4. quote daemon (fixed \$190, 3 ticks) =="
[ -d daemon/node_modules ] || (cd daemon && pnpm install --silent)
CFG=$(mktemp -t quay-smoke-XXXX).json
jq -n --arg venue "$VENUE" --arg book "$MOCK_BOOK" --arg stock "$MSTOCK" --arg cash "$MCASH" '{
  venue: $venue, bookId: $book, stockSymbol: "mAAPL",
  stockToken: $stock, stockDecimals: 18, quoteToken: $cash, quoteDecimals: 6,
  priceSource: "fixed", fixedPriceUsd: 190,
  spreadBps: 10, maxIn0: "100000000000000000000", maxIn1: "50000000000",
  freshSeconds: 3, validSeconds: 30, decayBpsPerSecond: 25, maxDecayBps: 100,
  intervalMs: 400
}' > "$CFG"
RPC_URL=$RPC UPDATER_PRIVATE_KEY=$PK0 DAEMON_MAX_TICKS=3 \
  node daemon/src/index.ts "$CFG"

echo "== 5. quote + swap through the live book =="
OUT=$(cast call "$VENUE" "getAmountOut(address,address,uint256)(uint256,bytes32)" \
  "$MCASH" "$MSTOCK" 1901900000 --rpc-url "$RPC")
AMOUNT_OUT=$(echo "$OUT" | head -1 | cut -d' ' -f1)
echo "   getAmountOut(1,901.90 mUSDG -> mAAPL): $AMOUNT_OUT"
[ "$AMOUNT_OUT" != "0" ] || { echo "FAIL: zero quote"; exit 1; }

cast send "$MCASH" "approve(address,uint256)" "$VENUE" 1901900000 \
  --rpc-url "$RPC" --private-key "$PK1" >/dev/null
BAL_BEFORE=$(cast call "$MSTOCK" "balanceOf(address)(uint256)" "$ADDR1" --rpc-url "$RPC" | cut -d' ' -f1)
cast send "$VENUE" \
  "swapExactInputSingle((bytes32,address,address,uint256,uint256,address,uint64,uint64,uint64))" \
  "($MOCK_BOOK,$MCASH,$MSTOCK,1901900000,1,$ADDR1,0,0,0)" \
  --rpc-url "$RPC" --private-key "$PK1" >/dev/null
BAL_AFTER=$(cast call "$MSTOCK" "balanceOf(address)(uint256)" "$ADDR1" --rpc-url "$RPC" | cut -d' ' -f1)
echo "   taker mAAPL: $BAL_BEFORE -> $BAL_AFTER"
[ "$BAL_AFTER" != "$BAL_BEFORE" ] || { echo "FAIL: swap did not settle"; exit 1; }

echo ""
echo "SMOKE PASSED: deploy -> real-token book -> daemon quotes -> quote -> swap"
