// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsMarketCalendar} from "../lib/UsMarketCalendar.sol";
import {IWindowCache, WindowState} from "../interfaces/IWindowCache.sol";

/// @dev The part of {MarketCalendar} the cache needs. Window classes are ABI-encoded as uint8.
interface ICalendar {
    function blindWindowAt(uint256 ts) external view returns (bool inside, uint64 start, uint64 end, uint8 cls);
    function nextBlindWindow(uint256 ts) external view returns (uint64 start, uint64 end, uint8 cls);
}

/// @title WindowCache
/// @notice Caches the current-or-next blind window and the end of the last completed window, keyed by window id
/// (decision D11), so hot paths read two storage slots instead of scanning the calendar.
/// @dev The cached window is the earliest window ending after `refreshedAt`. The cache is valid while
/// `now < refreshedAt + TTL` and `now < window end`; within that span no window can have ended after `refreshedAt`,
/// so `lastEnd` stays correct. TTL (24 h) is below `MarketCalendar.ANNOUNCE_LEAD` (72 h) and its minimum closure
/// delay (24 h): an ad-hoc closure that becomes effective at `t1` only creates or extends windows starting after
/// `t1 + 72 h`, and the cache is refreshed at most 24 h later, before such a window can start. Permissionless and
/// deterministic given the calendar; no owner.
contract WindowCache is IWindowCache {
    /// @notice The calendar this cache reads (a deployed `MarketCalendar`, so ad-hoc closures are honored).
    ICalendar public immutable CALENDAR;
    /// @notice Maximum age of a cache entry.
    uint256 public constant TTL = 24 hours;

    uint256 private constant LOOKBACK = 10 days;
    uint256 private constant MAX_LOOKBACK_WINDOWS = 4;

    /// @dev Packed in one slot: five values of at most 40 bits (timestamps fit until year 36812) and a class byte.
    struct Cached {
        uint40 refreshedAt;
        uint40 start;
        uint40 end;
        uint40 lastEnd;
        uint8 cls;
    }

    Cached private _cached;

    /// @notice The cache was refreshed from the calendar.
    event Refreshed(uint64 indexed windowId, uint64 start, uint64 end, uint64 lastEnd);

    /// @notice A constructor argument is the zero address.
    error ZeroAddress();

    /// @param calendar Deployed `MarketCalendar`.
    constructor(address calendar) {
        if (calendar == address(0)) revert ZeroAddress();
        CALENDAR = ICalendar(calendar);
    }

    /// @inheritdoc IWindowCache
    function state() external returns (WindowState memory) {
        Cached memory c = _cached;
        if (!_valid(c, block.timestamp)) {
            c = _compute(block.timestamp);
            _cached = c;
            emit Refreshed(UsMarketCalendar.windowIdOfStart(c.start), c.start, c.end, c.lastEnd);
        }
        return _derive(c, block.timestamp);
    }

    /// @inheritdoc IWindowCache
    function peek() external view returns (WindowState memory) {
        Cached memory c = _cached;
        if (!_valid(c, block.timestamp)) c = _compute(block.timestamp);
        return _derive(c, block.timestamp);
    }

    function _valid(Cached memory c, uint256 ts) private pure returns (bool) {
        return c.refreshedAt != 0 && ts >= c.refreshedAt && ts < uint256(c.refreshedAt) + TTL && ts < c.end;
    }

    function _derive(Cached memory c, uint256 ts) private pure returns (WindowState memory w) {
        w.blind = ts >= c.start && ts < c.end;
        w.windowId = UsMarketCalendar.windowIdOfStart(c.start);
        w.start = c.start;
        w.end = c.end;
        w.lastEnd = c.lastEnd;
        w.cls = c.cls;
    }

    function _compute(uint256 ts) private view returns (Cached memory c) {
        c.refreshedAt = uint40(ts);
        (bool inside, uint64 s, uint64 e, uint8 cls) = CALENDAR.blindWindowAt(ts);
        if (!inside) (s, e, cls) = CALENDAR.nextBlindWindow(ts);
        c.start = uint40(s);
        c.end = uint40(e);
        c.cls = cls;

        // end of the most recent window that ended at or before ts (bounded walk over the last 10 days)
        uint256 cursor = ts > LOOKBACK + UsMarketCalendar.MIN_TS ? ts - LOOKBACK : UsMarketCalendar.MIN_TS;
        uint64 last = 0;
        // `nextBlindWindow` only returns windows starting AFTER the cursor, so a window that contains or starts at
        // the cursor must be considered separately
        (bool containsCursor,, uint64 cursorEnd,) = CALENDAR.blindWindowAt(cursor);
        if (containsCursor && cursorEnd <= ts) last = cursorEnd;
        for (uint256 i; i < MAX_LOOKBACK_WINDOWS; ++i) {
            (uint64 ws, uint64 we,) = CALENDAR.nextBlindWindow(cursor);
            if (we > ts) break;
            last = we;
            cursor = ws;
        }
        c.lastEnd = uint40(last);
    }
}
