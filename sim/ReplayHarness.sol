// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {SundownMarket} from "../contracts/src/SundownMarket.sol";
import {SundownMarketFactory} from "../contracts/src/SundownMarketFactory.sol";
import {FlatGuard} from "../contracts/src/guards/FlatGuard.sol";
import {SundownGuard} from "../contracts/src/guards/SundownGuard.sol";
import {ChainlinkEquityOracle} from "../contracts/src/oracle/ChainlinkEquityOracle.sol";
import {MarketParams} from "../contracts/src/interfaces/ISundownMarket.sol";
import {MockERC20} from "../contracts/test/mocks/MockERC20.sol";
import {MockStockToken} from "../contracts/test/mocks/MockStockToken.sol";
import {MockWindowCache} from "../contracts/test/mocks/MockWindowCache.sol";
import {SimEquityFeed} from "./SimEquityFeed.sol";

/// @title ReplayHarness
/// @notice SIMULATION. Replays the worst real AAPL and SPY gaps (`sim/replay_inputs.json`, derived from
/// `sim/replay_events.json`) through three markets built from the same implementation: a control (FlatGuard at
/// the boosted LLTV), a session-aware market (SundownGuard) and a standard-tier control (FlatGuard at the standard
/// LLTV). Prices come from `SimEquityFeed` through the production `ChainlinkEquityOracle`; the blind windows are a
/// window-cache fixture placed at synthetic times with the event's class and length (the on-chain calendar covers
/// 2024 onward, most worst events are older). The keeper is this contract. Nothing here is a live integration.
/// Timeline and population are specified in research/replay_reference.py, which re-implements them in exact
/// integers for comparison (`sim/compare_replay.py`).
abstract contract ReplayHarness is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant H = 6 hours;
    uint256 internal constant C = 3 hours;
    uint256 internal constant S_OFFSET = 12 hours; // window start, relative to the borrow time
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant STANDARD = 0.86e18;
    uint256 internal constant N = 20;
    uint256 internal constant COLLATERAL = 50e18;
    uint256 internal constant LENDER_DEPOSIT = 5_000_000e6;
    uint256 internal constant FEE_BOUND = 0.055e18;
    uint64 internal constant WID = 7;

    struct Ev {
        string asset;
        string date;
        uint8 cls;
        uint256 windowSeconds;
        uint256 ratioWad;
    }

    struct Rig {
        MockERC20 usd;
        MockStockToken stock;
        SimEquityFeed feed;
        MockWindowCache cache;
        ChainlinkEquityOracle oracle;
        SundownMarketFactory factory;
        address[] borrowers;
        address keeper;
        address lender;
    }

    struct Row {
        uint256 loss;
        uint256 ordinaryLiq;
        uint256 deleverageCalls;
        uint256 deleverageDebt;
        uint256 deleverageNotional;
        uint256 borrowed;
    }

    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");

    // ---------------------------------------------------------------- entry point

    function runReplay(string memory inputsPath) public {
        string memory json = vm.readFile(inputsPath);
        string[] memory assets = vm.parseJsonStringArray(json, ".cols.asset");
        string[] memory dates = vm.parseJsonStringArray(json, ".cols.date");
        uint256[] memory cls = vm.parseJsonUintArray(json, ".cols.cls");
        uint256[] memory wsec = vm.parseJsonUintArray(json, ".cols.windowSeconds");
        uint256[] memory ratio = vm.parseJsonUintArray(json, ".cols.ratioWad");
        console2.log("CSVHEADER,asset,tierBps,date,variant,loss,ordLiq,delevCalls,delevDebt,delevNotional,capWeekday,capWindow,borrowed");
        for (uint256 i; i < assets.length; ++i) {
            Ev memory e = Ev(assets[i], dates[i], uint8(cls[i]), wsec[i], ratio[i]);
            uint256[3] memory depth = _depth(json, e.asset);
            uint256[2] memory tiers = [uint256(0.93e18), uint256(0.9e18)];
            for (uint256 t; t < 2; ++t) {
                _runEvent(e, tiers[t], depth);
            }
        }
    }

    function _depth(string memory json, string memory asset) private pure returns (uint256[3] memory d) {
        d[0] = vm.parseJsonUint(json, string.concat(".depthUsd.", asset, ".d1"));
        d[1] = vm.parseJsonUint(json, string.concat(".depthUsd.", asset, ".d3"));
        d[2] = vm.parseJsonUint(json, string.concat(".depthUsd.", asset, ".d5"));
    }

    // ---------------------------------------------------------------- one event, three markets

    struct Mk {
        SundownMarket control;
        SundownMarket standard;
        SundownMarket sundown;
        SundownGuard sg;
        uint256 bControl;
        uint256 bStandard;
        uint256 bSundown;
    }

    struct Out {
        Row control;
        Row standard;
        Row sundown;
    }

    function _runEvent(Ev memory e, uint256 tier, uint256[3] memory depth) private {
        Rig memory r = _rig(e);
        Mk memory k = _build(r, e, tier);
        Out memory o = _timeline(r, e, k);
        _report(e, tier, k, o, depth);
    }

    function _build(Rig memory r, Ev memory e, uint256 tier) private returns (Mk memory k) {
        k.control = _market(r, address(new FlatGuard(tier, 0.04e18)), tier);
        k.standard = _market(r, address(new FlatGuard(STANDARD, 0.04e18)), STANDARD);
        k.sg = _sundownGuard(r, e, tier);
        k.sundown = _market(r, address(k.sg), tier);
        k.sg.bindMarket(address(k.sundown));
        _fund(r, k.control);
        _fund(r, k.standard);
        _fund(r, k.sundown);
        k.bControl = _populate(r, k.control, tier, SundownGuard(address(0)));
        k.bStandard = _populate(r, k.standard, STANDARD, SundownGuard(address(0)));
        k.bSundown = _populate(r, k.sundown, tier, k.sg);
    }

    function _timeline(Rig memory r, Ev memory e, Mk memory k) private returns (Out memory o) {
        uint256 sStart = T0 + S_OFFSET;
        uint256 sEnd = sStart + e.windowSeconds;

        // deleverage zone opens: the keeper deleverages every eligible session-aware account
        vm.warp(sStart - H + C);
        (o.sundown.deleverageCalls, o.sundown.deleverageDebt, o.sundown.deleverageNotional) =
            _deleverage(r, k.sg, k.sundown);

        // the window starts: the feed goes quiet (ScheduledBlind)
        vm.warp(sStart);
        r.cache.set(true, WID, uint64(sStart), uint64(sEnd), 0, e.cls);

        // reopening at the gapped price
        vm.warp(sEnd + 120);
        r.cache.set(false, WID + 1, uint64(sEnd + 3 days), uint64(sEnd + 5 days), uint64(sEnd), e.cls);
        r.feed.publish(int256(100e8 * e.ratioWad / WAD));

        uint256 calls = o.sundown.deleverageCalls;
        uint256 debt = o.sundown.deleverageDebt;
        uint256 notional = o.sundown.deleverageNotional;
        o.control = _settle(r, k.control);
        o.standard = _settle(r, k.standard);
        o.sundown = _settle(r, k.sundown);
        o.sundown.deleverageCalls = calls;
        o.sundown.deleverageDebt = debt;
        o.sundown.deleverageNotional = notional;
        o.control.borrowed = k.bControl;
        o.standard.borrowed = k.bStandard;
        o.sundown.borrowed = k.bSundown;
    }

    function _report(Ev memory e, uint256 tier, Mk memory k, Out memory o, uint256[3] memory depth) private view {
        uint256 cv0 = COLLATERAL * 100e18 / 1e30;
        uint256 sf = k.sg.stressFraction(e.cls);
        uint256 capFrac = tier < sf ? tier : sf;
        string memory tierBps = vm.toString(tier * 1e4 / WAD);
        _emit(e, tierBps, "standard", o.standard, cv0 * STANDARD / WAD * N, cv0 * STANDARD / WAD * N);
        _emit(e, tierBps, "control", o.control, cv0 * tier / WAD * N, cv0 * tier / WAD * N);
        _emit(e, tierBps, "sundown", o.sundown, cv0 * tier / WAD * N, cv0 * capFrac / WAD * N);
        if (o.sundown.deleverageNotional > 0) _keeper(e, tierBps, o.sundown.deleverageNotional, depth);
    }

    function _emit(Ev memory e, string memory tierBps, string memory variant, Row memory x, uint256 capWeekday, uint256 capWindow)
        private
        pure
    {
        console2.log(
            string.concat(
                "ROW,", e.asset, ",", tierBps, ",", e.date, ",", variant, ",", vm.toString(x.loss), ","
            ),
            string.concat(
                vm.toString(x.ordinaryLiq), ",", vm.toString(x.deleverageCalls), ",", vm.toString(x.deleverageDebt), ","
            ),
            string.concat(
                vm.toString(x.deleverageNotional), ",", vm.toString(capWeekday), ",", vm.toString(capWindow), ",",
                vm.toString(x.borrowed)
            )
        );
    }

    // ---------------------------------------------------------------- keeper break-even (D29)

    /// @dev Keeper batch notional (USD, 6 decimals) against the exit-depth table: average slippage by linear
    /// interpolation through (0, 0), (d1, 1 %), (d3, 3 %), (d5, 5 %); break-even fee = slippage + gas share.
    /// Gas is an ASSUMPTION (`GAS_USD_PER_TX`, 6 decimals).
    uint256 internal constant GAS_USD_PER_TX = 0.5e6;

    function _keeper(Ev memory e, string memory tierBps, uint256 notional6, uint256[3] memory depth) private pure {
        uint256 usd = notional6 / 1e6;
        string memory pre = string.concat("KEEPER,", e.asset, ",", tierBps, ",", e.date, ",");
        if (usd > depth[2]) {
            console2.log(string.concat(pre, vm.toString(usd), ",beyond-depth-table,0,0"));
            return;
        }
        uint256 slip = _slippageWad(usd, depth);
        uint256 gasShare = GAS_USD_PER_TX * WAD / notional6;
        uint256 be = slip + gasShare;
        console2.log(
            string.concat(
                pre, vm.toString(usd), ",", be <= FEE_BOUND ? "viable" : "not-viable", ",", vm.toString(slip * 1e4 / WAD),
                ",", vm.toString(be * 1e4 / WAD)
            )
        );
    }

    function _slippageWad(uint256 usd, uint256[3] memory d) private pure returns (uint256) {
        uint256 x0;
        uint256 y0;
        for (uint256 k; k < 3; ++k) {
            uint256 y1 = k == 0 ? 0.01e18 : k == 1 ? 0.03e18 : 0.05e18;
            if (usd <= d[k]) return d[k] == x0 ? y0 : y0 + (y1 - y0) * (usd - x0) / (d[k] - x0);
            x0 = d[k];
            y0 = y1;
        }
        return 0.05e18;
    }

    // ---------------------------------------------------------------- setup helpers

    function _rig(Ev memory e) private returns (Rig memory r) {
        vm.warp(T0);
        r.usd = new MockERC20("USD", "USD", 6);
        r.stock = new MockStockToken();
        r.cache = new MockWindowCache();
        r.cache.set(false, WID, uint64(T0 + S_OFFSET), uint64(T0 + S_OFFSET + e.windowSeconds), 0, e.cls);
        r.feed = new SimEquityFeed(address(this), "SIM / USD (simulation)", 100e8);
        r.oracle = new ChainlinkEquityOracle(
            ChainlinkEquityOracle.Config({
                feed: address(r.feed),
                collateralToken: address(r.stock),
                windowCache: address(r.cache),
                sequencerFeed: address(0),
                sequencerGrace: 0,
                maxAge: 25 hours,
                freeAge: 1 hours,
                corporateActionHorizon: 1 days,
                deviationWad: 0.005e18,
                ageHaircutWadPerHour: 0.002e18,
                maxAgeHaircutWad: 0.05e18,
                minPriceWad: 1e18,
                maxPriceWad: 1_000_000e18
            })
        );
        r.factory = new SundownMarketFactory(address(new SundownMarket()), governance);
        r.keeper = makeAddr("keeper");
        r.lender = makeAddr("lender");
        r.borrowers = new address[](N);
        for (uint256 i; i < N; ++i) {
            r.borrowers[i] = makeAddr(string.concat("b", vm.toString(i)));
        }
    }

    function _market(Rig memory r, address guard_, uint256 lltv) private returns (SundownMarket) {
        vm.prank(governance);
        return SundownMarket(
            r.factory.createMarket(
                MarketParams({
                    collateralToken: address(r.stock),
                    loanToken: address(r.usd),
                    oracle: address(r.oracle),
                    guard: guard_,
                    guardian: guardian,
                    governance: governance,
                    lltvWad: uint64(lltv),
                    closeFactorWad: 0.5e18,
                    criticalHealthWad: 0.95e18,
                    maxBonusWad: 0.055e18,
                    collateralCap: 10_000e18,
                    minDebt: 10e6,
                    baseAprWad: 0,
                    slope1AprWad: 0.04e18,
                    slope2AprWad: 0.75e18,
                    kinkWad: 0.8e18,
                    shareName: "Sundown replay",
                    shareSymbol: "sdSIM"
                })
            )
        );
    }

    function _sundownGuard(Rig memory r, Ev memory e, uint256 tier) private returns (SundownGuard) {
        bool aapl = keccak256(bytes(e.asset)) == keccak256("AAPL");
        // D26: full-sample empirical q99.5 downside gap (research/results/class_stats.csv), bps * 1e14 as WAD
        SundownGuard.Params memory p = SundownGuard.Params({
            standardLltv: uint64(STANDARD),
            boostedLltv: uint64(tier),
            gapShort: aapl ? 28299e12 : 16152e12,
            gapWeekend: aapl ? 91529e12 : 40713e12,
            gapLong: aapl ? 59700e12 : 29799e12,
            oracleBuffer: 0.005e18,
            safetyBuffer: 0.01e18,
            bonus: 0.04e18,
            deleverageFee: 0.02e18,
            deleverageMargin: 0.005e18,
            preWindowHorizon: uint32(H),
            cureWindow: uint32(C)
        });
        return new SundownGuard(p, address(r.oracle), address(r.cache), governance, guardian, address(this), 2 days, 18, 6);
    }

    function _fund(Rig memory r, SundownMarket m) private {
        r.usd.mint(r.lender, LENDER_DEPOSIT);
        r.usd.mint(r.keeper, 1_000_000_000e6);
        vm.startPrank(r.lender);
        r.usd.approve(address(m), type(uint256).max);
        m.deposit(LENDER_DEPOSIT, r.lender);
        vm.stopPrank();
        vm.startPrank(r.keeper);
        r.usd.approve(address(m), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < N; ++i) {
            address b = r.borrowers[i];
            r.stock.mint(b, COLLATERAL);
            vm.startPrank(b);
            r.stock.approve(address(m), type(uint256).max);
            r.usd.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Leverage-seeking population: debt is 80 %..99 % of the tier cap, spread over (i mod 10).
    function _populate(Rig memory r, SundownMarket m, uint256 tier, SundownGuard sg) private returns (uint256 total) {
        uint256 cv0 = COLLATERAL * 100e18 / 1e30;
        for (uint256 i; i < N; ++i) {
            address b = r.borrowers[i];
            uint256 f = 0.8e18 + 0.19e18 * (i % 10) / 9;
            uint256 debt = cv0 * tier / WAD * f / WAD;
            vm.startPrank(b);
            if (address(sg) != address(0)) sg.enterBoosted();
            m.depositCollateral(COLLATERAL, b);
            m.borrow(debt, b);
            vm.stopPrank();
            total += debt;
        }
    }

    // ---------------------------------------------------------------- keeper behaviour

    function _deleverage(Rig memory r, SundownGuard sg, SundownMarket m)
        private
        returns (uint256 calls, uint256 debtSum, uint256 notional)
    {
        for (uint256 round; round < 4; ++round) {
            bool progressed;
            for (uint256 i; i < N; ++i) {
                address b = r.borrowers[i];
                (bool ok,,, uint256 req,) = sg.quoteDeleverage(b);
                if (!ok || req == 0) continue;
                vm.prank(r.keeper);
                try m.liquidate(b, req, r.keeper) returns (uint256 repaid, uint256) {
                    ++calls;
                    debtSum += repaid;
                    notional += repaid * (WAD + 0.02e18) / WAD;
                    progressed = true;
                } catch {}
            }
            if (!progressed) break;
        }
    }

    function _settle(Rig memory r, SundownMarket m) private returns (Row memory x) {
        for (uint256 round; round < 5; ++round) {
            bool progressed;
            for (uint256 i; i < N; ++i) {
                address b = r.borrowers[i];
                uint256 debt = m.debtOf(b);
                if (debt == 0 || m.collateralOf(b) == 0) continue;
                vm.prank(r.keeper);
                try m.liquidate(b, debt, r.keeper) {
                    ++x.ordinaryLiq;
                    progressed = true;
                } catch {}
            }
            if (!progressed) break;
        }
        for (uint256 i; i < N; ++i) {
            address b = r.borrowers[i];
            SundownMarket.Position memory p = m.positionOf(b);
            if (p.collateral == 0 && p.borrowShares > 0) m.realizeBadDebt(b);
        }
        x.loss = m.badDebtRealized();
    }
}
