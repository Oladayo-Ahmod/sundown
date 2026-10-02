// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {MarketCalendar} from "../src/MarketCalendar.sol";
import {UsMarketCalendar} from "../src/lib/UsMarketCalendar.sol";
import {ChainlinkEquityOracle} from "../src/oracle/ChainlinkEquityOracle.sol";
import {WindowCache} from "../src/oracle/WindowCache.sol";
import {WindowState} from "../src/interfaces/IWindowCache.sol";
import {PriceData, PriceStatus} from "../src/interfaces/IEquityOracle.sol";

interface ILiveFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title OracleForkLiveTest
/// @notice OPTIONAL fork tests (skipped unless `ROBINHOOD_MAINNET_RPC_URL` is set) that validate the production
/// `ChainlinkEquityOracle` against the REAL Chainlink tokenized-equity feeds on Robinhood Chain mainnet at the LATEST
/// block (D4: no archive, no pinning). Nothing here is mocked: feeds, tokens and the calendar are the real ones. The
/// tests assert properties that hold in any market state and log the live values they saw. See
/// docs/ORACLE_LIVE_VALIDATION.md for the recorded run.
contract OracleForkLiveTest is Test {
    string[4] internal syms = ["SPY", "AAPL", "NVDA", "TSLA"];

    MarketCalendar internal calendar;
    WindowCache internal cache;
    string internal json;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("ROBINHOOD_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet");
        json = vm.readFile("../deployments/robinhood-mainnet.json");
        calendar = new MarketCalendar(address(this), 1 days);
        cache = new WindowCache(address(calendar));
        return true;
    }

    function _addr(string memory sym, string memory what) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".assets.", sym, ".", what));
    }

    function _oracle(address feed, address token, uint256 minP, uint256 maxP) internal returns (ChainlinkEquityOracle) {
        return new ChainlinkEquityOracle(
            ChainlinkEquityOracle.Config({
                feed: feed,
                collateralToken: token,
                windowCache: address(cache),
                sequencerFeed: address(0),
                sequencerGrace: 0,
                maxAge: 25 hours,
                freeAge: 1 hours,
                corporateActionHorizon: 1 days,
                deviationWad: 0.005e18,
                ageHaircutWadPerHour: 0.002e18,
                maxAgeHaircutWad: 0.05e18,
                minPriceWad: minP,
                maxPriceWad: maxP
            })
        );
    }

    /// @dev 8 -> WAD normalization against the live answer, and the feed is the asset we think it is.
    function test_live_decimalsNormalizationMatchesTheRawAnswer() public {
        if (!_fork()) return;
        for (uint256 i; i < 4; ++i) {
            ILiveFeed feed = ILiveFeed(_addr(syms[i], "feed"));
            ChainlinkEquityOracle o = _oracle(address(feed), _addr(syms[i], "token"), 5e18, 20_000e18);
            (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

            assertEq(feed.decimals(), 8, "live feed has 8 decimals");
            assertEq(o.DECIMAL_SCALE(), 1e10, "adapter scale is 10^(18 - 8)");
            assertGt(answer, 0, "live answer is positive");
            PriceData memory d = o.price();
            assertEq(d.priceWad, uint256(answer) * 1e10, "priceWad == raw answer * 1e10, exactly");
            assertEq(d.updatedAt, updatedAt, "adapter reports the feed's own updatedAt");
            assertTrue(vm.contains(feed.description(), syms[i]), "feed description names the asset");

            emit log_named_string("asset", syms[i]);
            emit log_named_string("feed description", feed.description());
            emit log_named_int("raw answer (8 decimals)", answer);
            emit log_named_decimal_uint("priceWad (USD)", d.priceWad, 18);
            emit log_named_uint("updatedAt", d.updatedAt);
            emit log_named_uint("block.timestamp", block.timestamp);
            emit log_named_uint("age (s)", block.timestamp - d.updatedAt);
            emit log_named_uint("status", uint8(d.status));
        }
    }

    /// @dev The adapter's status at the current block agrees with the calendar (read directly, not through the
    /// adapter's cache) in whichever state the market is in now.
    function test_live_statusMatchesTheCalendarAtTheCurrentBlock() public {
        if (!_fork()) return;
        (bool blind, uint64 start, uint64 end, UsMarketCalendar.WindowClass cls) =
            calendar.blindWindowAt(block.timestamp);
        emit log_named_uint("block.timestamp", block.timestamp);
        emit log_named_string("calendar says", blind ? "inside a blind window" : "not in a blind window");
        emit log_named_uint("window start (current or next)", start);
        emit log_named_uint("window end", end);
        emit log_named_uint("window class (0 Short, 1 Weekend, 2 Long)", uint8(cls));

        for (uint256 i; i < 4; ++i) {
            ChainlinkEquityOracle o = _oracle(_addr(syms[i], "feed"), _addr(syms[i], "token"), 5e18, 20_000e18);
            PriceData memory d = o.price();
            uint256 age = block.timestamp - d.updatedAt;
            emit log_named_string("asset", syms[i]);
            emit log_named_uint("status", uint8(d.status));
            emit log_named_uint("age (s)", age);
            if (blind) {
                assertEq(uint8(d.status), uint8(PriceStatus.ScheduledBlind), "inside a window: ScheduledBlind");
                assertEq(d.haircutWad, o.DEVIATION_WAD(), "blind haircut is the deviation allowance only");
                // observation (not asserted: a feed may legitimately update at the window edge)
                emit log_named_int(
                    "updatedAt minus window start (s)", int256(uint256(d.updatedAt)) - int256(uint256(start))
                );
            } else {
                assertTrue(d.status != PriceStatus.ScheduledBlind, "outside a window: never ScheduledBlind");
                WindowState memory w = cache.peek();
                PriceStatus expected = d.updatedAt < w.lastEnd
                    ? PriceStatus.Reopening
                    : (age > 25 hours ? PriceStatus.Stale : PriceStatus.Fresh);
                assertEq(uint8(d.status), uint8(expected), "classification follows the window end and the age");
            }
            // the status never conflicts with peek()
            assertEq(uint8(o.peek().status), uint8(d.status));
        }
    }

    /// @dev Wrong feed addresses are rejected, each by a different mechanism; the limits are stated in the asserts.
    function test_live_wrongFeedAddressesAreRejected() public {
        if (!_fork()) return;
        address aaplToken = _addr("AAPL", "token");
        address aaplFeed = _addr("AAPL", "feed");
        address spyFeed = _addr("SPY", "feed");
        address usdg = vm.parseJsonAddress(json, ".usdg.address");

        // 1. an address with no code cannot be a feed: rejected at construction
        address nothing = makeAddr("no code here");
        vm.expectRevert();
        _oracle(nothing, aaplToken, 5e18, 20_000e18);

        // 2. a real contract that is not a feed (USDG answers decimals() but has no latestRoundData): the adapter
        // constructs and then reports Invalid, never a price
        ChainlinkEquityOracle notAFeed = _oracle(usdg, aaplToken, 5e18, 20_000e18);
        PriceData memory d = notAFeed.price();
        assertEq(uint8(d.status), uint8(PriceStatus.Invalid), "non-feed contract: Invalid");
        assertEq(d.priceWad, 0, "and no price");

        // 3. the stock token itself as a feed: same
        ChainlinkEquityOracle tokenAsFeed = _oracle(aaplToken, aaplToken, 5e18, 20_000e18);
        assertEq(uint8(tokenAsFeed.price().status), uint8(PriceStatus.Invalid), "token as feed: Invalid");

        // 4. another asset's REAL feed (SPY, about 770 USD) wired to AAPL's configuration (price bounds 200-500 USD):
        // rejected by the configured price bounds. The adapter has NO on-chain asset-identity check: a wrong feed
        // whose price falls inside the bounds would be accepted, so the bounds must bracket the asset's real range
        // (and the deployer must check the feed description, which the first test does off-chain).
        ChainlinkEquityOracle wrongAsset = _oracle(spyFeed, aaplToken, 200e18, 500e18);
        assertEq(
            uint8(wrongAsset.price().status),
            uint8(PriceStatus.Invalid),
            "wrong asset's feed outside the bounds: Invalid"
        );
        ChainlinkEquityOracle rightAsset = _oracle(aaplFeed, aaplToken, 200e18, 500e18);
        PriceData memory ok = rightAsset.price();
        assertTrue(ok.status != PriceStatus.Invalid, "the right feed with the same bounds is accepted");
        assertGt(ok.priceWad, 200e18);
        assertLt(ok.priceWad, 500e18);
    }
}
