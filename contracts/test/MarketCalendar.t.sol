// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketCalendar} from "../src/MarketCalendar.sol";
import {UsMarketCalendar as Cal} from "../src/lib/UsMarketCalendar.sol";
import {CalendarHarness} from "./mocks/CalendarHarness.sol";

contract MarketCalendarTest is Test {
    MarketCalendar internal cal;
    address internal owner = makeAddr("owner");
    uint256 internal constant DELAY = 2 days;

    // 2026-12-01 12:00 UTC, a Tuesday. Dec 16 is a Wednesday, Dec 18 a Friday, Dec 21 a Monday.
    uint256 internal now0;

    function setUp() public {
        cal = new MarketCalendar(owner, DELAY);
        now0 = Cal.dayIndex(2026, 12, 1) * 1 days + 12 hours;
        vm.warp(now0);
    }

    function _day(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        return Cal.dayIndex(y, m, d);
    }

    function _closeNow(uint256 day) internal {
        vm.startPrank(owner);
        cal.proposeClosure(day);
        vm.warp(block.timestamp + DELAY);
        cal.executeClosure(day);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- construction and access

    function test_constructor() public view {
        assertEq(cal.owner(), owner);
        assertEq(cal.CLOSURE_DELAY(), DELAY);
        assertEq(cal.ANNOUNCE_LEAD(), 72 hours);
    }

    function test_constructorRejectsShortDelay() public {
        vm.expectRevert(MarketCalendar.DelayTooShort.selector);
        new MarketCalendar(owner, 1 days - 1);
    }

    function test_onlyOwnerManagesClosures() public {
        address eve = makeAddr("eve");
        uint256 d = _day(2026, 12, 16);
        vm.startPrank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        cal.proposeClosure(d);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        cal.executeClosure(d);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        cal.cancelClosure(d);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- happy path

    function test_proposeExecuteFlowAndEvents() public {
        uint256 d = _day(2026, 12, 16); // Wednesday
        uint256 noon = d * 1 days + 17 hours;
        assertTrue(cal.isTradingDay(noon));
        assertFalse(cal.isBlind(noon));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(cal));
        emit MarketCalendar.ClosureProposed(d, now0 + DELAY);
        cal.proposeClosure(d);
        assertEq(cal.closureEta(d), now0 + DELAY);
        assertFalse(cal.isBlind(noon), "not effective until executed");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.TooEarly.selector, now0 + DELAY));
        cal.executeClosure(d);

        vm.warp(now0 + DELAY);
        uint64 start = Cal.slotStart(d);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(cal));
        emit MarketCalendar.ClosureAdded(d, start, start + 1 days, Cal.WindowClass.Short);
        cal.executeClosure(d);

        assertEq(cal.closureEta(d), 0);
        assertTrue(cal.isAdHocClosure(d));
        assertTrue(cal.isClosedDay(d));
        assertFalse(cal.isTradingDay(noon));
        assertTrue(cal.isBlind(noon));
        (bool inside, uint64 s, uint64 e, Cal.WindowClass c) = cal.blindWindowAt(noon);
        assertTrue(inside);
        assertEq(s, start);
        assertEq(e, start + 1 days);
        assertEq(uint8(c), uint8(Cal.WindowClass.Short));
        assertEq(cal.windowId(noon), Cal.windowIdOfStart(start));
        assertEq(uint8(cal.sessionAt(noon)), uint8(Cal.Session.Closed));
        assertEq(cal.secondsUntilBlind(noon), 0);
        (uint64 ns, uint64 ne,) = cal.nextBlindWindow(start - 1);
        assertEq(ns, start);
        assertEq(ne, e);
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, noon));
        cal.tradingDayOpen(noon);
        vm.expectRevert(abi.encodeWithSelector(Cal.NotTradingDay.selector, noon));
        cal.tradingDayClose(noon);
        // a neighbouring day is untouched
        uint256 thu = (d + 1) * 1 days + 17 hours;
        assertTrue(cal.isTradingDay(thu));
        assertEq(cal.tradingDayClose(thu), Cal.slotStart(d + 2));
        assertEq(cal.marketStatusOf(Cal.Session.Regular), 2);
    }

    function test_cancel() public {
        uint256 d = _day(2026, 12, 16);
        vm.startPrank(owner);
        cal.proposeClosure(d);
        vm.expectEmit(true, false, false, false, address(cal));
        emit MarketCalendar.ClosureCancelled(d);
        cal.cancelClosure(d);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.NotProposed.selector, d));
        cal.cancelClosure(d);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.NotProposed.selector, d));
        cal.executeClosure(d);
        vm.stopPrank();
    }

    function test_rejectsDuplicatesAndClosedDays() public {
        uint256 d = _day(2026, 12, 16);
        vm.startPrank(owner);
        cal.proposeClosure(d);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.AlreadyProposed.selector, d));
        cal.proposeClosure(d);
        // weekend and rule holiday are already closed
        uint256 sat = _day(2026, 12, 19);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.AlreadyClosed.selector, sat));
        cal.proposeClosure(sat);
        uint256 xmas = _day(2026, 12, 25);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.AlreadyClosed.selector, xmas));
        cal.proposeClosure(xmas);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- announced windows are never shortened or moved

    function test_rejectsClosureThatTouchesAnAnnouncedWindow() public {
        // Tue 2026-12-15 12:00 ET: proposing Wed Dec 16 would start a new window at Tue 20:00 ET (< 72 h away).
        vm.warp(_day(2026, 12, 15) * 1 days + 17 hours);
        uint256 d = _day(2026, 12, 16);
        uint64 start = Cal.slotStart(d);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketCalendar.WindowAnnounced.selector, start, block.timestamp + 72 hours)
        );
        cal.proposeClosure(d);
    }

    function test_rejectsExtendingOrMovingAnnouncedWeekend() public {
        // Wed 2026-12-16 12:00 ET. The weekend window (Fri Dec 18 20:00 -> Sun Dec 20 20:00) starts within 72 h.
        vm.warp(_day(2026, 12, 16) * 1 days + 17 hours);
        uint256 weekendStart = Cal.slotStart(_day(2026, 12, 19)); // Fri 20:00 ET
        (bool inside, uint64 s, uint64 e,) = cal.blindWindowAt(weekendStart);
        assertTrue(inside);
        // extend the END: close Monday Dec 21 (window would become Fri -> Mon 20:00)
        uint256 mon = _day(2026, 12, 21);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.WindowAnnounced.selector, s, block.timestamp + 72 hours));
        cal.proposeClosure(mon);
        // move the START earlier: close Friday Dec 18 (window would start Thu 20:00)
        uint256 fri = _day(2026, 12, 18);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketCalendar.WindowAnnounced.selector, s - 1 days, block.timestamp + 72 hours)
        );
        cal.proposeClosure(fri);
        // the announced window is unchanged
        (bool inside2, uint64 s2, uint64 e2,) = cal.blindWindowAt(weekendStart);
        assertTrue(inside2);
        assertEq(s2, s);
        assertEq(e2, e);
        assertEq(inside, inside2);
    }

    function test_extendsAnUnannouncedWindowAndNeverShortensIt() public {
        uint256 fridayEnd = Cal.slotStart(_day(2026, 12, 19)); // Fri Dec 18 20:00 ET
        (, uint64 s0, uint64 e0, Cal.WindowClass c0) = cal.blindWindowAt(fridayEnd);
        assertEq(uint8(c0), uint8(Cal.WindowClass.Weekend));
        // Today is Dec 1: the weekend of Dec 18 is >72 h away, so closing Monday Dec 21 is accepted.
        _closeNow(_day(2026, 12, 21));
        (bool inside, uint64 s1, uint64 e1, Cal.WindowClass c1) = cal.blindWindowAt(fridayEnd);
        assertTrue(inside);
        assertLe(s1, s0, "start never later");
        assertGe(e1, e0, "end never earlier");
        assertEq(uint8(c1), uint8(Cal.WindowClass.Long));
        assertEq(e1, Cal.slotStart(_day(2026, 12, 22)));
    }

    function test_rejectsPastAndOutOfRangeDays() public {
        uint256 past = _day(2026, 11, 18);
        uint64 start = Cal.slotStart(past);
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketCalendar.WindowAnnounced.selector, start, block.timestamp + 72 hours)
        );
        cal.proposeClosure(past);
        vm.expectRevert(abi.encodeWithSelector(Cal.OutOfRange.selector, Cal.slotStart(_day(2041, 1, 2))));
        cal.proposeClosure(_day(2041, 1, 2));
        vm.stopPrank();
    }

    function test_executionRechecksTheAnnouncementRule() public {
        // With a long delay, a proposal that was valid when made can become invalid by execution time.
        MarketCalendar slow = new MarketCalendar(owner, 7 days);
        uint256 d = _day(2026, 12, 10); // Thursday, 9 days away: valid now (start > now + 72 h)
        vm.prank(owner);
        slow.proposeClosure(d);
        vm.warp(now0 + 7 days); // Dec 8: start (Dec 10 01:00Z) is now < 72 h away
        uint64 start = Cal.slotStart(d);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketCalendar.WindowAnnounced.selector, start, block.timestamp + 72 hours)
        );
        slow.executeClosure(d);
        assertEq(slow.closureEta(d), now0 + 7 days, "proposal stays pending; nothing was applied");
        assertFalse(slow.isAdHocClosure(d));
    }

    function test_closedRunBoundIsEnforcedOnClosures() public {
        // Close consecutive weekdays in March 2030 until the run exceeds the library bound.
        uint256 d = _day(2030, 3, 4); // Monday
        bool rejected;
        for (uint256 k; k < 25; ++k) {
            uint256 day = d + k;
            if (cal.isClosedDay(day)) continue;
            vm.prank(owner);
            (bool ok, bytes memory ret) = address(cal).call(abi.encodeCall(cal.proposeClosure, (day)));
            if (!ok) {
                assertEq(bytes4(ret), Cal.ClosedRunTooLong.selector);
                rejected = true;
                break;
            }
            vm.warp(block.timestamp + DELAY);
            vm.prank(owner);
            cal.executeClosure(day);
        }
        assertTrue(rejected, "a closed run longer than MAX_CLOSED_RUN must be rejected");
    }

    // ---------------------------------------------------------------- fuzz: closures only ever add blindness

    function testFuzz_addingClosuresNeverShortensBlindness(uint256 ts, uint256 closeOffsetDays) public {
        CalendarHarness h = new CalendarHarness();
        ts = bound(ts, 1_600_000_000, 2_200_000_000);
        bool before_ = h.isBlind(ts);
        (, uint64 s0, uint64 e0,) = h.blindWindowAt(ts);
        uint256 day = ts / 1 days + bound(closeOffsetDays, 0, 20);
        // only closures that do not create an over-long run, as the wrapper enforces
        try h.blindWindowAt(day * 1 days + 17 hours) returns (bool, uint64, uint64, Cal.WindowClass) {
            h.setAdHoc(day, true);
            try h.blindWindowAt(ts) returns (bool inside, uint64 s1, uint64 e1, Cal.WindowClass) {
                if (before_) {
                    assertTrue(inside, "was blind, still blind");
                    assertLe(s1, s0);
                    assertGe(e1, e0);
                }
            } catch {}
        } catch {}
    }
}
