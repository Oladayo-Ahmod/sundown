// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PriceStatus} from "./IEquityOracle.sol";

/// @notice Account-level context the market hands to its guard.
/// @dev For `maxBorrowable` after a borrow or a collateral withdrawal, `collateral` and `debtAssets` are the
/// post-action state. `collateralValue` is rounded down and carries no haircut.
struct AccountCtx {
    address account;
    uint256 collateral;
    uint256 debtAssets;
    uint256 priceWad;
    uint256 haircutWad;
    uint64 updatedAt;
    uint64 windowId;
    PriceStatus status;
    uint256 lltvWad;
    uint256 totalBorrowAssets;
    uint256 totalAssets;
    uint256 collateralValue;
}

/// @title IRiskGuard
/// @notice Policy hook of a Sundown market. The market contains no session logic; all of it lives behind
/// this interface. The guard address is immutable per market, so trust is fixed at creation. The market bounds
/// the guard: borrow capacity is `min(guard, collateralValue * lltv)`, liquidation bonus is capped, the close
/// factor and the non-worsening rule are enforced by the market.
interface IRiskGuard {
    /// @notice Maximum total debt (loan-token units) the account may hold now.
    function maxBorrowable(AccountCtx calldata c) external view returns (uint256);

    /// @notice Whether the account may be liquidated now. The market has already required debt > 0 and a
    /// usable price.
    function liquidationAllowed(AccountCtx calldata c) external view returns (bool);

    /// @notice Liquidation bonus (WAD) for repaying `repayAssets` now; capped by the market.
    function liquidationBonus(AccountCtx calldata c, uint256 repayAssets) external view returns (uint256);

    /// @notice Called by the market after a borrow was accepted. May revert. No-op for stateless guards.
    function onBorrow(AccountCtx calldata c, uint256 borrowed) external;

    /// @notice Called by the market after a liquidation was applied. May revert. No-op for stateless guards.
    function onLiquidate(AccountCtx calldata c, address liquidator, uint256 repaid, uint256 seized) external;
}
