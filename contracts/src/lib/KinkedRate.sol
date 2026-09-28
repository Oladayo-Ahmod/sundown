// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title KinkedRate
/// @notice Kinked borrow-rate curve and per-second compounding.
/// @dev APR is linear in utilization up to the kink (`base + slope1 * u / kink`) and then steeper
/// (`base + slope1 + slope2 * (u - kink) / (1 - kink)`). Interest over `elapsed` seconds uses the 3-term Taylor
/// expansion `x + x^2/2 + x^3/6` of `exp(x) - 1`, with `x = ratePerSecond * elapsed`. The Taylor series
/// UNDERSTATES interest for very large `x` (relative error about `x^4/24 / x`): about 4e-6 at x = 0.1 and
/// 14 % at x = 1. Accrual is lazy, so `x` is large only if nobody touches a market for years.
library KinkedRate {
    /// @notice 1e18 fixed point.
    uint256 internal constant WAD = 1e18;
    /// @notice Seconds per year used to convert APR to a per-second rate.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Curve parameters (APRs and kink in WAD).
    struct Params {
        uint64 baseAprWad;
        uint64 slope1AprWad;
        uint64 slope2AprWad;
        uint64 kinkWad;
    }

    /// @notice APR (WAD) at utilization `utilWad` (0..1e18), rounded down.
    function aprWad(Params memory p, uint256 utilWad) internal pure returns (uint256) {
        if (utilWad <= p.kinkWad) {
            return p.baseAprWad + (uint256(p.slope1AprWad) * utilWad) / p.kinkWad;
        }
        return p.baseAprWad + p.slope1AprWad + (uint256(p.slope2AprWad) * (utilWad - p.kinkWad)) / (WAD - p.kinkWad);
    }

    /// @notice Per-second rate (WAD) at utilization `utilWad`, rounded down.
    function ratePerSecond(Params memory p, uint256 utilWad) internal pure returns (uint256) {
        return aprWad(p, utilWad) / SECONDS_PER_YEAR;
    }

    /// @notice `exp(rate * elapsed) - 1` (WAD) by the 3-term Taylor expansion, rounded down.
    function compoundFactor(uint256 ratePerSecondWad, uint256 elapsed) internal pure returns (uint256) {
        uint256 x = ratePerSecondWad * elapsed;
        uint256 x2 = (x * x) / WAD;
        uint256 x3 = (x2 * x) / WAD;
        return x + x2 / 2 + x3 / 6;
    }
}
