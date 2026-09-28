// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {MarketCalendar} from "../src/MarketCalendar.sol";
import {UsMarketCalendar as Cal} from "../src/lib/UsMarketCalendar.sol";
import {ChainlinkEquityOracle} from "../src/oracle/ChainlinkEquityOracle.sol";
import {WindowCache} from "../src/oracle/WindowCache.sol";
import {IWindowCache, WindowState} from "../src/interfaces/IWindowCache.sol";
import {IEquityOracle, PriceData, PriceStatus} from "../src/interfaces/IEquityOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {SimEquityFeed} from "sim/SimEquityFeed.sol";

/// @dev Real calendar facts used below (computed independently with Python zoneinfo in M1):
/// Tue 2026-09-01 15:00 ET = 1788289200 (open). The next window is the Labor Day window
/// [Sat 2026-09-05 00:00Z, Tue 2026-09-08 00:00Z) = [1788566400, 1788825600) (Long). The previous window is the
/// weekend [Sat 2026-08-29 00:00Z, Mon 2026-08-31 00:00Z) = [1787961600, 1788134400). The window after Labor Day is
/// [Sat 2026-09-12 00:00Z, Mon 2026-09-14 00:00Z) = [1789171200, 1789344000).
abstract contract OracleBase is Test {
    uint256 internal constant T0 = 1_788_289_200;
    uint256 internal constant LD_START = 1_788_566_400;
    uint256 internal constant LD_END = 1_788_825_600;
    uint256 internal constant PREV_END = 1_788_134_400;
    uint256 internal constant NEXT_START = 1_789_171_200;
    uint256 internal constant NEXT_END = 1_789_344_000;

    MarketCalendar internal calendar;
    WindowCache internal cache;
    MockAggregator internal feed;
    MockStockToken internal token;
    ChainlinkEquityOracle internal oracle;

    function _config(address feed_, address seq, uint32 grace)
        internal
        view
        returns (ChainlinkEquityOracle.Config memory c)
    {
        c = ChainlinkEquityOracle.Config({
            feed: feed_,
            collateralToken: address(token),
            windowCache: address(cache),
            sequencerFeed: seq,
            sequencerGrace: grace,
            maxAge: 25 hours,
            freeAge: 1 hours,
            corporateActionHorizon: 1 days,
            deviationWad: 0.005e18,
            ageHaircutWadPerHour: 0.002e18,
            maxAgeHaircutWad: 0.05e18,
            minPriceWad: 1e18,
            maxPriceWad: 1_000_000e18
        });
    }

    function setUp() public virtual {
        vm.warp(T0);
        calendar = new MarketCalendar(address(this), 1 days);
        cache = new WindowCache(address(calendar));
        feed = new MockAggregator(8, 370e8);
        token = new MockStockToken();
        oracle = new ChainlinkEquityOracle(_config(address(feed), address(0), 0));
    }
}

contract WindowCacheTest is OracleBase {
    function test_stateMatchesCalendarFacts() public {
        WindowState memory w = cache.state();
        assertFalse(w.blind);
        assertEq(w.start, LD_START);
        assertEq(w.end, LD_END);
        assertEq(w.lastEnd, PREV_END);
        assertEq(w.cls, 2); // Long
        assertEq(w.windowId, Cal.dayIndex(2026, 9, 4));
        WindowState memory p = cache.peek();
        assertEq(p.start, w.start);
        assertEq(p.lastEnd, w.lastEnd);
        assertEq(p.windowId, w.windowId);
    }

    function test_blindInsideWindowAndRefreshAfterIt() public {
        cache.state();
        vm.warp(1_788_600_000); // Saturday, inside Labor Day weekend (cache still valid: < 24 h, < end)
        WindowState memory w = cache.state();
        assertTrue(w.blind);
        vm.warp(LD_END + 30); // after the window: the cache refreshes to the next window
        w = cache.state();
        assertFalse(w.blind);
        assertEq(w.start, NEXT_START);
        assertEq(w.end, NEXT_END);
        assertEq(w.lastEnd, LD_END);
        assertEq(w.cls, 1); // Weekend
    }

    function test_refreshesByTtlAndEmits() public {
        vm.recordLogs();
        cache.state();
        assertEq(vm.getRecordedLogs().length, 1, "first call refreshes");
        vm.warp(T0 + 23 hours);
        cache.state();
        assertEq(vm.getRecordedLogs().length, 0, "warm cache: no refresh within the TTL");
        vm.warp(T0 + 24 hours);
        cache.state();
        assertEq(vm.getRecordedLogs().length, 1, "refresh at the TTL");
    }

    function test_warmReadIsCheap() public {
        uint256 g = gasleft();
        cache.state(); // cold: scans the calendar and writes the cache
        uint256 cold = g - gasleft();
        g = gasleft();
        cache.state(); // warm: reads one packed slot
        uint256 warm = g - gasleft();
        // relative bound: robust to coverage instrumentation, which inflates absolute gas
        assertLt(warm * 8, cold, "a warm read costs a small fraction of a refresh");
    }

    function test_peekDoesNotWrite() public {
        WindowState memory a = cache.peek();
        WindowState memory b = cache.peek();
        assertEq(a.start, b.start);
        // nothing was cached: the first state() still refreshes
        vm.recordLogs();
        cache.state();
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_insideWindowHasPreviousLastEnd() public {
        vm.warp(LD_START + 1 days);
        WindowState memory w = cache.state();
        assertTrue(w.blind);
        assertEq(w.start, LD_START);
        assertEq(w.lastEnd, PREV_END);
    }

    function test_zeroCalendarRejected() public {
        vm.expectRevert(WindowCache.ZeroAddress.selector);
        new WindowCache(address(0));
    }
}

/// @dev Differential test of the cache against the independent Python oracle windows (research/calendar_oracle.py).
contract WindowCacheDifferentialTest is OracleBase {
    function test_cacheMatchesOracleWindowsAtRandomTimes() public {
        string memory fx = vm.readFile("test/fixtures/calendar_cases.json");
        uint256[] memory wStart = vm.parseJsonUintArray(fx, ".windows.start");
        uint256[] memory wEnd = vm.parseJsonUintArray(fx, ".windows.end");
        uint256[] memory wCls = vm.parseJsonUintArray(fx, ".windows.cls");
        uint256[] memory rTs = vm.parseJsonUintArray(fx, ".random.ts");
        uint256[] memory rBlind = vm.parseJsonUintArray(fx, ".random.blind");
        uint256[] memory rId = vm.parseJsonUintArray(fx, ".random.id");
        uint256 checked;
        for (uint256 i; i < 1500; ++i) {
            uint256 ts = rTs[i];
            // skip the first weeks of 2024: their previous window is not in the fixture
            if (ts < wEnd[1]) continue;
            // 2025-01-09 (national day of mourning) is a one-off closure that the oracle fixture knows and a plain
            // MarketCalendar cannot (closures must be announced >= 72 h ahead): skip the weeks around it
            if (ts >= 1_735_689_600 && ts < 1_737_331_200) continue;
            if (_checkOne(ts, wStart, wEnd, wCls, rBlind[i], rId[i])) ++checked;
        }
        assertGt(checked, 1400);
    }

    function _checkOne(
        uint256 ts,
        uint256[] memory wStart,
        uint256[] memory wEnd,
        uint256[] memory wCls,
        uint256 blind,
        uint256 id
    ) internal returns (bool) {
        vm.warp(ts);
        // first window ending after ts (binary search), then the one before it
        uint256 lo;
        uint256 hi = wEnd.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (wEnd[mid] > ts) hi = mid;
            else lo = mid + 1;
        }
        if (lo >= wEnd.length) return false; // past the last window in the fixture
        WindowState memory w = cache.peek();
        assertEq(w.blind ? 1 : 0, blind, "blind");
        assertEq(w.windowId, id, "windowId");
        assertEq(w.start, wStart[lo], "current-or-next start");
        assertEq(w.end, wEnd[lo], "current-or-next end");
        assertEq(w.cls, wCls[lo], "class");
        assertEq(w.lastEnd, wEnd[lo - 1], "lastEnd");
        // the writing path returns the same thing and a second call hits the cache
        WindowState memory w2 = cache.state();
        assertEq(w2.lastEnd, w.lastEnd);
        assertEq(cache.state().windowId, w.windowId);
        return true;
    }
}

contract ChainlinkEquityOracleTest is OracleBase {
    function _price() internal returns (PriceData memory d) {
        d = oracle.price();
        PriceData memory p = oracle.peek();
        assertEq(uint8(p.status), uint8(d.status), "peek == price: status");
        assertEq(p.priceWad, d.priceWad, "peek == price: price");
        assertEq(p.haircutWad, d.haircutWad, "peek == price: haircut");
    }

    function test_freshPriceNormalizedAndAllowanceOnly() public {
        feed.set(370e8, T0 - 10 minutes);
        PriceData memory d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Fresh));
        assertEq(d.priceWad, 370e18); // 8 -> 18 decimals
        assertEq(d.updatedAt, T0 - 10 minutes);
        assertEq(d.haircutWad, 0.005e18); // deviation allowance only: age below freeAge
        assertEq(d.windowId, Cal.dayIndex(2026, 9, 4));
    }

    function test_ageHaircutGrowsAndCaps() public {
        feed.set(370e8, T0 - 3 hours);
        assertEq(_price().haircutWad, 0.005e18 + 0.004e18); // 0.2 % per hour beyond 1 h
        feed.set(370e8, T0 - 20 hours);
        assertEq(_price().haircutWad, 0.005e18 + 0.038e18);
        feed.set(370e8, T0 - 25 hours);
        PriceData memory d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Fresh), "age == maxAge is still fresh");
        assertEq(d.haircutWad, 0.005e18 + 0.048e18);
    }

    function test_staleIsUnscheduledBlindness() public {
        feed.set(370e8, T0 - 25 hours - 1);
        PriceData memory d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Stale));
        feed.set(370e8, T0 - 40 hours);
        d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Stale));
        assertEq(d.haircutWad, 0.005e18 + 0.05e18, "age haircut capped");
    }

    function test_scheduledBlindWindowIsNotStale() public {
        vm.warp(1_788_700_000); // Sunday, inside the Labor Day window
        feed.set(370e8, LD_START - 3 hours); // last update hours before the window start
        PriceData memory d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.ScheduledBlind));
        assertEq(d.haircutWad, 0.005e18, "no age haircut inside a scheduled window");
        assertEq(d.priceWad, 370e18);
    }

    function test_reopeningUntilFirstPostWindowUpdate() public {
        vm.warp(LD_END + 30); // Tuesday 00:00:30Z, live again
        feed.set(370e8, LD_START - 3 hours); // price predates the window end
        PriceData memory d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Reopening));
        feed.set(372e8, LD_END + 20); // first update after the window (observed lag was 18-85 s)
        d = _price();
        assertEq(uint8(d.status), uint8(PriceStatus.Fresh));
        assertEq(d.priceWad, 372e18);
    }

    function test_invalidAnswers() public {
        feed.set(0, T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "zero");
        feed.set(-5, T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "negative");
        feed.set(int256(uint256(type(uint128).max) + 1), T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "absurd");
        feed.set(370e8, 0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "updatedAt zero");
        feed.set(370e8, T0 + 1);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "future updatedAt");
        feed.set(370e8, T0);
        feed.setRounds(5, 4);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "incomplete round");
        feed.setRounds(5, 5);
        feed.set(0.5e8, T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "below bound");
        feed.set(1e15, T0); // 1e15 / 1e8 = $10,000,000 per token > $1,000,000 bound
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "above bound");
        feed.set(370e8, T0);
        feed.setRevert(true);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid), "feed reverts");
        feed.setRevert(false);
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
    }

    function test_otherFeedDecimals() public {
        MockAggregator f6 = new MockAggregator(6, 370e6);
        ChainlinkEquityOracle o6 = new ChainlinkEquityOracle(_config(address(f6), address(0), 0));
        assertEq(o6.price().priceWad, 370e18);
        assertEq(o6.DECIMAL_SCALE(), 1e12);
        MockAggregator f19 = new MockAggregator(19, 370);
        ChainlinkEquityOracle.Config memory c = _config(address(f19), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("decimals")));
        new ChainlinkEquityOracle(c);
    }

    function test_corporateActionFlags() public {
        feed.set(370e8, T0);
        token.setOraclePaused(true);
        assertEq(uint8(_price().status), uint8(PriceStatus.CorporateAction), "oraclePaused");
        token.setOraclePaused(false);
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
        token.setPending(1.01e18, T0 + 1 hours); // split/dividend taking effect within the horizon
        assertEq(uint8(_price().status), uint8(PriceStatus.CorporateAction), "pending multiplier");
        token.setPending(1.01e18, T0 + 3 days); // beyond the horizon
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
        token.setPending(1e18, 0); // no pending change
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
    }

    function test_legacyTokenWithoutOraclePausedDoesNotFlag() public {
        token.setLegacy(true);
        feed.set(370e8, T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
    }

    function test_invalidOutranksCorporateAction() public {
        token.setOraclePaused(true);
        feed.set(0, T0);
        assertEq(uint8(_price().status), uint8(PriceStatus.Invalid));
    }

    function test_sequencerFeedOptional() public {
        MockAggregator seq = new MockAggregator(0, 0);
        ChainlinkEquityOracle withSeq = new ChainlinkEquityOracle(_config(address(feed), address(seq), 1 hours));
        feed.set(370e8, T0);
        seq.setStartedAt(0);
        assertEq(uint8(withSeq.price().status), uint8(PriceStatus.SequencerDown), "uninitialized (startedAt 0)");
        seq.setStartedAt(T0 - 100);
        assertEq(uint8(withSeq.price().status), uint8(PriceStatus.SequencerDown), "inside the grace period");
        seq.setStartedAt(T0 - 2 hours);
        assertEq(uint8(withSeq.price().status), uint8(PriceStatus.Fresh), "up and past the grace period");
        seq.set(1, T0);
        assertEq(uint8(withSeq.price().status), uint8(PriceStatus.SequencerDown), "reported down");
        seq.set(0, T0);
        seq.setRevert(true);
        assertEq(uint8(withSeq.price().status), uint8(PriceStatus.SequencerDown), "unreadable counts as down");
        // without a configured feed (Robinhood Chain) nothing is checked
        assertEq(uint8(_price().status), uint8(PriceStatus.Fresh));
    }

    function test_configValidation() public {
        ChainlinkEquityOracle.Config memory c = _config(address(feed), address(0), 0);
        c.feed = address(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("feed")));
        new ChainlinkEquityOracle(c);
        c = _config(address(feed), address(0), 0);
        c.collateralToken = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("collateralToken"))
        );
        new ChainlinkEquityOracle(c);
        c = _config(address(feed), address(0), 0);
        c.windowCache = address(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("windowCache")));
        new ChainlinkEquityOracle(c);
        c = _config(address(feed), address(0), 0);
        c.maxAge = 0;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("maxAge")));
        new ChainlinkEquityOracle(c);
        c = _config(address(feed), address(0), 0);
        c.minPriceWad = c.maxPriceWad;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("bounds")));
        new ChainlinkEquityOracle(c);
        c = _config(address(feed), address(0), 0);
        c.deviationWad = 1e18;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkEquityOracle.InvalidConfig.selector, bytes32("haircut")));
        new ChainlinkEquityOracle(c);
    }

    function test_gasOfPriceWithWarmCache() public {
        feed.set(370e8, T0);
        oracle.price(); // warm the window cache
        uint256 g = gasleft();
        oracle.price();
        uint256 used = g - gasleft();
        assertLt(used, 60_000, "oracle read with a warm window cache");
    }

    function test_simFeedIsAUsableButLabeledSimulation() public {
        SimEquityFeed sim = new SimEquityFeed(address(this), "SIM TSLA / USD (simulation)", 370e8);
        assertTrue(sim.IS_SIMULATION());
        assertEq(sim.decimals(), 8);
        ChainlinkEquityOracle o = new ChainlinkEquityOracle(_config(address(sim), address(0), 0));
        assertEq(uint8(o.price().status), uint8(PriceStatus.Fresh));
        assertEq(o.price().priceWad, 370e18);
        sim.publish(390e8);
        assertEq(o.price().priceWad, 390e18);
        (uint80 round,,,, uint80 answeredIn) = sim.latestRoundData();
        assertEq(round, 2);
        assertEq(answeredIn, 2);
        vm.prank(address(0xBEEF));
        vm.expectRevert(SimEquityFeed.NotKeeper.selector);
        sim.publish(1e8);
        vm.expectRevert(SimEquityFeed.InvalidAnswer.selector);
        new SimEquityFeed(address(this), "bad", 0);
    }
}
