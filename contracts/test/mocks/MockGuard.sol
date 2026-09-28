// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccountCtx, IRiskGuard} from "../../src/interfaces/IRiskGuard.sol";

/// @title MockGuard
/// @notice TEST FIXTURE. A guard whose answers the test sets, and which records the last context it was given by
/// the market (to prove the market forwards status, haircut and window id unchanged).
contract MockGuard is IRiskGuard {
    uint256 public capacity = type(uint256).max;
    bool public allowLiquidation = true;
    uint256 public bonusWad = 0.04e18;
    bool public revertOnHooks;

    AccountCtx private _lastBorrowCtx;
    AccountCtx private _lastLiquidateCtx;
    uint256 public borrowHooks;
    uint256 public liquidateHooks;

    function set(uint256 capacity_, bool allow_, uint256 bonus_) external {
        capacity = capacity_;
        allowLiquidation = allow_;
        bonusWad = bonus_;
    }

    function setRevertOnHooks(bool on) external {
        revertOnHooks = on;
    }

    function lastBorrowCtx() external view returns (AccountCtx memory) {
        return _lastBorrowCtx;
    }

    function lastLiquidateCtx() external view returns (AccountCtx memory) {
        return _lastLiquidateCtx;
    }

    function maxBorrowable(AccountCtx calldata) external view returns (uint256) {
        return capacity;
    }

    function liquidationAllowed(AccountCtx calldata) external view returns (bool) {
        return allowLiquidation;
    }

    function liquidationBonus(AccountCtx calldata, uint256) external view returns (uint256) {
        return bonusWad;
    }

    function onBorrow(AccountCtx calldata c, uint256) external {
        require(!revertOnHooks, "hook reverted");
        _lastBorrowCtx = c;
        ++borrowHooks;
    }

    function onLiquidate(AccountCtx calldata c, address, uint256, uint256) external {
        require(!revertOnHooks, "hook reverted");
        _lastLiquidateCtx = c;
        ++liquidateHooks;
    }
}
