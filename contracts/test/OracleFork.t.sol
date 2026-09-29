// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {MarketCalendar} from "../src/MarketCalendar.sol";
import {ChainlinkEquityOracle} from "../src/oracle/ChainlinkEquityOracle.sol";
import {WindowCache} from "../src/oracle/WindowCache.sol";
import {PriceData, PriceStatus} from "../src/interfaces/IEquityOracle.sol";

/// @title OracleForkTest
/// @notice OPTIONAL fork test against Robinhood Chain mainnet at the LATEST block (decision D4: no archive RPC, no
/// pinning). Skipped unless `ROBINHOOD_MAINNET_RPC_URL` is set. This is the only evidence that the adapter works
/// against REAL Chainlink feeds and real stock tokens; without it the adapter must not be called "integrated".
/// Addresses are read from `deployments/robinhood-mainnet.json` (kept out of `src`).
contract OracleForkTest is Test {
    struct Asset {
        string symbol;
        address feed;
        address token;
    }

    function _assets() internal view returns (Asset[] memory a) {
        string memory json = vm.readFile("../deployments/robinhood-mainnet.json");
        string[4] memory syms = ["AAPL", "NVDA", "TSLA", "SPY"];
        a = new Asset[](4);
        for (uint256 i; i < 4; ++i) {
            a[i] = Asset({
                symbol: syms[i],
                feed: vm.parseJsonAddress(json, string.concat(".assets.", syms[i], ".feed")),
                token: vm.parseJsonAddress(json, string.concat(".assets.", syms[i], ".token"))
            });
        }
    }

    function test_adapterReadsRealFeedsAndTokens() public {
        string memory url = vm.envOr("ROBINHOOD_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet");

        MarketCalendar calendar = new MarketCalendar(address(this), 1 days);
        WindowCache cache = new WindowCache(address(calendar));
        Asset[] memory assets = _assets();
        for (uint256 i; i < assets.length; ++i) {
            ChainlinkEquityOracle o = new ChainlinkEquityOracle(
                ChainlinkEquityOracle.Config({
                    feed: assets[i].feed,
                    collateralToken: assets[i].token,
                    windowCache: address(cache),
                    sequencerFeed: address(0), // no uptime feed exists on Robinhood Chain
                    sequencerGrace: 0,
                    maxAge: 25 hours,
                    freeAge: 1 hours,
                    corporateActionHorizon: 1 days,
                    deviationWad: 0.005e18,
                    ageHaircutWadPerHour: 0.002e18,
                    maxAgeHaircutWad: 0.05e18,
                    minPriceWad: 5e18,
                    maxPriceWad: 20_000e18
                })
            );
            assertEq(o.DECIMAL_SCALE(), 1e10, "feeds have 8 decimals");
            PriceData memory d = o.price();
            emit log_named_string("asset", assets[i].symbol);
            emit log_named_uint("priceWad", d.priceWad);
            emit log_named_uint("status", uint8(d.status));
            emit log_named_uint("age_s", block.timestamp - d.updatedAt);
            // a real, live feed: positive, plausible, and in a usable state (corporate-action pause or a bad round
            // would be a real finding, not a test to relax)
            assertTrue(d.status != PriceStatus.Invalid, "feed answer valid");
            assertTrue(d.status != PriceStatus.CorporateAction, "no corporate action in progress");
            assertTrue(d.status != PriceStatus.SequencerDown, "no sequencer feed configured");
            assertGt(d.priceWad, 5e18);
            assertLt(d.priceWad, 20_000e18);
            assertGt(d.haircutWad, 0);
            // peek and price agree on a fresh cache
            assertEq(uint8(o.peek().status), uint8(d.status));
            assertEq(o.peek().priceWad, d.priceWad);
        }
    }
}
