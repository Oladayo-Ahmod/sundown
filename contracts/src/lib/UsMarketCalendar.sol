// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title UsMarketCalendar
/// @notice Pure, DST-aware America/New_York calendar for the Chainlink 24/5 US-equity push feeds.
/// @dev Production library. See docs/CALENDAR_NOTES.md for the full design note.
///
/// Trading-day model (decision D1): trading day D opens 20:00 ET on calendar day D-1 and closes 20:00 ET on D;
/// weekends and NYSE holidays are closed trading days. For consecutive open trading days D1 < D2 the oracle is
/// blind over [20:00 ET on D1, 20:00 ET on D2-1), half-open. Consecutive weekdays give no window.
/// Class is by the number of closed calendar days n = D2 - D1 - 1 (1 Short, 2 Weekend, >=3 Long), never by hours.
///
/// Holiday rules follow the NYSE "Holidays & Trading Hours" calendar (https://www.nyse.com/markets/hours-calendars),
/// cross-checked against exchange_calendars by research/calendar_oracle.py. One-off closures (e.g. 2025-01-09) are not
/// derivable from rules and are supplied by the caller through the `adHoc` function pointer.
///
/// Early closes (13:00 ET) are informational. ASSUMPTION (UNVERIFIED): they do not move window boundaries.
/// Flip it with `EARLY_CLOSE_WINDOW_SOD`.
library UsMarketCalendar {
    /// @notice Blind-window class by closed calendar days (not hours).
    enum WindowClass {
        Short,
        Weekend,
        Long
    }

    /// @notice Display-only session. Risk logic must never use it.
    enum Session {
        Closed,
        PreMarket,
        Regular,
        PostMarket,
        Overnight
    }

    /// @notice Timestamp outside the supported years 2020-2040 (UTC).
    error OutOfRange(uint256 ts);
    /// @notice Day is a weekend, holiday or ad-hoc closure.
    error NotTradingDay(uint256 ts);
    /// @notice A run of consecutive closed days exceeded `MAX_CLOSED_RUN`.
    error ClosedRunTooLong();
    /// @notice No blind window found within `MAX_SCAN` days.
    error ScanExceeded();

    /// @dev 2020-01-01T00:00:00Z.
    uint256 internal constant MIN_TS = 1_577_836_800;
    /// @dev 2041-01-01T00:00:00Z (exclusive).
    uint256 internal constant MAX_TS = 2_240_611_200;
    /// @dev Max consecutive closed days scanned in one direction. Real calendars reach 3; ad-hoc closures may add.
    uint256 internal constant MAX_CLOSED_RUN = 14;
    /// @dev Max days scanned forward by `nextBlindWindow`.
    uint256 internal constant MAX_SCAN = 21;

    uint256 internal constant DAY = 86_400;
    /// @dev Trading day opens at this ET second-of-day on the previous calendar day.
    uint256 internal constant OPEN_SOD = 20 hours;
    /// @dev Trading day closes at this ET second-of-day.
    uint256 internal constant CLOSE_SOD = 20 hours;
    /// @dev UNVERIFIED config: ET second-of-day at which a window starts when D1 is an early-close day.
    /// 20 hours = early closes do not move boundaries. Set to 17 hours to model a 17:00 feed pause.
    uint256 internal constant EARLY_CLOSE_WINDOW_SOD = 20 hours;

    uint256 internal constant PRE_OPEN_SOD = 4 hours;
    uint256 internal constant REGULAR_OPEN_SOD = 9 hours + 30 minutes;
    uint256 internal constant REGULAR_CLOSE_SOD = 16 hours;
    uint256 internal constant EARLY_REGULAR_CLOSE_SOD = 13 hours;

    // ------------------------------------------------------------------ public-facing API (rules only)

    /// @notice Whether the ET calendar date of `ts` is a trading day (rules only; typed view, reads no state).
    function isTradingDay(uint256 ts) internal view returns (bool) {
        return isTradingDay(ts, _noAdHoc);
    }

    /// @notice Whether the ET calendar date of `ts` is a trading day, honouring ad-hoc closures.
    function isTradingDay(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (bool) {
        _checkRange(ts);
        return !_closed(_localDay(ts), adHoc);
    }

    /// @notice Whether the oracle is expected to be blind at `ts` (rules only).
    function isBlind(uint256 ts) internal view returns (bool inside) {
        (inside,,,) = blindWindowAt(ts);
    }

    /// @notice Whether the oracle is expected to be blind at `ts`, honouring ad-hoc closures.
    function isBlind(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (bool inside) {
        (inside,,,) = blindWindowAt(ts, adHoc);
    }

    /// @notice The blind window containing `ts`, if any (rules only).
    /// @return inside True if `ts` is in a window; otherwise the other values are zero.
    /// @return start Window start (UTC seconds, inclusive).
    /// @return end Window end (UTC seconds, exclusive).
    /// @return cls Window class.
    function blindWindowAt(uint256 ts) internal view returns (bool inside, uint64 start, uint64 end, WindowClass cls) {
        return blindWindowAtWith(ts, EARLY_CLOSE_WINDOW_SOD, _noAdHoc);
    }

    /// @notice The blind window containing `ts`, honouring ad-hoc closures.
    function blindWindowAt(uint256 ts, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (bool inside, uint64 start, uint64 end, WindowClass cls)
    {
        return blindWindowAtWith(ts, EARLY_CLOSE_WINDOW_SOD, adHoc);
    }

    /// @notice The first blind window starting strictly after `ts` (rules only).
    function nextBlindWindow(uint256 ts) internal view returns (uint64 start, uint64 end, WindowClass cls) {
        return nextBlindWindowWith(ts, EARLY_CLOSE_WINDOW_SOD, _noAdHoc);
    }

    /// @notice The first blind window starting strictly after `ts`, honouring ad-hoc closures.
    function nextBlindWindow(uint256 ts, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (uint64 start, uint64 end, WindowClass cls)
    {
        return nextBlindWindowWith(ts, EARLY_CLOSE_WINDOW_SOD, adHoc);
    }

    /// @notice Id of the window containing `ts`, or of the next window if `ts` is outside any window (rules only).
    function windowId(uint256 ts) internal view returns (uint64) {
        return windowIdWith(ts, EARLY_CLOSE_WINDOW_SOD, _noAdHoc);
    }

    /// @notice Id of the window containing `ts`, or of the next window, honouring ad-hoc closures.
    function windowId(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (uint64) {
        return windowIdWith(ts, EARLY_CLOSE_WINDOW_SOD, adHoc);
    }

    /// @notice Seconds until the next blind window starts; 0 if blind now (rules only).
    function secondsUntilBlind(uint256 ts) internal view returns (uint256) {
        return secondsUntilBlindWith(ts, EARLY_CLOSE_WINDOW_SOD, _noAdHoc);
    }

    /// @notice Seconds until the next blind window starts; 0 if blind now. Honours ad-hoc closures.
    function secondsUntilBlind(uint256 ts, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (uint256)
    {
        return secondsUntilBlindWith(ts, EARLY_CLOSE_WINDOW_SOD, adHoc);
    }

    /// @notice Display-only session at `ts` (rules only). Never use for risk decisions.
    function sessionAt(uint256 ts) internal view returns (Session) {
        return sessionAtWith(ts, EARLY_CLOSE_WINDOW_SOD, _noAdHoc);
    }

    /// @notice Display-only session at `ts`, honouring ad-hoc closures. Never use for risk decisions.
    function sessionAt(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (Session) {
        return sessionAtWith(ts, EARLY_CLOSE_WINDOW_SOD, adHoc);
    }

    /// @notice Chainlink Data Streams `marketStatus` equivalent of a display session (24/5 v11 mapping).
    /// @dev marketStatus is NOT available in the push AggregatorV3 feeds; this is documentation-grade only.
    /// 0 Unknown is never produced here.
    function marketStatusOf(Session s) internal pure returns (uint8) {
        if (s == Session.PreMarket) return 1;
        if (s == Session.Regular) return 2;
        if (s == Session.PostMarket) return 3;
        if (s == Session.Overnight) return 4;
        return 5;
    }

    /// @notice UTC time the trading day containing the ET date of `ts` opened (20:00 ET the day before).
    function tradingDayOpen(uint256 ts) internal view returns (uint64) {
        return tradingDayOpen(ts, _noAdHoc);
    }

    /// @notice UTC time the trading day containing the ET date of `ts` opened. Reverts if not a trading day.
    function tradingDayOpen(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (uint64) {
        uint256 d = _tradingDayOf(ts, adHoc);
        return SafeCast.toUint64(_utcAt(d - 1, OPEN_SOD));
    }

    /// @notice UTC time the trading day containing the ET date of `ts` closes (20:00 ET).
    function tradingDayClose(uint256 ts) internal view returns (uint64) {
        return tradingDayClose(ts, _noAdHoc);
    }

    /// @notice UTC time the trading day containing the ET date of `ts` closes. Reverts if not a trading day.
    function tradingDayClose(uint256 ts, function(uint256) view returns (bool) adHoc) internal view returns (uint64) {
        uint256 d = _tradingDayOf(ts, adHoc);
        return SafeCast.toUint64(_utcAt(d, CLOSE_SOD));
    }

    /// @notice UTC time of the regular-session open (09:30 ET) on the ET date of `ts`. Display only.
    function regularOpen(uint256 ts) internal view returns (uint64) {
        uint256 d = _tradingDayOf(ts, _noAdHoc);
        return SafeCast.toUint64(_utcAt(d, REGULAR_OPEN_SOD));
    }

    /// @notice UTC time of the regular-session close (16:00, or 13:00 on early closes) on the ET date of `ts`.
    function regularClose(uint256 ts) internal view returns (uint64) {
        uint256 d = _tradingDayOf(ts, _noAdHoc);
        return SafeCast.toUint64(_utcAt(d, _isEarlyClose(d, _noAdHoc) ? EARLY_REGULAR_CLOSE_SOD : REGULAR_CLOSE_SOD));
    }

    /// @notice Whether the ET date of `ts` is a 13:00 early-close day. Informational.
    function isEarlyClose(uint256 ts) internal view returns (bool) {
        _checkRange(ts);
        return _isEarlyClose(_localDay(ts), _noAdHoc);
    }

    // ------------------------------------------------------------------ generic entry points

    /// @notice `blindWindowAt` with an explicit early-close window start (ET second-of-day) and ad-hoc closures.
    function blindWindowAtWith(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (bool inside, uint64 start, uint64 end, WindowClass cls)
    {
        uint256 d1;
        uint256 d2;
        (inside, d1, d2) = _windowAt(ts, earlySod, adHoc);
        if (!inside) return (false, 0, 0, WindowClass.Short);
        start = SafeCast.toUint64(_closeTime(d1, earlySod, adHoc));
        end = SafeCast.toUint64(_utcAt(d2 - 1, OPEN_SOD));
        cls = _classOf(d2 - d1 - 1);
    }

    /// @notice `nextBlindWindow` with an explicit early-close window start and ad-hoc closures.
    function nextBlindWindowWith(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (uint64 start, uint64 end, WindowClass cls)
    {
        (uint256 d1, uint256 d2) = _nextWindow(ts, earlySod, adHoc);
        start = SafeCast.toUint64(_closeTime(d1, earlySod, adHoc));
        end = SafeCast.toUint64(_utcAt(d2 - 1, OPEN_SOD));
        cls = _classOf(d2 - d1 - 1);
    }

    /// @notice `windowId` with an explicit early-close window start and ad-hoc closures.
    function windowIdWith(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (uint64)
    {
        (bool inside, uint256 d1,) = _windowAt(ts, earlySod, adHoc);
        if (inside) return SafeCast.toUint64(d1);
        (d1,) = _nextWindow(ts, earlySod, adHoc);
        return SafeCast.toUint64(d1);
    }

    /// @notice `secondsUntilBlind` with an explicit early-close window start and ad-hoc closures.
    function secondsUntilBlindWith(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (uint256)
    {
        (bool inside,,) = _windowAt(ts, earlySod, adHoc);
        if (inside) return 0;
        (uint256 d1,) = _nextWindow(ts, earlySod, adHoc);
        return _closeTime(d1, earlySod, adHoc) - ts;
    }

    /// @notice `sessionAt` with an explicit early-close window start and ad-hoc closures.
    function sessionAtWith(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        internal
        view
        returns (Session)
    {
        (bool inside,,) = _windowAt(ts, earlySod, adHoc);
        if (inside) return Session.Closed;
        uint256 tod = (ts - _offset(ts)) % DAY;
        if (tod >= CLOSE_SOD || tod < PRE_OPEN_SOD) return Session.Overnight;
        if (tod < REGULAR_OPEN_SOD) return Session.PreMarket;
        uint256 close = _isEarlyClose(_localDay(ts), adHoc) ? EARLY_REGULAR_CLOSE_SOD : REGULAR_CLOSE_SOD;
        return tod < close ? Session.Regular : Session.PostMarket;
    }

    // ------------------------------------------------------------------ day-index helpers (exposed for the wrapper)

    /// @notice Whether the ET calendar day with index `day` (days since 1970-01-01) is closed.
    function isClosedDay(uint256 day, function(uint256) view returns (bool) adHoc) internal view returns (bool) {
        return _closed(day, adHoc);
    }

    /// @notice First UTC instant of the trading-day slot of `day` (20:00 ET on the previous calendar day).
    function slotStart(uint256 day) internal pure returns (uint64) {
        return SafeCast.toUint64(_utcAt(day - 1, OPEN_SOD));
    }

    /// @notice Day index (days since 1970-01-01) of a civil date.
    function dayIndex(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return _daysFromCivil(year, month, day);
    }

    /// @notice Window id for a window that starts at `start` (day index of D1).
    function windowIdOfStart(uint256 start) internal pure returns (uint64) {
        return SafeCast.toUint64(_localDay(start));
    }

    /// @notice Reverts `OutOfRange` unless `ts` is within the supported years.
    function checkRange(uint256 ts) internal pure {
        _checkRange(ts);
    }

    /// @notice ET UTC offset in seconds (4 h during DST, else 5 h; ET is behind UTC).
    function etOffset(uint256 ts) internal pure returns (uint256) {
        return _offset(ts);
    }

    // ------------------------------------------------------------------ windows

    function _windowAt(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        private
        view
        returns (bool inside, uint256 d1, uint256 d2)
    {
        _checkRange(ts);
        uint256 s = (ts - _offset(ts) + 4 hours) / DAY; // trading-day slot of ts
        if (_closed(s, adHoc)) {
            return (true, _lastOpenBefore(s, adHoc), _firstOpenAfter(s, adHoc));
        }
        // Open slot. Only reachable inside a window when an early close is configured to pause before 20:00.
        if (_closed(s + 1, adHoc) && ts >= _closeTime(s, earlySod, adHoc)) {
            return (true, s, _firstOpenAfter(s + 1, adHoc));
        }
        return (false, 0, 0);
    }

    function _nextWindow(uint256 ts, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        private
        view
        returns (uint256 d1, uint256 d2)
    {
        _checkRange(ts);
        uint256 l = _localDay(ts);
        for (uint256 i; i <= MAX_SCAN; ++i) {
            d1 = l + i;
            if (!_closed(d1, adHoc) && _closed(d1 + 1, adHoc) && _closeTime(d1, earlySod, adHoc) > ts) {
                return (d1, _firstOpenAfter(d1 + 1, adHoc));
            }
        }
        revert ScanExceeded();
    }

    function _lastOpenBefore(uint256 day, function(uint256) view returns (bool) adHoc)
        private
        view
        returns (uint256 d)
    {
        d = day - 1;
        uint256 n;
        while (_closed(d, adHoc)) {
            if (++n > MAX_CLOSED_RUN) revert ClosedRunTooLong();
            --d;
        }
    }

    function _firstOpenAfter(uint256 day, function(uint256) view returns (bool) adHoc)
        private
        view
        returns (uint256 d)
    {
        d = day + 1;
        uint256 n;
        while (_closed(d, adHoc)) {
            if (++n > MAX_CLOSED_RUN) revert ClosedRunTooLong();
            ++d;
        }
    }

    function _classOf(uint256 closedDays) private pure returns (WindowClass) {
        return closedDays == 1 ? WindowClass.Short : closedDays == 2 ? WindowClass.Weekend : WindowClass.Long;
    }

    function _closeTime(uint256 day, uint256 earlySod, function(uint256) view returns (bool) adHoc)
        private
        view
        returns (uint256)
    {
        return _utcAt(day, _isEarlyClose(day, adHoc) ? earlySod : CLOSE_SOD);
    }

    function _tradingDayOf(uint256 ts, function(uint256) view returns (bool) adHoc) private view returns (uint256 d) {
        _checkRange(ts);
        d = _localDay(ts);
        if (_closed(d, adHoc)) revert NotTradingDay(ts);
    }

    function _noAdHoc(uint256) private pure returns (bool) {
        return false;
    }

    function _checkRange(uint256 ts) private pure {
        if (ts < MIN_TS || ts >= MAX_TS) revert OutOfRange(ts);
    }

    // ------------------------------------------------------------------ closed days, holidays, early closes

    function _closed(uint256 day, function(uint256) view returns (bool) adHoc) private view returns (bool) {
        uint256 wd = _weekday(day);
        if (wd == 0 || wd == 6) return true;
        return _isRuleHoliday(day) || adHoc(day);
    }

    function _isRuleHoliday(uint256 day) private pure returns (bool) {
        (uint256 y, uint256 m, uint256 d) = _civil(day);
        uint256 wd = _weekday(day);
        bool monFri = wd >= 1 && wd <= 5;
        if (m == 1) {
            // New Year's Day: Sunday -> Monday Jan 2; Saturday NOT observed. MLK: 3rd Monday.
            return (d == 1 && monFri) || (d == 2 && wd == 1) || (wd == 1 && d >= 15 && d <= 21);
        }
        if (m == 2) return wd == 1 && d >= 15 && d <= 21; // Washington's Birthday: 3rd Monday
        if (m == 3 || m == 4) return day + 2 == _easter(y); // Good Friday
        if (m == 5) return wd == 1 && d >= 25; // Memorial Day: last Monday
        if (m == 6) {
            // Juneteenth, first observed by NYSE in 2022
            return y >= 2022 && ((d == 19 && monFri) || (d == 18 && wd == 5) || (d == 20 && wd == 1));
        }
        if (m == 7) return (d == 4 && monFri) || (d == 3 && wd == 5) || (d == 5 && wd == 1); // Independence Day
        if (m == 9) return wd == 1 && d <= 7; // Labor Day
        if (m == 11) return wd == 4 && d >= 22 && d <= 28; // Thanksgiving
        if (m == 12) return (d == 25 && monFri) || (d == 24 && wd == 5) || (d == 26 && wd == 1); // Christmas
        return false;
    }

    function _isEarlyClose(uint256 day, function(uint256) view returns (bool) adHoc) private view returns (bool) {
        if (_closed(day, adHoc)) return false;
        (, uint256 m, uint256 d) = _civil(day);
        uint256 wd = _weekday(day);
        if (m == 11) return wd == 5 && d >= 23 && d <= 29; // day after Thanksgiving
        if (m == 12) return d == 24 && wd >= 1 && wd <= 4; // Christmas Eve
        if (m == 7) return d == 3 && wd >= 1 && wd <= 4; // July 3 before a weekday Independence Day
        return false;
    }

    /// @dev Easter Sunday day index by the Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    function _easter(uint256 y) private pure returns (uint256) {
        uint256 h = _easterH(y);
        uint256 l = _easterL(y, h);
        uint256 m = ((y % 19) + 11 * h + 22 * l) / 451;
        uint256 t = h + l - 7 * m + 114;
        return _daysFromCivil(y, t / 31, (t % 31) + 1);
    }

    /// @dev h = (19a + b - b/4 - (b - (b+8)/25 + 1)/3 + 15) mod 30, with a = y mod 19, b = y / 100.
    function _easterH(uint256 y) private pure returns (uint256) {
        uint256 b = y / 100;
        uint256 f = (b + 8) / 25;
        uint256 g = (b - f + 1) / 3;
        return (19 * (y % 19) + b - b / 4 - g + 15) % 30;
    }

    /// @dev l = (32 + 2e + 2i - h - k) mod 7, with e = b mod 4, i = c / 4, k = c mod 4, c = y mod 100.
    function _easterL(uint256 y, uint256 h) private pure returns (uint256) {
        uint256 c = y % 100;
        return (32 + 2 * ((y / 100) % 4) + 2 * (c / 4) - h - (c % 4)) % 7;
    }

    // ------------------------------------------------------------------ time zone

    /// @dev ET offset behind UTC for a UTC instant: 4 h in [2nd Sun Mar 07:00Z, 1st Sun Nov 06:00Z), else 5 h.
    function _offset(uint256 ts) private pure returns (uint256) {
        (uint256 y,,) = _civil(ts / DAY);
        uint256 start = _nthWeekday(y, 3, 2, 0) * DAY + 7 hours;
        uint256 end = _nthWeekday(y, 11, 1, 0) * DAY + 6 hours;
        return (ts >= start && ts < end) ? 4 hours : 5 hours;
    }

    function _localDay(uint256 ts) private pure returns (uint256) {
        return (ts - _offset(ts)) / DAY;
    }

    /// @dev UTC instant of ET `sod` on ET calendar `day`. Valid for sod outside 01:00-03:00 (never used there).
    function _utcAt(uint256 day, uint256 sod) private pure returns (uint256) {
        (uint256 y,,) = _civil(day);
        bool dst = day >= _nthWeekday(y, 3, 2, 0) && day < _nthWeekday(y, 11, 1, 0);
        return day * DAY + sod + (dst ? 4 hours : 5 hours);
    }

    // ------------------------------------------------------------------ civil calendar

    function _weekday(uint256 day) private pure returns (uint256) {
        return (day + 4) % 7; // 0 = Sunday; day 0 (1970-01-01) was a Thursday
    }

    /// @dev Day index of the n-th (1-based) weekday `wd` (0 = Sunday) of month `m` in year `y`.
    function _nthWeekday(uint256 y, uint256 m, uint256 n, uint256 wd) private pure returns (uint256) {
        uint256 first = _daysFromCivil(y, m, 1);
        return first + ((wd + 7 - _weekday(first)) % 7) + 7 * (n - 1);
    }

    /// @dev Howard Hinnant's days-from-civil, unsigned (dates >= 1970).
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// @dev Howard Hinnant's civil-from-days, unsigned (dates >= 1970).
    function _civil(uint256 day) private pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = day + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
}
