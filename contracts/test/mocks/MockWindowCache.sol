// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IWindowCache, WindowState} from "../../src/interfaces/IWindowCache.sol";

/// @dev TEST FIXTURE: a window cache whose state is set by the test.
contract MockWindowCache is IWindowCache {
    WindowState internal _s;

    function set(bool blind, uint64 windowId, uint64 start, uint64 end, uint64 lastEnd, uint8 cls) external {
        _s = WindowState(blind, windowId, start, end, lastEnd, cls);
    }

    function state() external view returns (WindowState memory) {
        return _s;
    }

    function peek() external view returns (WindowState memory) {
        return _s;
    }
}
