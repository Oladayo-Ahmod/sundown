// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UsMarketCalendar as Cal} from "../src/lib/UsMarketCalendar.sol";
import {CalendarHarness} from "./mocks/CalendarHarness.sol";

/// @dev Shared helpers: ad-hoc closure bitmap + window assertions. All expected UTC constants in the named tests
/// were computed independently with Python zoneinfo (not with this library).
abstract contract CalendarBase is Test {
    mapping(uint256 day => bool closed) internal _adHocClosed;

    function _adHoc(uint256 day) internal view returns (bool) {
        return _adHocClosed[day];
    }

    /// @dev Asserts the window containing `mid` and its edges, the `next` lookup, the id and the length.
    function _checkWindow(uint256 mid, uint64 start, uint64 end, Cal.WindowClass cls, uint256 hoursLong) internal view {
        (bool inside, uint64 s, uint64 e, Cal.WindowClass c) = Cal.blindWindowAt(mid, _adHoc);
        assertTrue(inside, "inside");
        assertEq(s, start, "start");
        assertEq(e, end, "end");
        assertEq(uint8(c), uint8(cls), "class");
        assertEq(uint256(e - s), hoursLong * 1 hours, "length");
        assertTrue(Cal.isBlind(start, _adHoc), "blind at start");
        assertFalse(Cal.isBlind(start - 1, _adHoc), "not blind before start");
        assertTrue(Cal.isBlind(end - 1, _adHoc), "blind at end-1");
        assertFalse(Cal.isBlind(end, _adHoc), "not blind at end");
        (uint64 ns, uint64 ne, Cal.WindowClass nc) = Cal.nextBlindWindow(start - 1, _adHoc);
        assertEq(ns, start, "next start");
        assertEq(ne, end, "next end");
        assertEq(uint8(nc), uint8(cls), "next class");
        assertEq(Cal.windowId(mid, _adHoc), Cal.windowIdOfStart(start), "id");
        assertEq(Cal.windowId(start - 1, _adHoc), Cal.windowIdOfStart(start), "id before = next window");
    }
}

contract UsMarketCalendarNamedTest is CalendarBase {
    CalendarHarness internal h;

    function setUp() public {
        h = new CalendarHarness();
    }

    // ---------------------------------------------------------------- DST

    function test_springForward2024() public view {
        // Sun 2024-03-10: 02:00 EST -> 03:00 EDT at 07:00Z.
        assertEq(h.etOffset(1_710_054_000 - 1), 5 hours);
        assertEq(h.etOffset(1_710_054_000), 4 hours);
        // Fri Mar 8 20:00 EST -> Sun Mar 10 20:00 EDT = 47 h, still class Weekend.
        _checkWindow(1_709_946_000 + 1 days, 1_709_946_000, 1_710_115_200, Cal.WindowClass.Weekend, 47);
    }

    function test_springForward2026() public view {
        assertEq(h.etOffset(1_772_953_200 - 1), 5 hours);
        assertEq(h.etOffset(1_772_953_200), 4 hours);
        _checkWindow(1_772_845_200 + 1 days, 1_772_845_200, 1_773_014_400, Cal.WindowClass.Weekend, 47);
    }

    function test_fallBack2026() public view {
        assertEq(h.etOffset(1_793_512_800 - 1), 4 hours);
        assertEq(h.etOffset(1_793_512_800), 5 hours);
        // Fri Oct 30 20:00 EDT -> Sun Nov 1 20:00 EST = 49 h, class Weekend.
        _checkWindow(1_793_404_800 + 1 days, 1_793_404_800, 1_793_581_200, Cal.WindowClass.Weekend, 49);
    }

    function test_fallBackRepeatedHour() public view {
        // 01:30 EDT (05:30Z) and the repeated 01:30 EST (06:30Z) on Sun 2026-11-01: both inside the weekend window,
        // with the correct (different) UTC offsets.
        assertEq(h.etOffset(1_793_511_000), 4 hours);
        assertEq(h.etOffset(1_793_514_600), 5 hours);
        assertTrue(h.isBlind(1_793_511_000));
        assertTrue(h.isBlind(1_793_514_600));
        assertEq(uint8(h.sessionAt(1_793_511_000)), uint8(Cal.Session.Closed));
        assertEq(uint8(h.sessionAt(1_793_514_600)), uint8(Cal.Session.Closed));
    }

    // ---------------------------------------------------------------- holidays

    function test_goodFriday2026() public view {
        // Easter 2026-04-05, Good Friday Apr 3. Closed Fri/Sat/Sun -> Long.
        _checkWindow(1_775_174_400 + 1 days, 1_775_174_400, 1_775_433_600, Cal.WindowClass.Long, 72);
    }

    function test_goodFriday2027() public view {
        // Easter 2027-03-28, Good Friday Mar 26.
        _checkWindow(1_806_019_200 + 1 days, 1_806_019_200, 1_806_278_400, Cal.WindowClass.Long, 72);
    }

    function test_thanksgivingWeek2026() public view {
        // Thu Nov 26 closed: Wed 20:00 -> Thu 20:00 EST, Short.
        _checkWindow(1_795_654_800 + 1 hours, 1_795_654_800, 1_795_741_200, Cal.WindowClass.Short, 24);
        // Fri Nov 27 is an early close but boundaries do NOT move (UNVERIFIED assumption): next window is the
        // ordinary Fri 20:00 -> Sun 20:00 weekend.
        assertTrue(Cal.isEarlyClose(1_795_827_600 - 6 hours));
        _checkWindow(1_795_827_600 + 1 days, 1_795_827_600, 1_796_000_400, Cal.WindowClass.Weekend, 48);
    }

    function test_independenceDayOnSaturday2026() public view {
        // Sat Jul 4 2026 -> observed Fri Jul 3. Window Thu Jul 2 20:00 -> Sun Jul 5 20:00 (matches the Robinhood
        // feed: first update after at Mon 2026-07-06 00:00Z).
        _checkWindow(1_783_036_800 + 1 days, 1_783_036_800, 1_783_296_000, Cal.WindowClass.Long, 72);
        // Jul 2 2026 is NOT an early close (Jul 3 is the holiday).
        assertFalse(Cal.isEarlyClose(1_783_036_800 - 5 hours));
    }

    function test_independenceDayOnSunday2027() public view {
        // Sun Jul 4 2027 -> observed Mon Jul 5.
        _checkWindow(1_814_572_800 + 1 days, 1_814_572_800, 1_814_832_000, Cal.WindowClass.Long, 72);
    }

    function test_christmasOnSaturday2027() public view {
        // Sat Dec 25 2027 -> observed Fri Dec 24 (not an early close).
        _checkWindow(1_829_610_000 + 1 days, 1_829_610_000, 1_829_869_200, Cal.WindowClass.Long, 72);
    }

    function test_christmasOnSunday2033() public view {
        // Sun Dec 25 2033 -> observed Mon Dec 26.
        _checkWindow(2_018_998_800 + 1 days, 2_018_998_800, 2_019_258_000, Cal.WindowClass.Long, 72);
    }

    function test_newYearOnSaturday2028IsNotObserved() public view {
        // Sat Jan 1 2028: Fri Dec 31 2027 stays open (day index 21183).
        assertTrue(Cal.isTradingDay(21_183 * 1 days + 17 hours, _adHoc));
        // Window is the ordinary weekend after Friday's close.
        _checkWindow(1_830_301_200 + 1 days, 1_830_301_200, 1_830_474_000, Cal.WindowClass.Weekend, 48);
    }

    function test_newYearOnSunday2023ObservedMonday() public view {
        _checkWindow(1_672_448_400 + 1 days, 1_672_448_400, 1_672_707_600, Cal.WindowClass.Long, 72);
    }

    function test_laborDay2026EndsMondayEvening() public view {
        // Fri Sep 4 20:00 EDT -> Mon Sep 7 20:00 EDT: Long (n = 3). Matches the observed Chainlink update at Tue
        // 2026-09-08 00:00Z.
        _checkWindow(1_788_566_400 + 1 days, 1_788_566_400, 1_788_825_600, Cal.WindowClass.Long, 72);
        assertTrue(h.isBlind(1_788_796_800)); // Mon 12:00 ET holiday
        assertEq(uint8(h.sessionAt(1_788_796_800)), uint8(Cal.Session.Closed));
    }

    function test_midweekHolidayIsShort24h() public view {
        // Wed 2024-06-19 (Juneteenth): Tue 20:00 -> Wed 20:00 EDT.
        _checkWindow(1_718_755_200 + 2 hours, 1_718_755_200, 1_718_841_600, Cal.WindowClass.Short, 24);
    }

    function test_juneteenthFriday2026() public view {
        _checkWindow(1_781_827_200 + 1 days, 1_781_827_200, 1_782_086_400, Cal.WindowClass.Long, 72);
    }

    function test_juneteenthNotAHolidayBefore2022() public view {
        // Fri 2021-06-18 and Mon 2021-06-21 were open; Fri 2022-06-17 was the observed holiday (Jun 19 = Sunday ->
        // Monday Jun 20, 2022).
        assertTrue(Cal.isTradingDay(Cal.dayIndex(2021, 6, 18) * 1 days + 17 hours, _adHoc));
        assertTrue(Cal.isTradingDay(Cal.dayIndex(2021, 6, 21) * 1 days + 17 hours, _adHoc));
        assertFalse(Cal.isTradingDay(Cal.dayIndex(2022, 6, 20) * 1 days + 17 hours, _adHoc));
    }

    function test_ruleOnlyCalendarMissesAdHocClosure() public {
        // 2025-01-09 (national day of mourning for President Carter) is not derivable from rules.
        uint256 day = Cal.dayIndex(2025, 1, 9);
        uint256 noon = day * 1 days + 17 hours;
        assertTrue(Cal.isTradingDay(noon, _adHoc), "rules alone: open");
        _adHocClosed[day] = true;
        assertFalse(Cal.isTradingDay(noon, _adHoc), "with ad-hoc closure: closed");
        uint64 start = Cal.slotStart(day);
        _checkWindow(start + 1 hours, start, start + 1 days, Cal.WindowClass.Short, 24);
    }

    // ---------------------------------------------------------------- early-close config (UNVERIFIED flip)

    function test_earlyCloseFlipMovesWindowStart() public view {
        // 17:00 ET on Fri 2026-11-27 (day after Thanksgiving, early close) -> window starts at 17:00 EST (22:00Z).
        uint256 start = 1_795_816_800;
        (bool inside, uint64 s, uint64 e,) = h.blindWindowAtWith(start, 17 hours);
        assertTrue(inside);
        assertEq(s, start);
        assertEq(e, 1_796_000_400);
        (inside,,,) = h.blindWindowAtWith(start - 1, 17 hours);
        assertFalse(inside);
        // default config: not blind at 17:00 ET.
        (inside,,,) = h.blindWindowAtWith(start, 20 hours);
        assertFalse(inside);
        (uint64 ns,,) = h.nextBlindWindowWith(start - 1 days, 17 hours);
        assertEq(ns, start);
        assertEq(h.secondsUntilBlindWith(start - 100, 17 hours), 100);
        assertEq(h.secondsUntilBlindWith(start, 17 hours), 0);
        assertEq(h.windowIdWith(start, 17 hours), h.windowIdOfStart(start));
        assertEq(uint8(h.sessionAtWith(start, 17 hours)), uint8(Cal.Session.Closed));
        assertEq(uint8(h.sessionAtWith(start, 20 hours)), uint8(Cal.Session.PostMarket));
    }

    function test_earlyCloseFlipChristmasEve2026() public view {
        // Thu Dec 24 2026 early close and Fri Dec 25 holiday: flipped window starts Thu 17:00 EST.
        (uint64 ns, uint64 ne, Cal.WindowClass c) = h.nextBlindWindowWith(1_798_149_600 - 1 days, 17 hours);
        assertEq(ns, 1_798_149_600);
        assertEq(ne, 1_798_419_600);
        assertEq(uint8(c), uint8(Cal.WindowClass.Long));
    }

    // ---------------------------------------------------------------- display session + marketStatus

    function test_sessionBoundaries() public view {
        // Tue 2026-09-08: 04:00 Pre, 09:30 Regular, 16:00 Post, 20:00 Overnight (slot of Wed).
        uint256 t0400 = 1_788_854_400;
        uint256 t0930 = 1_788_874_200;
        uint256 t1600 = 1_788_897_600;
        uint256 t2000 = 1_788_912_000;
        assertEq(uint8(h.sessionAt(t0400 - 1)), uint8(Cal.Session.Overnight));
        assertEq(uint8(h.sessionAt(t0400)), uint8(Cal.Session.PreMarket));
        assertEq(uint8(h.sessionAt(t0930 - 1)), uint8(Cal.Session.PreMarket));
        assertEq(uint8(h.sessionAt(t0930)), uint8(Cal.Session.Regular));
        assertEq(uint8(h.sessionAt(t1600 - 1)), uint8(Cal.Session.Regular));
        assertEq(uint8(h.sessionAt(t1600)), uint8(Cal.Session.PostMarket));
        assertEq(uint8(h.sessionAt(t2000 - 1)), uint8(Cal.Session.PostMarket));
        assertEq(uint8(h.sessionAt(t2000)), uint8(Cal.Session.Overnight));
        // Early close day Fri 2026-11-27: regular ends 13:00 ET (18:00Z), then PostMarket (display assumption).
        uint256 t1300 = 1_795_827_600 - 7 hours; // Fri 13:00 EST
        assertEq(uint8(h.sessionAt(t1300 - 1)), uint8(Cal.Session.Regular));
        assertEq(uint8(h.sessionAt(t1300)), uint8(Cal.Session.PostMarket));
    }

    function test_marketStatusMapping() public view {
        assertEq(h.marketStatusOf(Cal.Session.Closed), 5);
        assertEq(h.marketStatusOf(Cal.Session.PreMarket), 1);
        assertEq(h.marketStatusOf(Cal.Session.Regular), 2);
        assertEq(h.marketStatusOf(Cal.Session.PostMarket), 3);
        assertEq(h.marketStatusOf(Cal.Session.Overnight), 4);
    }

    // ---------------------------------------------------------------- trading-day times, range, reverts

    function test_tradingDayTimes() public view {
        uint256 ts = 1_788_874_200 + 1 hours; // Tue 2026-09-08 10:30 ET
        assertEq(h.tradingDayOpen(ts), 1_788_825_600); // Mon 20:00 EDT = Tue 00:00Z
        assertEq(h.tradingDayClose(ts), 1_788_912_000); // Tue 20:00 EDT = Wed 00:00Z
        assertEq(h.regularOpen(ts), 1_788_874_200);
        assertEq(h.regularClose(ts), 1_788_897_600);
        // early-close day regular close 13:00 ET
        assertEq(h.regularClose(1_795_827_600 - 6 hours), 1_795_827_600 - 7 hours);
    }

    function test_notTradingDayReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, 1_788_796_800));
        h.tradingDayOpen(1_788_796_800); // Labor Day
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, 1_788_796_800));
        h.tradingDayClose(1_788_796_800);
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, 1_788_796_800));
        h.regularOpen(1_788_796_800);
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, 1_788_796_800));
        h.regularClose(1_788_796_800);
    }

    function test_rangeBoundaries() public {
        uint256 lo = 1_577_836_800; // 2020-01-01T00:00Z
        uint256 hi = 2_240_611_200; // 2041-01-01T00:00Z (exclusive)
        h.isBlind(lo);
        h.isBlind(hi - 1);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, lo - 1));
        h.isBlind(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.isBlind(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.nextBlindWindow(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.isTradingDay(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.isEarlyClose(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, lo - 1));
        h.checkRange(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.windowId(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.secondsUntilBlind(hi);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, hi));
        h.sessionAt(hi);
    }

    function test_windowsNearRangeEdges() public view {
        // Windows may extend just outside the supported domain; evaluation is still correct.
        (uint64 s,,) = h.nextBlindWindow(2_240_611_200 - 10 days);
        assertGt(s, 2_240_611_200 - 10 days);
    }

    // ---------------------------------------------------------------- bounded scans (long ad-hoc runs)

    function _closeRange(uint256 y, uint256 m, uint256 d0, uint256 d1) internal {
        uint256 first = Cal.dayIndex(y, m, d0);
        for (uint256 i; i <= d1 - d0; ++i) {
            h.setAdHoc(first + i, true);
        }
    }

    function test_closedRunTooLongBackward() public {
        _closeRange(2030, 1, 2, 31); // Jan 2-31 2030 closed (30 days incl. weekends)
        uint256 tsEnd = (Cal.dayIndex(2030, 1, 30)) * 1 days + 17 hours;
        vm.expectRevert(Cal.ClosedRunTooLong.selector);
        h.blindWindowAt(tsEnd);
    }

    function test_closedRunTooLongForward() public {
        _closeRange(2030, 1, 2, 31);
        uint256 tsStart = (Cal.dayIndex(2030, 1, 3)) * 1 days + 17 hours;
        vm.expectRevert(Cal.ClosedRunTooLong.selector);
        h.windowId(tsStart);
    }

    function test_scanExceeded() public {
        _closeRange(2030, 1, 2, 31);
        uint256 ts = (Cal.dayIndex(2030, 1, 5)) * 1 days + 17 hours;
        vm.expectRevert(Cal.ScanExceeded.selector);
        h.nextBlindWindow(ts);
        vm.expectRevert(Cal.ClosedRunTooLong.selector); // _windowAt scans the run before the next-window search
        h.secondsUntilBlindWith(ts, 20 hours);
    }

    function test_longRunWithinBoundIsReported() public {
        // 10 closed weekdays + surrounding weekends = 12 closed days <= MAX_CLOSED_RUN in each direction.
        _closeRange(2030, 3, 4, 15);
        uint256 ts = Cal.dayIndex(2030, 3, 8) * 1 days + 17 hours;
        (bool inside, uint64 s, uint64 e, Cal.WindowClass c) = h.blindWindowAt(ts);
        assertTrue(inside);
        assertEq(uint8(c), uint8(Cal.WindowClass.Long));
        assertGt(e, s);
    }
}

contract UsMarketCalendarDifferentialTest is CalendarBase {
    string internal fx;

    function setUp() public {
        fx = vm.readFile("test/fixtures/calendar_cases.json");
        uint256[] memory adhoc = vm.parseJsonUintArray(fx, ".adhoc");
        for (uint256 i; i < adhoc.length; ++i) {
            _adHocClosed[adhoc[i]] = true;
        }
    }

    /// @dev Walks the oracle's window list through `nextBlindWindow` so extra or missing windows both fail.
    function test_windowChainMatchesOracle() public view {
        uint256[] memory st = vm.parseJsonUintArray(fx, ".windows.start");
        uint256[] memory en = vm.parseJsonUintArray(fx, ".windows.end");
        uint256[] memory cl = vm.parseJsonUintArray(fx, ".windows.cls");
        uint256[] memory id = vm.parseJsonUintArray(fx, ".windows.id");
        assertGt(st.length, 600, "fixture has all windows 2024-2035");
        uint256 cursor = st[0] - 1;
        for (uint256 i; i < st.length; ++i) {
            cursor = _chainStep(cursor, st[i], en[i], cl[i], id[i]);
        }
    }

    function _chainStep(uint256 cursor, uint256 st, uint256 en, uint256 cl, uint256 id)
        internal
        view
        returns (uint256)
    {
        (uint64 s, uint64 e, Cal.WindowClass c) = Cal.nextBlindWindow(cursor, _adHoc);
        assertEq(s, st, "chain start");
        assertEq(e, en, "chain end");
        assertEq(uint256(c), cl, "chain class");
        assertEq(Cal.windowIdOfStart(s), id, "chain id");
        (bool inside, uint64 s2, uint64 e2, Cal.WindowClass c2) = Cal.blindWindowAt(st + (en - st) / 2, _adHoc);
        assertTrue(inside);
        assertEq(s2, st);
        assertEq(e2, en);
        assertEq(uint256(c2), cl);
        return s;
    }

    function test_isTradingDayForEveryCalendarDay() public view {
        uint256[] memory sessions = vm.parseJsonUintArray(fx, ".sessions");
        uint256 first = sessions[0];
        uint256 last = sessions[sessions.length - 1];
        bool[] memory isSession = new bool[](last - first + 1);
        for (uint256 i; i < sessions.length; ++i) {
            isSession[sessions[i] - first] = true;
        }
        // every calendar day 2024-2035 (weekends, holidays, trading days)
        for (uint256 d = first; d <= last; ++d) {
            assertEq(Cal.isTradingDay(d * 1 days + 17 hours, _adHoc), isSession[d - first], "isTradingDay");
        }
    }

    function test_tradingDayAndRegularTimes() public view {
        uint256[] memory tdClose = vm.parseJsonUintArray(fx, ".tdClose");
        uint256[] memory tdOpen = vm.parseJsonUintArray(fx, ".tdOpen");
        uint256[] memory rOpen = vm.parseJsonUintArray(fx, ".regOpen");
        uint256[] memory rClose = vm.parseJsonUintArray(fx, ".regClose");
        for (uint256 i; i < tdClose.length; ++i) {
            uint256 ts = tdClose[i] - 6 hours; // 14:00 ET on the session date
            assertEq(Cal.tradingDayOpen(ts, _adHoc), tdOpen[i], "tdOpen");
            assertEq(Cal.tradingDayClose(ts, _adHoc), tdClose[i], "tdClose");
            assertEq(Cal.regularOpen(ts), rOpen[i], "regOpen");
            assertEq(Cal.regularClose(ts), rClose[i], "regClose");
        }
    }

    function test_earlyClosesAndHolidays() public view {
        uint256[] memory sessions = vm.parseJsonUintArray(fx, ".sessions");
        uint256[] memory early = vm.parseJsonUintArray(fx, ".earlyCloses");
        uint256[] memory holidays = vm.parseJsonUintArray(fx, ".holidays");
        assertGt(early.length, 20, "early closes present");
        assertGt(holidays.length, 100, "holidays present");
        uint256 first = sessions[0];
        bool[] memory isEarly = new bool[](sessions[sessions.length - 1] - first + 1);
        for (uint256 i; i < early.length; ++i) {
            isEarly[early[i] - first] = true;
        }
        // isEarlyClose is true exactly on the oracle's early-close dates, over every trading day
        for (uint256 i; i < sessions.length; ++i) {
            assertEq(Cal.isEarlyClose(sessions[i] * 1 days + 17 hours), isEarly[sessions[i] - first], "isEarlyClose");
        }
        // every oracle weekday closure is closed (the ad-hoc one through the bitmap) and never an early close
        for (uint256 i; i < holidays.length; ++i) {
            assertFalse(Cal.isTradingDay(holidays[i] * 1 days + 17 hours, _adHoc), "holiday");
            assertFalse(Cal.isEarlyClose(holidays[i] * 1 days + 17 hours), "holiday not early");
        }
    }

    function test_dstTransitionsMatchZoneinfo() public view {
        uint256[] memory ts = vm.parseJsonUintArray(fx, ".dst.ts");
        uint256[] memory off = vm.parseJsonUintArray(fx, ".dst.offset");
        assertEq(ts.length, 126);
        for (uint256 i; i < ts.length; ++i) {
            assertEq(Cal.etOffset(ts[i]), off[i], "ET offset around DST transition");
        }
    }

    function test_randomTimestampsMatchOracle() public view {
        _compareRows(".random", 20_000);
    }

    function test_windowBoundariesMatchOracle() public view {
        _compareRows(".boundary", 0);
    }

    /// @dev The rules-only (no ad-hoc function) API against the oracle, skipping the window around the one-off
    /// 2025-01-09 closure which rules alone cannot know.
    function test_rulesOnlyApiMatchesOracleAwayFromAdHocClosure() public view {
        uint256[] memory ts = vm.parseJsonUintArray(fx, ".random.ts");
        uint256[] memory blind = vm.parseJsonUintArray(fx, ".random.blind");
        uint256[] memory id = vm.parseJsonUintArray(fx, ".random.id");
        uint256[] memory ses = vm.parseJsonUintArray(fx, ".random.session");
        uint256 checked;
        for (uint256 i; i < ts.length; ++i) {
            if (ts[i] >= 1_735_689_600 && ts[i] < 1_736_640_000) continue; // 2025-01-01 .. 2025-01-12
            ++checked;
            _checkRulesOnly(ts[i], blind[i], id[i], ses[i]);
        }
        assertGt(checked, 19_000);
    }

    function _checkRulesOnly(uint256 ts, uint256 blind, uint256 id, uint256 ses) internal view {
        assertEq(Cal.isBlind(ts) ? 1 : 0, blind, "rules isBlind");
        (bool inside, uint64 s, uint64 e,) = Cal.blindWindowAt(ts);
        assertEq(inside ? 1 : 0, blind, "rules blindWindowAt");
        assertEq(Cal.windowId(ts), id, "rules windowId");
        assertEq(uint256(Cal.sessionAt(ts)), ses, "rules sessionAt");
        (uint64 ns, uint64 ne,) = Cal.nextBlindWindow(ts);
        assertGt(ns, ts);
        assertLt(ns, ne);
        if (inside) {
            assertEq(Cal.secondsUntilBlind(ts), 0);
            assertEq(Cal.windowId(ts), Cal.windowIdOfStart(s));
            assertLt(ts, e);
        } else {
            assertEq(Cal.secondsUntilBlind(ts), ns - ts);
        }
        if (Cal.isTradingDay(ts)) {
            assertLt(Cal.tradingDayOpen(ts), Cal.tradingDayClose(ts));
        }
    }

    function _compareRows(string memory key, uint256 expectLen) internal view {
        uint256[] memory ts = vm.parseJsonUintArray(fx, string.concat(key, ".ts"));
        uint256[] memory blind = vm.parseJsonUintArray(fx, string.concat(key, ".blind"));
        uint256[] memory id = vm.parseJsonUintArray(fx, string.concat(key, ".id"));
        uint256[] memory cls = vm.parseJsonUintArray(fx, string.concat(key, ".cls"));
        uint256[] memory ses = vm.parseJsonUintArray(fx, string.concat(key, ".session"));
        if (expectLen != 0) assertEq(ts.length, expectLen);
        for (uint256 i; i < ts.length; ++i) {
            _checkRow(ts[i], blind[i], id[i], cls[i], ses[i]);
        }
    }

    function _checkRow(uint256 ts, uint256 blind, uint256 id, uint256 cls, uint256 ses) internal view {
        (bool inside,,, Cal.WindowClass c) = Cal.blindWindowAt(ts, _adHoc);
        assertEq(inside ? 1 : 0, blind, "blind");
        assertEq(Cal.isBlind(ts, _adHoc) ? 1 : 0, blind, "isBlind");
        assertEq(Cal.windowId(ts, _adHoc), id, "windowId");
        if (inside) assertEq(uint256(c), cls, "class");
        assertEq(uint256(Cal.sessionAt(ts, _adHoc)), ses, "session");
        assertEq(Cal.secondsUntilBlind(ts, _adHoc) == 0, inside, "secondsUntilBlind zero iff blind");
    }
}

/// @dev Property / fuzz tests over the full supported domain.
contract UsMarketCalendarPropertyTest is CalendarBase {
    uint256 internal constant LO = 1_577_836_800 + 40 days;
    uint256 internal constant HI = 2_240_611_200 - 40 days;

    function testFuzz_windowEdgesAndConsistency(uint256 ts) public view {
        ts = bound(ts, LO, HI);
        (bool inside, uint64 s, uint64 e, Cal.WindowClass c) = Cal.blindWindowAt(ts, _adHoc);
        assertEq(Cal.isBlind(ts, _adHoc), inside);
        if (inside) {
            assertLe(s, ts);
            assertLt(ts, e);
            assertLt(s, e, "zero-length window never reported");
            assertTrue(Cal.isBlind(s, _adHoc));
            assertFalse(Cal.isBlind(s - 1, _adHoc));
            assertTrue(Cal.isBlind(e - 1, _adHoc));
            assertFalse(Cal.isBlind(e, _adHoc));
            uint256 closedDays = (uint256(e - s) + 12 hours) / 1 days;
            assertEq(uint8(c), closedDays == 1 ? 0 : closedDays == 2 ? 1 : 2, "class from calendar days");
            assertEq(Cal.windowId(ts, _adHoc), Cal.windowIdOfStart(s));
            assertEq(Cal.secondsUntilBlind(ts, _adHoc), 0);
            assertEq(uint8(Cal.sessionAt(ts, _adHoc)), uint8(Cal.Session.Closed));
        } else {
            (uint64 ns, uint64 ne,) = Cal.nextBlindWindow(ts, _adHoc);
            assertGt(ns, ts);
            assertEq(Cal.windowId(ts, _adHoc), Cal.windowIdOfStart(ns));
            assertEq(Cal.secondsUntilBlind(ts, _adHoc), ns - ts);
            assertNotEq(uint8(Cal.sessionAt(ts, _adHoc)), uint8(Cal.Session.Closed));
            assertLt(ns, ne);
        }
    }

    function testFuzz_nextWindowStrictlyAfterAndNonOverlapping(uint256 ts) public view {
        ts = bound(ts, LO, HI);
        (uint64 s, uint64 e,) = Cal.nextBlindWindow(ts, _adHoc);
        assertGt(s, ts, "next starts after ts");
        assertLt(s, e);
        // windows never overlap: the following window starts at least one open trading day (23-25 h) later.
        (uint64 s2,,) = Cal.nextBlindWindow(s, _adHoc);
        assertGe(s2, e + 23 hours, "non-overlapping with a trading day in between");
        assertGt(Cal.windowIdOfStart(s2), Cal.windowIdOfStart(s), "ids strictly increase");
    }

    function testFuzz_windowIdMonotone(uint256 a, uint256 b) public view {
        a = bound(a, LO, HI);
        b = bound(b, LO, HI);
        (a, b) = a <= b ? (a, b) : (b, a);
        assertLe(Cal.windowId(a, _adHoc), Cal.windowId(b, _adHoc));
    }

    function testFuzz_utcOffsetIsFourOrFiveHours(uint256 ts) public pure {
        ts = bound(ts, LO, HI);
        uint256 off = Cal.etOffset(ts);
        assertTrue(off == 4 hours || off == 5 hours);
    }

    function testFuzz_displaySessionMatchesLocalTime(uint256 ts) public view {
        ts = bound(ts, LO, HI);
        Cal.Session s = Cal.sessionAt(ts, _adHoc);
        uint256 tod = (ts - Cal.etOffset(ts)) % 1 days;
        if (s == Cal.Session.Closed) return;
        if (tod >= 20 hours || tod < 4 hours) assertEq(uint8(s), uint8(Cal.Session.Overnight));
        else if (tod < 9.5 hours) assertEq(uint8(s), uint8(Cal.Session.PreMarket));
        else assertTrue(s == Cal.Session.Regular || s == Cal.Session.PostMarket);
    }

    /// @dev The 20:00 ET boundaries never fall in the 01:00-03:00 DST-ambiguous hours: re-derive both edges.
    function testFuzz_windowEdgesAreTwentyHundredEt(uint256 ts) public view {
        ts = bound(ts, LO, HI);
        (uint64 s, uint64 e,) = Cal.nextBlindWindow(ts, _adHoc);
        assertEq((s - Cal.etOffset(s)) % 1 days, 20 hours);
        assertEq((e - Cal.etOffset(e)) % 1 days, 20 hours);
    }

    function test_gasReport() public {
        CalendarHarness h = new CalendarHarness();
        uint256 inWin = 1_788_796_800; // Labor Day 2026 (blind)
        uint256 outWin = 1_788_289_200; // Tue 2026-09-01 (open)
        uint256 g;
        g = gasleft();
        h.isBlind(outWin);
        console.log("gas isBlind (open)        ", g - gasleft());
        g = gasleft();
        h.isBlind(inWin);
        console.log("gas isBlind (blind)       ", g - gasleft());
        g = gasleft();
        h.blindWindowAt(inWin);
        console.log("gas blindWindowAt (blind) ", g - gasleft());
        g = gasleft();
        h.nextBlindWindow(outWin);
        console.log("gas nextBlindWindow       ", g - gasleft());
        g = gasleft();
        h.windowId(outWin);
        console.log("gas windowId              ", g - gasleft());
        g = gasleft();
        h.secondsUntilBlind(outWin);
        console.log("gas secondsUntilBlind     ", g - gasleft());
        g = gasleft();
        h.sessionAt(outWin);
        console.log("gas sessionAt             ", g - gasleft());
        g = gasleft();
        h.isTradingDay(outWin);
        console.log("gas isTradingDay          ", g - gasleft());
        g = gasleft();
        h.tradingDayClose(outWin);
        console.log("gas tradingDayClose       ", g - gasleft());
        g = gasleft();
        h.isEarlyClose(outWin);
        console.log("gas isEarlyClose          ", g - gasleft());
        // worst case: a 12-day closed run (10 ad-hoc days incl. one weekend + the surrounding weekend)
        uint256 d0 = Cal.dayIndex(2030, 3, 4);
        for (uint256 i; i < 10; ++i) {
            h.setAdHoc(d0 + i, true);
        }
        uint256 mid = (d0 + 4) * 1 days + 17 hours;
        g = gasleft();
        h.blindWindowAt(mid);
        console.log("gas blindWindowAt (12d run)", g - gasleft());
        g = gasleft();
        h.windowId(mid);
        console.log("gas windowId (12d run)     ", g - gasleft());
        g = gasleft();
        h.secondsUntilBlind(d0 * 1 days - 3 days);
        console.log("gas secondsUntilBlind (pre)", g - gasleft());
    }
}
