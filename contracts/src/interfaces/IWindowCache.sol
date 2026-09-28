// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Cached blind-window state at the current time.
/// @param blind True if the 24/5 push feed is expected to be blind now.
/// @param windowId Id of the current or next blind window (day index of the last open trading day before it).
/// @param start Start of the current or next window (UTC, inclusive).
/// @param end End of the current or next window (UTC, exclusive).
/// @param lastEnd End of the most recent window that ended at or before now (0 if none found).
/// @param cls Window class: 0 Short, 1 Weekend, 2 Long.
struct WindowState {
    bool blind;
    uint64 windowId;
    uint64 start;
    uint64 end;
    uint64 lastEnd;
    uint8 cls;
}

/// @title IWindowCache
/// @notice Cheap, cached view of the blind-window calendar for oracles and guards (decision D11): they read this
/// instead of calling `nextBlindWindow`/`secondsUntilBlind` on every user action.
interface IWindowCache {
    /// @notice Current window state; refreshes the cache when it is stale. State-changing.
    function state() external returns (WindowState memory);

    /// @notice Current window state without writing; recomputes from the calendar when the cache is stale.
    function peek() external view returns (WindowState memory);
}
