// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEquityOracle, PriceData, PriceStatus} from "../interfaces/IEquityOracle.sol";
import {IWindowCache, WindowState} from "../interfaces/IWindowCache.sol";

/// @dev Chainlink AggregatorV3 subset used for the price feed and the optional L2 sequencer-uptime feed.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Robinhood stock-token corporate-action surface (ERC-8056 multiplier + oracle pause flag).
interface ICorporateActionToken {
    function oraclePaused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/// @title ChainlinkEquityOracle
/// @notice Production oracle path for one tokenized-equity collateral token: a Chainlink AggregatorV3 price feed
/// judged with calendar-aware freshness (decision N1). It is NOT claimed "integrated" until a fork test has read
/// the real feeds (see test/OracleFork.t.sol).
/// @dev Policy (docs/MARKET_DESIGN.md sections 4.1 and 9):
///  - the feed price is per token and already includes the corporate-action multiplier: no further scaling;
///  - the 0.5 % feed deviation is an irreducible price-error allowance, returned as part of `haircutWad`;
///  - outside blind windows an age haircut applies; inside scheduled blind windows only the allowance does (the
///    frozen price is the guard's gap-VaR problem);
///  - scheduled blindness comes from the calendar (via {IWindowCache}); unscheduled blindness (`Stale`) is a feed
///    older than `MAX_AGE` while the calendar says the feed is live; `Reopening` is a live calendar with a price
///    older than the last window end (first post-window update not seen yet);
///  - zero/negative/out-of-bounds answers, incomplete rounds and future timestamps are `Invalid`;
///  - `oraclePaused()` or a pending multiplier change is `CorporateAction`; an optional sequencer-uptime feed
///    (none exists on Robinhood Chain; Arbitrum One has one) yields `SequencerDown`.
/// All parameters are immutable and come from deployment config, never hardcoded here.
contract ChainlinkEquityOracle is IEquityOracle {
    /// @notice 1e18 fixed point.
    uint256 internal constant WAD = 1e18;

    /// @notice Deployment configuration.
    struct Config {
        address feed;
        address collateralToken;
        address windowCache;
        address sequencerFeed; // zero = none
        uint32 sequencerGrace;
        uint32 maxAge; // heartbeat + grace
        uint32 freeAge; // age below which no age haircut applies
        uint32 corporateActionHorizon;
        uint64 deviationWad;
        uint64 ageHaircutWadPerHour;
        uint64 maxAgeHaircutWad;
        uint256 minPriceWad;
        uint256 maxPriceWad;
    }

    IAggregatorV3 public immutable FEED;
    address public immutable COLLATERAL_TOKEN;
    IWindowCache public immutable WINDOW_CACHE;
    IAggregatorV3 public immutable SEQUENCER_FEED;
    uint32 public immutable SEQUENCER_GRACE;
    uint32 public immutable MAX_AGE;
    uint32 public immutable FREE_AGE;
    uint32 public immutable CORPORATE_ACTION_HORIZON;
    uint64 public immutable DEVIATION_WAD;
    uint64 public immutable AGE_HAIRCUT_WAD_PER_HOUR;
    uint64 public immutable MAX_AGE_HAIRCUT_WAD;
    uint256 public immutable MIN_PRICE_WAD;
    uint256 public immutable MAX_PRICE_WAD;
    /// @notice `10^(18 - feed decimals)`: normalizes the feed answer to WAD.
    uint256 public immutable DECIMAL_SCALE;

    /// @notice A configuration value is invalid.
    error InvalidConfig(bytes32 field);

    /// @param c Configuration (validated).
    constructor(Config memory c) {
        if (c.feed == address(0)) revert InvalidConfig("feed");
        if (c.collateralToken == address(0)) revert InvalidConfig("collateralToken");
        if (c.windowCache == address(0)) revert InvalidConfig("windowCache");
        if (c.maxAge == 0) revert InvalidConfig("maxAge");
        if (c.minPriceWad == 0 || c.minPriceWad >= c.maxPriceWad) revert InvalidConfig("bounds");
        if (c.deviationWad >= WAD || c.maxAgeHaircutWad >= WAD) revert InvalidConfig("haircut");
        uint8 dec = IAggregatorV3(c.feed).decimals();
        if (dec > 18) revert InvalidConfig("decimals");

        FEED = IAggregatorV3(c.feed);
        COLLATERAL_TOKEN = c.collateralToken;
        WINDOW_CACHE = IWindowCache(c.windowCache);
        SEQUENCER_FEED = IAggregatorV3(c.sequencerFeed);
        SEQUENCER_GRACE = c.sequencerGrace;
        MAX_AGE = c.maxAge;
        FREE_AGE = c.freeAge;
        CORPORATE_ACTION_HORIZON = c.corporateActionHorizon;
        DEVIATION_WAD = c.deviationWad;
        AGE_HAIRCUT_WAD_PER_HOUR = c.ageHaircutWadPerHour;
        MAX_AGE_HAIRCUT_WAD = c.maxAgeHaircutWad;
        MIN_PRICE_WAD = c.minPriceWad;
        MAX_PRICE_WAD = c.maxPriceWad;
        DECIMAL_SCALE = 10 ** (18 - dec);
    }

    /// @inheritdoc IEquityOracle
    function price() external returns (PriceData memory) {
        return _compute(WINDOW_CACHE.state());
    }

    /// @inheritdoc IEquityOracle
    function peek() external view returns (PriceData memory) {
        return _compute(WINDOW_CACHE.peek());
    }

    function _compute(WindowState memory w) private view returns (PriceData memory d) {
        d.windowId = w.windowId;

        (bool ok, uint256 priceWad, uint256 updatedAt) = _readFeed();
        d.priceWad = priceWad;
        d.updatedAt = uint64(updatedAt);
        if (!ok) {
            d.status = PriceStatus.Invalid;
            return d;
        }
        if (_corporateActionPending()) {
            d.status = PriceStatus.CorporateAction;
            return d;
        }
        if (_sequencerDown()) {
            d.status = PriceStatus.SequencerDown;
            return d;
        }

        if (w.blind) {
            d.status = PriceStatus.ScheduledBlind;
            d.haircutWad = DEVIATION_WAD;
            return d;
        }
        uint256 age = block.timestamp - updatedAt;
        d.haircutWad = DEVIATION_WAD + _ageHaircut(age);
        if (updatedAt < w.lastEnd) d.status = PriceStatus.Reopening;
        else d.status = age > MAX_AGE ? PriceStatus.Stale : PriceStatus.Fresh;
    }

    /// @dev Reads and validates the feed. Returns ok = false for any reason the answer cannot be trusted.
    function _readFeed() private view returns (bool ok, uint256 priceWad, uint256 updatedAt) {
        try FEED.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updated, uint80 answeredIn
        ) {
            updatedAt = updated;
            if (answer <= 0 || uint256(answer) > type(uint128).max) return (false, 0, updatedAt);
            priceWad = uint256(answer) * DECIMAL_SCALE;
            if (
                updated == 0 || updated > block.timestamp || updated > type(uint64).max || answeredIn < roundId
                    || priceWad < MIN_PRICE_WAD || priceWad > MAX_PRICE_WAD
            ) return (false, priceWad, updatedAt);
            return (true, priceWad, updatedAt);
        } catch {
            return (false, 0, 0);
        }
    }

    function _ageHaircut(uint256 age) private view returns (uint256) {
        if (age <= FREE_AGE) return 0;
        uint256 h = (uint256(AGE_HAIRCUT_WAD_PER_HOUR) * (age - FREE_AGE)) / 1 hours;
        return h > MAX_AGE_HAIRCUT_WAD ? MAX_AGE_HAIRCUT_WAD : h;
    }

    /// @dev `oraclePaused()` true, or a scheduled multiplier change taking effect within the horizon. Tokens
    /// without these functions (older versions) simply do not flag.
    function _corporateActionPending() private view returns (bool) {
        ICorporateActionToken t = ICorporateActionToken(COLLATERAL_TOKEN);
        try t.oraclePaused() returns (bool paused) {
            if (paused) return true;
        } catch {}
        try t.uiMultiplier() returns (uint256 current) {
            try t.newUIMultiplier() returns (uint256 next) {
                if (next != current) {
                    try t.effectiveAt() returns (uint256 eff) {
                        return eff <= block.timestamp + CORPORATE_ACTION_HORIZON;
                    } catch {
                        return true;
                    }
                }
            } catch {}
        } catch {}
        return false;
    }

    /// @dev Optional L2 sequencer-uptime check (Chainlink convention: answer 0 = up; `startedAt` = last change).
    /// Conservative: any failure to read the feed counts as down.
    function _sequencerDown() private view returns (bool) {
        if (address(SEQUENCER_FEED) == address(0)) return false;
        try SEQUENCER_FEED.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            return answer != 0 || startedAt == 0 || block.timestamp < startedAt + SEQUENCER_GRACE;
        } catch {
            return true;
        }
    }
}
