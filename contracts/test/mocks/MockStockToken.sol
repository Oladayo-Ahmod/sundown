// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStockToken
/// @notice TEST FIXTURE. An 18-decimal ERC-20 that models the corporate-action surface of a Robinhood stock token
/// (ERC-8056 multiplier and the oracle pause flag). `legacy = true` makes `oraclePaused()` revert like the older
/// testnet token.
contract MockStockToken is ERC20 {
    bool public oraclePausedFlag;
    bool public legacy;
    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;

    constructor() ERC20("Mock Stock", "MSTK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setOraclePaused(bool on) external {
        oraclePausedFlag = on;
    }

    function setLegacy(bool on) external {
        legacy = on;
    }

    function setPending(uint256 next, uint256 effectiveAt_) external {
        newUIMultiplier = next;
        effectiveAt = effectiveAt_;
    }

    function oraclePaused() external view returns (bool) {
        require(!legacy, "no oraclePaused");
        return oraclePausedFlag;
    }
}
