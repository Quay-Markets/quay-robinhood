// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {QuaySharedLiquidityAMM} from "src/QuaySharedLiquidityAMM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Bootstraps one stock market on an existing venue in a single run:
///      token allowlist -> liquidity group -> book -> updater (-> oracle
///      guard -> initial deposits, both optional). Idempotent where possible:
///      existing groups are reused, allowlisting is re-applied harmlessly.
///
/// Required env:
///   QUAY_VENUE       venue address
///   TOKEN0           stock token address (base)
///   TOKEN1           settlement token address (quote, e.g. USDG)
///   STRATEGY         approved strategy module address
///   UPDATER          first updater EOA for the book
///   GROUP_NAME       string; groupId = keccak256(bytes(GROUP_NAME))
///   MARKET_SALT      string; book salt = keccak256(bytes(MARKET_SALT))
/// Optional env:
///   FEE_BPS          protocol fee (default 0)
///   GROUP_OWNER      group owner (default: broadcaster)
///   ORACLE_FEED      Chainlink-style feed (default: none)
///   ORACLE_MAX_AGE   seconds (default 60)
///   ORACLE_DEV_BPS   deviation bound (default 200)
///   ORACLE_SCALE     priceScale (default 0 = must be set when feed given)
///   DEPOSIT0/1       initial inventory pulled from the broadcaster (default 0)
///
/// Run:
///   QUAY_VENUE=0x... TOKEN0=0x... TOKEN1=0x... STRATEGY=0x... UPDATER=0x... \
///   GROUP_NAME=maker1 MARKET_SALT=AAPL_USDG_V1 \
///   forge script script/SetupMarket.s.sol --rpc-url $RPC_URL --broadcast
contract SetupMarket is Script {
    function run() external returns (bytes32 bookId) {
        QuaySharedLiquidityAMM venue = QuaySharedLiquidityAMM(vm.envAddress("QUAY_VENUE"));
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address strategy = vm.envAddress("STRATEGY");
        address updater = vm.envAddress("UPDATER");
        bytes32 groupId = keccak256(bytes(vm.envString("GROUP_NAME")));
        bytes32 salt = keccak256(bytes(vm.envString("MARKET_SALT")));
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));

        vm.startBroadcast();
        address broadcaster = msg.sender;
        address groupOwner = vm.envOr("GROUP_OWNER", broadcaster);

        // 1. Token allowlist (owner-only; harmless to re-apply).
        if (!venue.isTokenAllowed(token0)) venue.setTokenAllowed(token0, true);
        if (!venue.isTokenAllowed(token1)) venue.setTokenAllowed(token1, true);

        // 2. Liquidity group (reused when it already exists).
        (, bool exists,,) = venue.liquidityGroups(groupId);
        if (!exists) venue.createLiquidityGroup(groupId, groupOwner);

        // 3. Book + updater.
        bookId = venue.createBook(token0, token1, groupId, salt, feeBps, strategy, updater);

        // 4. Optional oracle guard.
        address feed = vm.envOr("ORACLE_FEED", address(0));
        if (feed != address(0)) {
            venue.setBookOracle(
                bookId,
                feed,
                uint32(vm.envOr("ORACLE_MAX_AGE", uint256(60))),
                uint16(vm.envOr("ORACLE_DEV_BPS", uint256(200))),
                vm.envUint("ORACLE_SCALE")
            );
        }

        // 5. Optional initial inventory (broadcaster must be group owner or
        //    approve + deposit separately).
        uint256 deposit0 = vm.envOr("DEPOSIT0", uint256(0));
        uint256 deposit1 = vm.envOr("DEPOSIT1", uint256(0));
        if (deposit0 > 0) {
            IERC20(token0).approve(address(venue), deposit0);
            venue.deposit(groupId, token0, deposit0);
        }
        if (deposit1 > 0) {
            IERC20(token1).approve(address(venue), deposit1);
            venue.deposit(groupId, token1, deposit1);
        }
        vm.stopBroadcast();

        console.log("Market ready");
        console.log("  venue:  %s", address(venue));
        console.log("  bookId:");
        console.logBytes32(bookId);
        console.log("  groupId:");
        console.logBytes32(groupId);
    }
}
