// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {SundownMarket} from "../../src/SundownMarket.sol";
import {SundownGuard} from "../../src/guards/SundownGuard.sol";
import {MarketState} from "../../src/interfaces/ISundownMarket.sol";
import {PriceStatus} from "../../src/interfaces/IEquityOracle.sol";
import {WindowState} from "../../src/interfaces/IWindowCache.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEquityOracle} from "../mocks/MockEquityOracle.sol";
import {MockWindowCache} from "../mocks/MockWindowCache.sol";

/// @dev Drives a market protected by {SundownGuard}: lenders, standard and boosted borrowers, keepers, a window
/// and price mover, guardian and governance. Every call is wrapped in try/catch; the handler records GHOST
/// VIOLATIONS (must stay 0) from expectations it computes itself from the raw state, window and parameters.
contract GuardHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint64 internal constant WID = 7;

    SundownMarket public immutable market;
    SundownGuard public immutable guard;
    MockEquityOracle public immutable oracle;
    MockWindowCache public immutable cache;
    MockERC20 public immutable stock;
    MockERC20 public immutable usd;
    address public immutable governance;
    address public immutable guardian;

    address[] public borrowers;
    address public keeper;
    address public lender;

    // ghost violations
    uint256 public vCap; // G1: borrow/withdraw left debt above the expected cap
    uint256 public vEntry; // G4: boosted entry outside its gating
    uint256 public vDelev; // G2: deleverage worsened a position / exceeded the required repay
    uint256 public vStandard; // G2: a standard account was deleveraged
    uint256 public vZone; // G6: deleverage while halted / not Fresh / outside the zone
    uint256 public vEvents; // G8: Deleveraged emitted iff the pre-state predicate held
    uint256 public vGuardian; // G3: the guardian loosened something, or a hook was bypassed
    uint256 public vTimelock; // G7: parameters changed before eta or outside executeParams
    uint256 public vRepay; // G5: a full repay reverted
    bytes32 public ghostParamsHash;
    uint64 public ghostEta;
    SundownGuard.Params[] internal variants;
    mapping(bytes32 => uint256) public calls;

    uint256 private constant RARE = 8;

    modifier rare(uint256 seed) {
        if (seed % RARE != 0) return;
        _;
    }

    constructor(
        SundownMarket market_,
        SundownGuard guard_,
        MockEquityOracle oracle_,
        MockWindowCache cache_,
        MockERC20 stock_,
        MockERC20 usd_,
        address governance_,
        address guardian_
    ) {
        market = market_;
        guard = guard_;
        oracle = oracle_;
        cache = cache_;
        stock = stock_;
        usd = usd_;
        governance = governance_;
        guardian = guardian_;
        ghostParamsHash = keccak256(abi.encode(guard_.currentParams()));

        lender = _actor("lender", 100_000_000e6, 0);
        keeper = _actor("keeper", 100_000_000e6, 0);
        for (uint256 i; i < 3; ++i) {
            address b = _actor(string.concat("borrower", vm.toString(i)), 1_000_000e6, 100_000e18);
            borrowers.push(b);
            vm.prank(b);
            market.depositCollateral(100e18, b);
        }
        vm.prank(lender);
        market.deposit(5_000_000e6, lender);
        _farWindow();

        SundownGuard.Params memory p = guard_.currentParams();
        variants.push(p);
        SundownGuard.Params memory v1 = guard_.currentParams();
        v1.gapWeekend = 0.1e18;
        variants.push(v1);
        SundownGuard.Params memory v2 = guard_.currentParams();
        v2.preWindowHorizon = 8 hours;
        v2.cureWindow = 2 hours;
        variants.push(v2);
        SundownGuard.Params memory v3 = guard_.currentParams();
        v3.deleverageFee = 0.03e18;
        v3.deleverageMargin = 0.01e18;
        variants.push(v3);
        SundownGuard.Params memory v4 = guard_.currentParams();
        v4.gapWeekend = 0.13e18; // stress fraction 85.5 % < standard LLTV 86 %
        variants.push(v4);
    }

    function _actor(string memory label, uint256 usdAmt, uint256 stockAmt) private returns (address a) {
        a = makeAddr(label);
        usd.mint(a, usdAmt);
        if (stockAmt != 0) stock.mint(a, stockAmt);
        vm.startPrank(a);
        usd.approve(address(market), type(uint256).max);
        stock.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function borrowersLength() external view returns (uint256) {
        return borrowers.length;
    }

    // ---------------------------------------------------------------- independent expectations

    function _farWindow() private {
        cache.set(false, WID, uint64(block.timestamp + 3 days), uint64(block.timestamp + 3 days + 48 hours), 0, 1);
    }

    function _status() private view returns (PriceStatus s) {
        (,,,, s) = oracle.data();
    }

    function _price() private view returns (uint256 p) {
        (p,,,,) = oracle.data();
    }

    function _stress(WindowState memory w, PriceStatus s, SundownGuard.Params memory p) private view returns (bool) {
        return
            w.blind || s == PriceStatus.Reopening || (w.start != 0 && block.timestamp + p.preWindowHorizon >= w.start);
    }

    function _gap(SundownGuard.Params memory p, uint8 cls) private pure returns (uint256) {
        return cls == 0 ? p.gapShort : cls == 1 ? p.gapWeekend : p.gapLong;
    }

    function _frac(SundownGuard.Params memory p, uint8 cls) private pure returns (uint256) {
        uint256 h = _gap(p, cls) + p.oracleBuffer + p.safetyBuffer;
        return h >= WAD ? 0 : WAD - h;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _cv(address a) private view returns (uint256) {
        return market.collateralOf(a) * _price() / 1e30;
    }

    /// @dev Expected debt ceiling for `a` right now (loan units, rounded down).
    function _expectedCap(address a) private view returns (uint256) {
        if (_status() == PriceStatus.Stale) return 0;
        SundownGuard.Params memory p = guard.currentParams();
        uint256 frac = p.standardLltv;
        if (p.boostedLltv != 0 && guard.boosted(a)) {
            frac = p.boostedLltv;
            WindowState memory w = cache.peek();
            if (_stress(w, _status(), p)) frac = _min(frac, _frac(p, w.cls));
        }
        uint256 cap = _cv(a) * frac / WAD;
        uint256 byMarket = _cv(a) * 0.93e18 / WAD;
        return _min(cap, byMarket);
    }

    function _threshold(address a, SundownGuard.Params memory p) private view returns (uint256) {
        bool b = p.boostedLltv != 0 && guard.boosted(a);
        return _cv(a) * (b ? p.boostedLltv : p.standardLltv) / WAD;
    }

    function _required(uint256 cv, uint256 debt, uint256 capFrac, SundownGuard.Params memory p)
        private
        pure
        returns (uint256)
    {
        uint256 t = capFrac > p.deleverageMargin ? capFrac - p.deleverageMargin : 0;
        uint256 target = cv * t / WAD;
        if (debt <= target) return 0;
        uint256 growth = (t * (WAD + p.deleverageFee) + WAD - 1) / WAD;
        if (growth >= WAD) return debt;
        uint256 r = ((debt - target) * WAD + (WAD - growth) - 1) / (WAD - growth);
        return r > debt ? debt : r;
    }

    // ---------------------------------------------------------------- lender / borrower actions

    function enter(uint256 seed) external {
        address a = borrowers[seed % borrowers.length];
        SundownGuard.Params memory p = guard.currentParams();
        WindowState memory w = cache.peek();
        PriceStatus st = _status();
        bool stress = _stress(w, st, p);
        bool halted = market.state() != MarketState.Active;
        bool disabled = guard.boostedEntryDisabled();
        uint256 debt = market.debtOf(a);
        uint256 fitCap = _cv(a) * _min(p.standardLltv, _frac(p, w.cls)) / WAD;
        vm.prank(a);
        try guard.enterBoosted() {
            ++calls["enter"];
            if (stress || halted || disabled || st != PriceStatus.Fresh || p.boostedLltv == 0) ++vEntry;
            if (debt != 0 && debt > fitCap) ++vEntry;
        } catch {}
    }

    function exitTier(uint256 seed) external {
        address a = borrowers[seed % borrowers.length];
        vm.prank(a);
        try guard.exitBoosted() {
            ++calls["exit"];
            if (market.debtOf(a) > _cv(a) * guard.currentParams().standardLltv / WAD) ++vEntry;
        } catch {}
    }

    function depositCollateral(uint256 seed, uint256 amount) external {
        address a = borrowers[seed % borrowers.length];
        vm.prank(a);
        try market.depositCollateral(bound(amount, 1e17, 40e18), a) {
            ++calls["deposit"];
        } catch {}
    }

    function withdrawCollateral(uint256 seed, uint256 pct) external {
        address a = borrowers[seed % borrowers.length];
        uint256 amount = market.collateralOf(a) * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        vm.prank(a);
        try market.withdrawCollateral(amount, a) {
            ++calls["withdraw"];
            uint256 debt = market.debtOf(a);
            if (debt != 0 && debt > _expectedCap(a)) ++vCap;
        } catch {}
    }

    function borrow(uint256 seed, uint256 amount) external {
        address a = borrowers[seed % borrowers.length];
        uint256 cap = _expectedCap(a);
        uint256 debt = market.debtOf(a);
        amount = cap > debt ? bound(amount, 1e6, cap - debt + 5e6) : bound(amount, 1e6, 3000e6);
        bool blocked = guard.borrowsBlocked();
        vm.prank(a);
        try market.borrow(amount, a) {
            ++calls["borrow"];
            if (blocked) ++vGuardian;
            if (market.debtOf(a) > _expectedCap(a)) ++vCap;
        } catch {}
    }

    function repayAll(uint256 seed) external {
        address a = borrowers[seed % borrowers.length];
        uint256 debt = market.debtOf(a);
        if (debt == 0) return;
        if (usd.balanceOf(a) < debt) usd.mint(a, debt);
        vm.prank(a);
        try market.repay(debt, a) {
            ++calls["repay"];
        } catch {
            ++vRepay;
        }
    }

    // ---------------------------------------------------------------- keeper: ordinary liquidation and deleverage

    struct Pre {
        address target;
        uint256 debt;
        uint256 cv;
        uint256 required;
        uint256 collateral;
        bool healthy;
        bool isBoosted;
        bool expectDelev;
    }

    function _pre(address t) private view returns (Pre memory r) {
        SundownGuard.Params memory p = guard.currentParams();
        r.target = t;
        r.debt = market.debtOf(t);
        r.cv = _cv(t);
        r.collateral = market.collateralOf(t);
        r.healthy = r.debt <= _threshold(t, p);
        r.isBoosted = p.boostedLltv != 0 && guard.boosted(t);
        WindowState memory w = cache.peek();
        bool zone = !w.blind && w.start != 0 && block.timestamp + (p.preWindowHorizon - p.cureWindow) >= w.start;
        uint256 capFrac = _min(p.boostedLltv, _frac(p, w.cls));
        r.required = _required(r.cv, r.debt, capFrac, p);
        r.expectDelev = r.healthy && r.isBoosted && market.state() == MarketState.Active
            && _status() == PriceStatus.Fresh && zone && r.debt > r.cv * capFrac / WAD;
    }

    /// @dev Builds the interesting situation: a boosted account at its full boosted capacity, then the next
    /// window moved into the deleverage zone, so `keep` has something to deleverage.
    function squeeze(uint256 seed, uint256 offset) external {
        address a = borrowers[seed % borrowers.length];
        if (market.state() == MarketState.Halted && seed % 2 == 0) {
            vm.prank(governance);
            try market.resume() {} catch {}
        }
        oracle.setStatus(PriceStatus.Fresh);
        _farWindow();
        vm.prank(a);
        try guard.enterBoosted() {} catch {}
        uint256 cap = _expectedCap(a);
        uint256 debt = market.debtOf(a);
        if (cap > debt + 1e6) {
            vm.prank(a);
            try market.borrow(cap - debt, a) {
                ++calls["squeezeBorrow"];
                if (market.debtOf(a) > _expectedCap(a)) ++vCap;
            } catch {}
        }
        SundownGuard.Params memory p = guard.currentParams();
        uint256 s = bound(offset, 1, p.preWindowHorizon - p.cureWindow);
        cache.set(
            false,
            WID,
            uint64(block.timestamp + s),
            uint64(block.timestamp + s + 48 hours),
            0,
            uint8(bound(seed >> 8, 0, 2))
        );
        if (seed % 5 == 1) {
            vm.prank(guardian);
            try market.guardianHalt() {} catch {}
        }
        if (seed % 2 == 0) _keep(a, seed >> 16);
    }

    function keep(uint256 seed, uint256 amountSeed) external {
        _keep(borrowers[seed % borrowers.length], amountSeed);
    }

    function _keep(address target, uint256 amountSeed) private {
        Pre memory r = _pre(target);
        if (r.debt == 0) return;
        uint256 amount = bound(amountSeed, 1e6, r.debt + 1e6);
        if (r.healthy && amountSeed % 2 == 0) amount = r.required + (amountSeed % 3 == 0 ? 1 : 0);
        if (amount == 0) amount = 1e6;

        vm.recordLogs();
        vm.prank(keeper);
        try market.liquidate(r.target, amount, keeper) returns (uint256 repaid, uint256) {
            ++calls["liquidate"];
            _checkLiquidation(r, repaid, vm.getRecordedLogs());
        } catch {
            vm.getRecordedLogs();
        }
    }

    function _checkLiquidation(Pre memory r, uint256 repaid, Vm.Log[] memory logs) private {
        uint256 delevLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(guard) && logs[i].topics[0] == SundownGuard.Deleveraged.selector) {
                ++delevLogs;
            }
        }
        if (!r.healthy) {
            if (delevLogs != 0) ++vEvents;
            return;
        }
        ++calls["deleverage"];
        if (!r.expectDelev) ++vZone;
        if (!r.isBoosted) ++vStandard;
        if (delevLogs != 1) ++vEvents;
        if (repaid > r.required && repaid != r.debt) ++vDelev;
        uint256 debtAfter = market.debtOf(r.target);
        uint256 cvAfter = market.collateralOf(r.target) * _price() / 1e30;
        // never worsens: debt/cv does not rise (wei-level slack)
        if (r.collateral != 0 && debtAfter * r.cv > r.debt * cvAfter + r.debt + r.cv + 2) ++vDelev;
    }

    // ---------------------------------------------------------------- time, windows, price

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 12 hours);
        if (dt % 7 == 0) dt = 2 days;
        vm.warp(block.timestamp + dt);
        WindowState memory w = cache.peek();
        if (!w.blind && block.timestamp >= w.start) {
            if (block.timestamp < w.end) cache.set(true, w.windowId, w.start, w.end, w.lastEnd, w.cls);
            else _farWindow();
        } else if (w.blind && block.timestamp >= w.end) {
            _farWindow();
            oracle.setStatus(PriceStatus.Reopening);
        }
    }

    function setWindow(uint256 kind, uint256 offset, uint256 cls) external {
        uint8 c = uint8(bound(cls, 0, 2));
        kind = bound(kind, 0, 2);
        if (kind == 0) {
            _farWindow();
        } else if (kind == 1) {
            uint256 s = bound(offset, 1, 8 hours);
            cache.set(false, WID, uint64(block.timestamp + s), uint64(block.timestamp + s + 48 hours), 0, c);
        } else {
            uint256 elapsed = bound(offset, 0, 30 hours);
            cache.set(true, WID, uint64(block.timestamp - elapsed), uint64(block.timestamp - elapsed + 48 hours), 0, c);
        }
    }

    function setPrice(uint256 usdPrice) external {
        oracle.setPrice(bound(usdPrice, 70, 130) * 1e18);
    }

    function setStatus(uint256 seed, uint256 s) external rare(seed) {
        uint256 k = bound(s, 0, 3);
        oracle.setStatus(
            k == 0
                ? PriceStatus.Fresh
                : k == 1 ? PriceStatus.Reopening : k == 2 ? PriceStatus.Stale : PriceStatus.ScheduledBlind
        );
    }

    function freshStatus() external {
        oracle.setStatus(PriceStatus.Fresh);
    }

    // ---------------------------------------------------------------- guardian and governance

    function guardianDisable(uint256 seed) external rare(seed) {
        bool before = guard.boostedEntryDisabled();
        bytes32 h = keccak256(abi.encode(guard.currentParams()));
        vm.prank(guardian);
        guard.disableBoostedEntry();
        _guardianPost(before, guard.boostedEntryDisabled(), h);
    }

    function guardianBlock(uint256 seed) external rare(seed) {
        bool before = guard.borrowsBlocked();
        bytes32 h = keccak256(abi.encode(guard.currentParams()));
        vm.prank(guardian);
        guard.blockBorrows();
        _guardianPost(before, guard.borrowsBlocked(), h);
    }

    function _guardianPost(bool before, bool afterFlag, bytes32 paramsBefore) private {
        if (before && !afterFlag) ++vGuardian; // a guardian call cleared a flag
        if (keccak256(abi.encode(guard.currentParams())) != paramsBefore) ++vGuardian;
        ++calls["guardian"];
    }

    function guardianTriesToLoosen(uint256 seed) external rare(seed) {
        vm.startPrank(guardian);
        try guard.clearGuardianFlags() {
            ++vGuardian;
        } catch {}
        try guard.queueParams(variants[0]) {
            ++vGuardian;
        } catch {}
        try guard.executeParams(variants[0]) {
            ++vGuardian;
        } catch {}
        vm.stopPrank();
    }

    function govClear(uint256 seed) external rare(seed) {
        vm.prank(governance);
        guard.clearGuardianFlags();
        ++calls["govClear"];
    }

    function govQueue(uint256 seed, uint256 idx) external rare(seed) {
        SundownGuard.Params memory p = variants[bound(idx, 0, variants.length - 1)];
        vm.prank(governance);
        guard.queueParams(p);
        ghostEta = uint64(block.timestamp + guard.TIMELOCK_DELAY());
        ++calls["queue"];
    }

    function govExecute(uint256 idx) external {
        SundownGuard.Params memory p = variants[bound(idx, 0, variants.length - 1)];
        bytes32 queued = guard.queuedHash();
        bytes32 before = keccak256(abi.encode(guard.currentParams()));
        vm.prank(governance);
        try guard.executeParams(p) {
            ++calls["execute"];
            if (block.timestamp < ghostEta) ++vTimelock; // executed before eta
            ghostParamsHash = keccak256(abi.encode(p));
            if (queued != keccak256(abi.encode(p))) ++vTimelock;
        } catch {
            if (keccak256(abi.encode(guard.currentParams())) != before) ++vTimelock;
        }
    }

    function haltResume(uint256 seed, bool resumeIt) external rare(seed) {
        if (resumeIt) {
            vm.prank(governance);
            try market.resume() {} catch {}
        } else {
            vm.prank(guardian);
            try market.guardianHalt() {} catch {}
        }
    }
}
