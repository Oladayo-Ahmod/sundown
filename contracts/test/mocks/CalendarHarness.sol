// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsMarketCalendar as Cal} from "../../src/lib/UsMarketCalendar.sol";

/// @title CalendarHarness
/// @notice TEST FIXTURE. Exposes the internal {UsMarketCalendar} library as external calls (for reverts and gas
/// measurement) with a directly settable ad-hoc closure bitmap. Not a production contract.
contract CalendarHarness {
    mapping(uint256 day => bool closed) public adHoc;

    /// @notice Test-only direct closure setter (production path is {MarketCalendar}).
    function setAdHoc(uint256 day, bool closed) external {
        adHoc[day] = closed;
    }

    function _adHoc(uint256 day) private view returns (bool) {
        return adHoc[day];
    }

    function isTradingDay(uint256 ts) external view returns (bool) {
        return Cal.isTradingDay(ts, _adHoc);
    }

    function isBlind(uint256 ts) external view returns (bool) {
        return Cal.isBlind(ts, _adHoc);
    }

    function blindWindowAt(uint256 ts) external view returns (bool, uint64, uint64, Cal.WindowClass) {
        return Cal.blindWindowAt(ts, _adHoc);
    }

    function nextBlindWindow(uint256 ts) external view returns (uint64, uint64, Cal.WindowClass) {
        return Cal.nextBlindWindow(ts, _adHoc);
    }

    function windowId(uint256 ts) external view returns (uint64) {
        return Cal.windowId(ts, _adHoc);
    }

    function secondsUntilBlind(uint256 ts) external view returns (uint256) {
        return Cal.secondsUntilBlind(ts, _adHoc);
    }

    function sessionAt(uint256 ts) external view returns (Cal.Session) {
        return Cal.sessionAt(ts, _adHoc);
    }

    function blindWindowAtWith(uint256 ts, uint256 earlySod)
        external
        view
        returns (bool, uint64, uint64, Cal.WindowClass)
    {
        return Cal.blindWindowAtWith(ts, earlySod, _adHoc);
    }

    function nextBlindWindowWith(uint256 ts, uint256 earlySod) external view returns (uint64, uint64, Cal.WindowClass) {
        return Cal.nextBlindWindowWith(ts, earlySod, _adHoc);
    }

    function windowIdWith(uint256 ts, uint256 earlySod) external view returns (uint64) {
        return Cal.windowIdWith(ts, earlySod, _adHoc);
    }

    function secondsUntilBlindWith(uint256 ts, uint256 earlySod) external view returns (uint256) {
        return Cal.secondsUntilBlindWith(ts, earlySod, _adHoc);
    }

    function sessionAtWith(uint256 ts, uint256 earlySod) external view returns (Cal.Session) {
        return Cal.sessionAtWith(ts, earlySod, _adHoc);
    }

    function tradingDayOpen(uint256 ts) external view returns (uint64) {
        return Cal.tradingDayOpen(ts, _adHoc);
    }

    function tradingDayClose(uint256 ts) external view returns (uint64) {
        return Cal.tradingDayClose(ts, _adHoc);
    }

    function regularOpen(uint256 ts) external view returns (uint64) {
        return Cal.regularOpen(ts);
    }

    function regularClose(uint256 ts) external view returns (uint64) {
        return Cal.regularClose(ts);
    }

    function isEarlyClose(uint256 ts) external view returns (bool) {
        return Cal.isEarlyClose(ts);
    }

    function marketStatusOf(Cal.Session s) external pure returns (uint8) {
        return Cal.marketStatusOf(s);
    }

    function etOffset(uint256 ts) external pure returns (uint256) {
        return Cal.etOffset(ts);
    }

    function windowIdOfStart(uint256 start) external pure returns (uint64) {
        return Cal.windowIdOfStart(start);
    }

    function dayIndex(uint256 y, uint256 m, uint256 d) external pure returns (uint256) {
        return Cal.dayIndex(y, m, d);
    }

    function checkRange(uint256 ts) external pure {
        Cal.checkRange(ts);
    }
}
