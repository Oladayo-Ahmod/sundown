// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SharesMath
/// @notice Asset/share conversions with virtual shares and assets (as in Morpho Blue), used for borrow shares.
/// @dev All rounding is explicit; callers choose it so that it always favors the protocol.
library SharesMath {
    /// @notice Virtual shares added to the share supply.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @notice Virtual assets added to the asset total.
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Shares for `assets`, rounded down.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Shares for `assets`, rounded up.
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
    }

    /// @notice Assets for `shares`, rounded down.
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Assets for `shares`, rounded up.
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }
}
