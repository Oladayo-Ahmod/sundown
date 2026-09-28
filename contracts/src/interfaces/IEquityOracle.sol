// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice State of a collateral price as judged by the oracle adapter.
/// @dev `Invalid`, `CorporateAction` and `SequencerDown` make the market itself refuse to act on the price;
/// every other status is forwarded to the guard unchanged (see docs/MARKET_DESIGN.md section 4.1).
enum PriceStatus {
    Fresh,
    ScheduledBlind,
    Reopening,
    Stale,
    Invalid,
    CorporateAction,
    SequencerDown
}

/// @notice A price observation.
/// @param priceWad USD per one whole collateral token, 1e18 scale; the feed price already includes the
/// token's corporate-action multiplier.
/// @param updatedAt Feed `updatedAt`.
/// @param windowId Id of the current or next blind window (0 if unknown).
/// @param haircutWad Fraction (1e18 = 100 %) a guard may subtract: deviation allowance plus age haircut.
/// @param status See {PriceStatus}.
struct PriceData {
    uint256 priceWad;
    uint64 updatedAt;
    uint64 windowId;
    uint256 haircutWad;
    PriceStatus status;
}

/// @title IEquityOracle
/// @notice Price source for one tokenized-equity collateral token, quoted in USD.
interface IEquityOracle {
    /// @notice Current price; may refresh internal caches. Used by the market.
    function price() external returns (PriceData memory);

    /// @notice Current price without writing state. Used by UIs and tests.
    function peek() external view returns (PriceData memory);
}
