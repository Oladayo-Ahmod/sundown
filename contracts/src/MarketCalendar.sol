// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UsMarketCalendar as Cal} from "./lib/UsMarketCalendar.sol";

/// @title MarketCalendar
/// @notice Deployable wrapper around {UsMarketCalendar} adding owner-controlled, time-delayed ad-hoc closures
/// (e.g. a national day of mourning).
/// @dev Closures can only be ADDED. Governance can never shorten or move an announced window: a closure is accepted
/// only if the resulting window that contains the closed day starts more than `ANNOUNCE_LEAD` in the future. The
/// owner is intended to be a timelock/multisig; the contract adds its own `CLOSURE_DELAY` between proposal and
/// execution so users see the change coming. Days are indices of ET calendar dates (days since 1970-01-01).
contract MarketCalendar is Ownable {
    /// @notice A resulting window must start later than `now + ANNOUNCE_LEAD` for a closure to be accepted.
    uint256 public constant ANNOUNCE_LEAD = 72 hours;
    /// @notice Minimum configurable `CLOSURE_DELAY`.
    uint256 public constant MIN_DELAY = 1 days;

    /// @notice Delay between `proposeClosure` and `executeClosure`.
    uint256 public immutable CLOSURE_DELAY;

    /// @notice Execution time of a pending closure proposal (0 if none).
    mapping(uint256 day => uint256 eta) public closureEta;

    mapping(uint256 word => uint256 bits) private _closedBitmap;

    /// @notice A closure was proposed and can be executed at `eta`.
    event ClosureProposed(uint256 indexed day, uint256 eta);
    /// @notice A pending closure proposal was cancelled.
    event ClosureCancelled(uint256 indexed day);
    /// @notice A closure became effective. The resulting window containing the day is included.
    event ClosureAdded(uint256 indexed day, uint64 windowStart, uint64 windowEnd, Cal.WindowClass cls);

    /// @notice Constructor delay is below `MIN_DELAY`.
    error DelayTooShort();
    /// @notice A proposal for this day is already pending.
    error AlreadyProposed(uint256 day);
    /// @notice The day is already closed (weekend, holiday or earlier closure).
    error AlreadyClosed(uint256 day);
    /// @notice No pending proposal for this day.
    error NotProposed(uint256 day);
    /// @notice The proposal cannot be executed before `eta`.
    error TooEarly(uint256 eta);
    /// @notice The resulting window starts too soon: it would change a window that is already announced.
    error WindowAnnounced(uint64 windowStart, uint256 minStart);

    /// @param owner_ Timelock/multisig allowed to manage closures.
    /// @param delay_ Seconds between proposal and execution, at least `MIN_DELAY`.
    constructor(address owner_, uint256 delay_) Ownable(owner_) {
        if (delay_ < MIN_DELAY) revert DelayTooShort();
        CLOSURE_DELAY = delay_;
    }

    // ------------------------------------------------------------------ closure management

    /// @notice Propose closing ET calendar day `day`. Validated now and again at execution.
    /// @param day Day index (days since 1970-01-01) of the ET calendar date to close.
    function proposeClosure(uint256 day) external onlyOwner {
        if (closureEta[day] != 0) revert AlreadyProposed(day);
        if (Cal.isClosedDay(day, _isAdHoc)) revert AlreadyClosed(day);
        _setBit(day, true);
        _checkClosure(day);
        _setBit(day, false);
        uint256 eta = block.timestamp + CLOSURE_DELAY;
        closureEta[day] = eta;
        emit ClosureProposed(day, eta);
    }

    /// @notice Cancel a pending closure proposal.
    /// @param day Day index of the pending proposal.
    function cancelClosure(uint256 day) external onlyOwner {
        if (closureEta[day] == 0) revert NotProposed(day);
        delete closureEta[day];
        emit ClosureCancelled(day);
    }

    /// @notice Make a proposed closure effective once its delay has elapsed.
    /// @param day Day index of the pending proposal.
    function executeClosure(uint256 day) external onlyOwner {
        uint256 eta = closureEta[day];
        if (eta == 0) revert NotProposed(day);
        if (block.timestamp < eta) revert TooEarly(eta);
        // No already-closed check here: a pending day cannot become closed by any other path (rules are constant and
        // only this day's own execution sets its bit), and `proposeClosure` rejected closed days.
        delete closureEta[day];
        _setBit(day, true);
        _checkClosure(day);
        (, uint64 start, uint64 end, Cal.WindowClass cls) = Cal.blindWindowAt(Cal.slotStart(day), _isAdHoc);
        emit ClosureAdded(day, start, end, cls);
    }

    // ------------------------------------------------------------------ views

    /// @notice Whether `day` was closed through the ad-hoc mechanism.
    /// @param day Day index of an ET calendar date.
    function isAdHocClosure(uint256 day) external view returns (bool) {
        return _isAdHoc(day);
    }

    /// @notice Whether ET calendar day `day` is closed (weekend, rule holiday or ad-hoc closure).
    /// @param day Day index of an ET calendar date.
    function isClosedDay(uint256 day) external view returns (bool) {
        return Cal.isClosedDay(day, _isAdHoc);
    }

    /// @notice Whether the ET calendar date of `ts` is a trading day.
    /// @param ts UTC seconds within 2020-2040.
    function isTradingDay(uint256 ts) external view returns (bool) {
        return Cal.isTradingDay(ts, _isAdHoc);
    }

    /// @notice Whether the 24/5 push feed is expected to be blind at `ts`.
    /// @param ts UTC seconds within 2020-2040.
    function isBlind(uint256 ts) external view returns (bool) {
        return Cal.isBlind(ts, _isAdHoc);
    }

    /// @notice The blind window containing `ts`, if any.
    /// @param ts UTC seconds within 2020-2040.
    /// @return inside True if `ts` is in a window.
    /// @return start Window start, inclusive.
    /// @return end Window end, exclusive.
    /// @return cls Window class by closed calendar days.
    function blindWindowAt(uint256 ts)
        external
        view
        returns (bool inside, uint64 start, uint64 end, Cal.WindowClass cls)
    {
        return Cal.blindWindowAt(ts, _isAdHoc);
    }

    /// @notice The next blind window starting strictly after `ts`.
    /// @param ts UTC seconds within 2020-2040.
    /// @return start Window start, inclusive.
    /// @return end Window end, exclusive.
    /// @return cls Window class by closed calendar days.
    function nextBlindWindow(uint256 ts) external view returns (uint64 start, uint64 end, Cal.WindowClass cls) {
        return Cal.nextBlindWindow(ts, _isAdHoc);
    }

    /// @notice Id of the window containing `ts`, or of the next window when `ts` is outside any window.
    /// @param ts UTC seconds within 2020-2040.
    function windowId(uint256 ts) external view returns (uint64) {
        return Cal.windowId(ts, _isAdHoc);
    }

    /// @notice Seconds until the next blind window starts; 0 when blind now.
    /// @param ts UTC seconds within 2020-2040.
    function secondsUntilBlind(uint256 ts) external view returns (uint256) {
        return Cal.secondsUntilBlind(ts, _isAdHoc);
    }

    /// @notice Display-only session at `ts`. Never use for risk decisions.
    /// @param ts UTC seconds within 2020-2040.
    function sessionAt(uint256 ts) external view returns (Cal.Session) {
        return Cal.sessionAt(ts, _isAdHoc);
    }

    /// @notice Chainlink Data Streams `marketStatus` equivalent of a display session (documentation only).
    /// @param s Display session.
    function marketStatusOf(Cal.Session s) external pure returns (uint8) {
        return Cal.marketStatusOf(s);
    }

    /// @notice UTC time the trading day containing the ET date of `ts` opened. Reverts on closed days.
    /// @param ts UTC seconds within 2020-2040.
    function tradingDayOpen(uint256 ts) external view returns (uint64) {
        return Cal.tradingDayOpen(ts, _isAdHoc);
    }

    /// @notice UTC time the trading day containing the ET date of `ts` closes. Reverts on closed days.
    /// @param ts UTC seconds within 2020-2040.
    function tradingDayClose(uint256 ts) external view returns (uint64) {
        return Cal.tradingDayClose(ts, _isAdHoc);
    }

    // ------------------------------------------------------------------ internals

    function _checkClosure(uint256 day) private view {
        (, uint64 start,,) = Cal.blindWindowAt(Cal.slotStart(day), _isAdHoc);
        uint256 minStart = block.timestamp + ANNOUNCE_LEAD;
        if (start <= minStart) revert WindowAnnounced(start, minStart);
    }

    function _isAdHoc(uint256 day) private view returns (bool) {
        return (_closedBitmap[day / 256] >> (day % 256)) & 1 == 1;
    }

    function _setBit(uint256 day, bool on) private {
        if (on) _closedBitmap[day / 256] |= (uint256(1) << (day % 256));
        else _closedBitmap[day / 256] &= ~(uint256(1) << (day % 256));
    }
}
