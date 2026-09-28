// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccountCtx, IRiskGuard} from "../interfaces/IRiskGuard.sol";

/// @title FlatGuard
/// @notice CONTROL guard: static LTV, static liquidation threshold (the market's LLTV) and a flat bonus. It
/// ignores the price status, the haircut and the window id, exactly like a conventional market that keeps
/// using a frozen oracle price. Stateless, so one instance may serve several markets.
/// @dev The flat bonus must lie in [3 %, 5.5 %]: nothing below 3 % ships without live keeper evidence (D15) and
/// 5.5 % is the Aave maximum (secondary source).
contract FlatGuard is IRiskGuard {
    /// @notice 1e18 fixed point.
    uint256 internal constant WAD = 1e18;
    /// @notice Lowest allowed flat bonus (3 %).
    uint256 public constant MIN_BONUS_WAD = 0.03e18;
    /// @notice Highest allowed flat bonus (5.5 %).
    uint256 public constant MAX_BONUS_WAD = 0.055e18;

    /// @notice Static borrow LTV (WAD).
    uint256 public immutable LTV_WAD;
    /// @notice Flat liquidation bonus (WAD).
    uint256 public immutable BONUS_WAD;

    /// @notice A constructor argument is out of range.
    error InvalidParam(bytes32 field);

    /// @param ltvWad Borrow LTV in (0, 1e18).
    /// @param bonusWad Flat bonus in [3 %, 5.5 %].
    constructor(uint256 ltvWad, uint256 bonusWad) {
        if (ltvWad == 0 || ltvWad >= WAD) revert InvalidParam("ltv");
        if (bonusWad < MIN_BONUS_WAD || bonusWad > MAX_BONUS_WAD) revert InvalidParam("bonus");
        LTV_WAD = ltvWad;
        BONUS_WAD = bonusWad;
    }

    /// @inheritdoc IRiskGuard
    function maxBorrowable(AccountCtx calldata c) external view returns (uint256) {
        return Math.mulDiv(c.collateralValue, LTV_WAD, WAD);
    }

    /// @inheritdoc IRiskGuard
    function liquidationAllowed(AccountCtx calldata c) external pure returns (bool) {
        return c.debtAssets > Math.mulDiv(c.collateralValue, c.lltvWad, WAD);
    }

    /// @inheritdoc IRiskGuard
    function liquidationBonus(AccountCtx calldata, uint256) external view returns (uint256) {
        return BONUS_WAD;
    }

    /// @inheritdoc IRiskGuard
    function onBorrow(AccountCtx calldata, uint256) external pure {}

    /// @inheritdoc IRiskGuard
    function onLiquidate(AccountCtx calldata, address, uint256, uint256) external pure {}
}
