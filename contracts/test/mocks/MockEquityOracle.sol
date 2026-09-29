// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEquityOracle, PriceData, PriceStatus} from "../../src/interfaces/IEquityOracle.sol";

/// @title MockEquityOracle
/// @notice TEST FIXTURE (not a real integration). Returns whatever the test sets, including every status.
contract MockEquityOracle is IEquityOracle {
    PriceData public data;

    constructor(uint256 priceWad) {
        data = PriceData({
            priceWad: priceWad,
            updatedAt: uint64(block.timestamp),
            windowId: 0,
            haircutWad: 0,
            status: PriceStatus.Fresh
        });
    }

    function setPrice(uint256 priceWad) external {
        data.priceWad = priceWad;
        data.updatedAt = uint64(block.timestamp);
    }

    function setStatus(PriceStatus status) external {
        data.status = status;
    }

    function setHaircut(uint256 haircutWad) external {
        data.haircutWad = haircutWad;
    }

    function setWindowId(uint64 id) external {
        data.windowId = id;
    }

    function price() external view returns (PriceData memory) {
        return data;
    }

    function peek() external view returns (PriceData memory) {
        return data;
    }
}
