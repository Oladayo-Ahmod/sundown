// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {SundownGuard} from "../src/guards/SundownGuard.sol";
import {ISundownMarket, MarketParams} from "../src/interfaces/ISundownMarket.sol";
import {PriceStatus} from "../src/interfaces/IEquityOracle.sol";
import {AccountCtx} from "../src/interfaces/IRiskGuard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";
import {MockWindowCache} from "./mocks/MockWindowCache.sol";

/// @dev AAPL-like fixture: standard 86 %, boosted 93 %, gapVaR from docs/GUARD_DESIGN.md section 11 (Short 283,
/// Weekend 915, Long 597 bps), buffers 50 + 100 bps, bonus 4 %, deleverage fee 2 %, margin 50 bps, horizon 6 h,
/// cure 3 h. Price $100, 18-decimal collateral, 6-decimal loan token.
contract SundownGuardTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant H = 6 hours;
    uint256 internal constant C = 3 hours;
    uint8 internal constant SHORT = 0;
    uint8 internal constant WEEKEND = 1;
    uint8 internal constant LONG = 2;
    uint64 internal constant WID = 7;

    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");
    address internal deployer = makeAddr("deployer");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    MockERC20 internal stock;
    MockERC20 internal usd;
    MockEquityOracle internal oracle;
    MockWindowCache internal cache;
    SundownGuard internal guard;
    SundownMarket internal market;

    event Deleveraged(
        address indexed account,
        address indexed liquidator,
        uint64 indexed windowId,
        uint256 repaid,
        uint256 seized,
        uint256 debtBefore,
        uint256 stressCap,
        uint256 requiredRepay
    );
    event Flagged(address indexed account, uint64 indexed windowId, uint256 debt, uint256 stressCap);

    function _p() internal pure returns (SundownGuard.Params memory p) {
        p = SundownGuard.Params({
            standardLltv: 0.86e18,
            boostedLltv: 0.93e18,
            gapShort: 0.0283e18,
            gapWeekend: 0.0915e18,
            gapLong: 0.0597e18,
            oracleBuffer: 0.005e18,
            safetyBuffer: 0.01e18,
            bonus: 0.04e18,
            deleverageFee: 0.02e18,
            deleverageMargin: 0.005e18,
            preWindowHorizon: uint32(H),
            cureWindow: uint32(C)
        });
    }

    function setUp() public virtual {
        vm.warp(T0);
        stock = new MockERC20("Stock", "STK", 18);
        usd = new MockERC20("USD", "USD", 6);
        oracle = new MockEquityOracle(100e18);
        oracle.setWindowId(WID); // the market passes the oracle's window id in the context
        cache = new MockWindowCache();
        _farWindow();
        guard = new SundownGuard(_p(), address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);
        SundownMarketFactory factory = new SundownMarketFactory(address(new SundownMarket()), governance);
        vm.prank(governance);
        market = SundownMarket(
            factory.createMarket(
                MarketParams({
                    collateralToken: address(stock),
                    loanToken: address(usd),
                    oracle: address(oracle),
                    guard: address(guard),
                    guardian: guardian,
                    governance: governance,
                    lltvWad: 0.93e18,
                    closeFactorWad: 0.5e18,
                    criticalHealthWad: 0.95e18,
                    maxBonusWad: 0.055e18,
                    collateralCap: 1000e18,
                    minDebt: 10e6,
                    baseAprWad: 0,
                    slope1AprWad: 0.04e18,
                    slope2AprWad: 0.75e18,
                    kinkWad: 0.8e18,
                    shareName: "Sundown AAPL/USD",
                    shareSymbol: "sdAAPL"
                })
            )
        );
        vm.prank(deployer);
        guard.bindMarket(address(market));

        usd.mint(lender, 10_000_000e6);
        usd.mint(keeper, 10_000_000e6);
        usd.mint(alice, 1_000_000e6);
        usd.mint(bob, 1_000_000e6);
        stock.mint(alice, 10_000e18);
        stock.mint(bob, 10_000e18);
        address[4] memory who = [lender, keeper, alice, bob];
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(who[i]);
            usd.approve(address(market), type(uint256).max);
            stock.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        market.deposit(5_000_000e6, lender);
    }

    // ---------------------------------------------------------------- window helpers

    /// @dev Next window starts in 3 days: outside every stress period.
    function _farWindow() internal {
        cache.set(false, WID, uint64(block.timestamp + 3 days), uint64(block.timestamp + 3 days + 48 hours), 0, WEEKEND);
    }

    /// @dev Next window starts in `secs`.
    function _startsIn(uint256 secs, uint8 cls) internal {
        cache.set(false, WID, uint64(block.timestamp + secs), uint64(block.timestamp + secs + 48 hours), 0, cls);
    }

    function _blind(uint8 cls) internal {
        cache.set(true, WID, uint64(block.timestamp - 1 hours), uint64(block.timestamp + 40 hours), 0, cls);
    }

    function _boostedPosition(address who, uint256 collateral, uint256 debt) internal {
        vm.startPrank(who);
        guard.enterBoosted();
        market.depositCollateral(collateral, who);
        market.borrow(debt, who);
        vm.stopPrank();
    }

    /// @dev Weekend stress fraction: 1 - 9.15 % - 0.5 % - 1 % = 89.35 %.
    uint256 internal constant WEEKEND_FRAC = 0.8935e18;

    // ---------------------------------------------------------------- binding and construction

    function test_bindChecksTheMarketAndRenouncesAdmin() public {
        assertEq(address(guard.market()), address(market));
        assertEq(guard.admin(), address(0));
        vm.prank(deployer);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.bindMarket(address(market));
    }

    function test_bindRejectsAMarketThatNamesAnotherGuard() public {
        SundownGuard other =
            new SundownGuard(_p(), address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.BindingMismatch.selector, bytes32("guard")));
        other.bindMarket(address(market));
    }

    function test_bindRejectsWrongOracleDecimalsAndLltv() public {
        MockEquityOracle o2 = new MockEquityOracle(100e18);
        SundownGuard g =
            new SundownGuard(_p(), address(o2), address(cache), governance, guardian, deployer, 2 days, 18, 6);
        MarketParams memory mp = _marketParams(address(g), 0.93e18, address(oracle));
        SundownMarketFactory f = new SundownMarketFactory(address(new SundownMarket()), governance);
        vm.prank(governance);
        address m = f.createMarket(mp);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.BindingMismatch.selector, bytes32("oracle")));
        g.bindMarket(m);

        SundownGuard g2 =
            new SundownGuard(_p(), address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);
        vm.prank(governance);
        address m2 = f.createMarket(_marketParams(address(g2), 0.9e18, address(oracle)));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.BindingMismatch.selector, bytes32("lltv")));
        g2.bindMarket(m2);

        SundownGuard g3 =
            new SundownGuard(_p(), address(oracle), address(cache), governance, guardian, deployer, 2 days, 8, 6);
        vm.prank(governance);
        address m3 = f.createMarket(_marketParams(address(g3), 0.93e18, address(oracle)));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.BindingMismatch.selector, bytes32("decimals")));
        g3.bindMarket(m3);
    }

    function _marketParams(address g, uint64 lltv, address orc) internal view returns (MarketParams memory) {
        return MarketParams({
            collateralToken: address(stock),
            loanToken: address(usd),
            oracle: orc,
            guard: g,
            guardian: guardian,
            governance: governance,
            lltvWad: lltv,
            closeFactorWad: 0.5e18,
            criticalHealthWad: 0.95e18,
            maxBonusWad: 0.055e18,
            collateralCap: 1000e18,
            minDebt: 10e6,
            baseAprWad: 0,
            slope1AprWad: 0.04e18,
            slope2AprWad: 0.75e18,
            kinkWad: 0.8e18,
            shareName: "x",
            shareSymbol: "x"
        });
    }

    function test_constructorValidatesBounds() public {
        SundownGuard.Params memory p = _p();
        p.boostedLltv = 0.95e18; // above MAX_BOOSTED_LLTV
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("boostedLltv")));
        new SundownGuard(p, address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);

        p = _p();
        p.deleverageFee = 0.05e18; // above bonus
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("deleverageFee")));
        new SundownGuard(p, address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);

        p = _p();
        p.cureWindow = uint32(H); // leaves no deleverage interval
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("cureWindow")));
        new SundownGuard(p, address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);

        p = _p();
        p.bonus = 0.02e18;
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("bonus")));
        new SundownGuard(p, address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);

        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("timelock")));
        new SundownGuard(_p(), address(oracle), address(cache), governance, guardian, deployer, 10 minutes, 18, 6);
    }

    function test_stressFractionPerClass() public view {
        assertEq(guard.stressFraction(SHORT), 1e18 - 0.0283e18 - 0.015e18);
        assertEq(guard.stressFraction(WEEKEND), WEEKEND_FRAC);
        assertEq(guard.stressFraction(LONG), 1e18 - 0.0597e18 - 0.015e18);
    }

    // ---------------------------------------------------------------- capacity

    function test_standardAndBoostedCapacityOutsideStress() public {
        // standard: 86 % of $10,000
        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, 8700e6, 8600e6));
        market.borrow(8700e6, alice);
        market.borrow(8600e6, alice);
        vm.stopPrank();
        // boosted: 93 %
        _boostedPosition(bob, 100e18, 9300e6);
        assertEq(market.debtOf(bob), 9300e6);
    }

    function test_boostedCapIsTheStressCapInsideTheHorizon() public {
        vm.prank(bob);
        guard.enterBoosted();
        vm.prank(bob);
        market.depositCollateral(100e18, bob);
        _startsIn(H, WEEKEND); // exactly at the horizon: stress applies
        uint256 cap = 10_000e6 * WEEKEND_FRAC / WAD; // 8,935e6
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, cap + 1, cap));
        market.borrow(cap + 1, bob);
        market.borrow(cap, bob);
        vm.stopPrank();
    }

    function test_capacityBoundaryOneSecondBeforeTheHorizon() public {
        vm.startPrank(bob);
        guard.enterBoosted();
        market.depositCollateral(100e18, bob);
        vm.stopPrank();
        _startsIn(H + 1, WEEKEND);
        vm.prank(bob);
        market.borrow(9300e6, bob); // full boosted capacity one second before the horizon
        assertEq(market.debtOf(bob), 9300e6);
    }

    function test_withdrawalChecksTheStressCap() public {
        _boostedPosition(bob, 100e18, 8000e6);
        _startsIn(2 hours, WEEKEND);
        // 8,000 <= 89.35 % of the remaining value needs value >= 8,953.7: withdraw 10 tokens -> $9,000 value OK
        vm.prank(bob);
        market.withdrawCollateral(10e18, bob);
        // withdrawing 5 more leaves $8,500: cap 7,594e6 < 8,000e6 -> revert
        vm.prank(bob);
        vm.expectRevert();
        market.withdrawCollateral(5e18, bob);
    }

    function test_longAndShortUseTheirOwnClass() public {
        vm.startPrank(bob);
        guard.enterBoosted();
        market.depositCollateral(100e18, bob);
        vm.stopPrank();
        _startsIn(1 hours, SHORT); // short: 1 - 2.83 % - 1.5 % = 95.67 % > 93 %: the tier cap binds, not the stress cap
        vm.prank(bob);
        market.borrow(9300e6, bob);
        _startsIn(1 hours, LONG); // long: 92.53 %
        vm.prank(bob);
        vm.expectRevert();
        market.borrow(100e6, bob);
    }

    function test_blindWindowAndReopeningKeepTheStressCap() public {
        vm.startPrank(bob);
        guard.enterBoosted();
        market.depositCollateral(100e18, bob);
        vm.stopPrank();
        _blind(WEEKEND);
        oracle.setStatus(PriceStatus.ScheduledBlind);
        vm.prank(bob);
        vm.expectRevert();
        market.borrow(9000e6, bob); // above 8,935
        vm.prank(bob);
        market.borrow(8900e6, bob);
        // reopening: window over, status Reopening still applies the stress cap
        _farWindow();
        oracle.setStatus(PriceStatus.Reopening);
        vm.prank(bob);
        vm.expectRevert();
        market.borrow(100e6, bob);
        // fresh again: boosted capacity returns
        oracle.setStatus(PriceStatus.Fresh);
        vm.prank(bob);
        market.borrow(100e6, bob);
    }

    function test_unscheduledBlindnessBlocksBorrowsAndWithdrawalsButNotRepay() public {
        _boostedPosition(bob, 100e18, 5000e6);
        vm.prank(alice);
        market.depositCollateral(100e18, alice);
        vm.prank(alice);
        market.borrow(1000e6, alice);
        oracle.setStatus(PriceStatus.Stale);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, 5100e6, 0));
        market.borrow(100e6, bob);
        vm.expectRevert();
        market.withdrawCollateral(1e18, bob);
        market.repay(1000e6, bob); // repay stays open
        vm.stopPrank();
        vm.startPrank(alice); // standard accounts are blocked too (D23)
        vm.expectRevert();
        market.borrow(100e6, alice);
        market.repay(500e6, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- tier entry and exit

    function test_enterBoostedGating() public {
        // in the horizon
        _startsIn(H, WEEKEND);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.EntryNotAllowed.selector, bytes32("stress")));
        guard.enterBoosted();
        // during a blind window
        _blind(WEEKEND);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.EntryNotAllowed.selector, bytes32("stress")));
        guard.enterBoosted();
        // reopening
        _farWindow();
        oracle.setStatus(PriceStatus.Reopening);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.EntryNotAllowed.selector, bytes32("price")));
        guard.enterBoosted();
        oracle.setStatus(PriceStatus.Fresh);
        // one second before the horizon is allowed
        _startsIn(H + 1, WEEKEND);
        vm.prank(bob);
        guard.enterBoosted();
        assertTrue(guard.boosted(bob));
        vm.prank(bob);
        vm.expectRevert(SundownGuard.AlreadyBoosted.selector);
        guard.enterBoosted();
    }

    function test_enterBoostedRefusedWhenHalted() public {
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.EntryNotAllowed.selector, bytes32("halted")));
        guard.enterBoosted();
    }

    function test_enterBoostedCannotEscapeALiquidation() public {
        // standard account at 85.9 %, then the price drops so it is above the 86 % threshold
        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        market.borrow(8590e6, alice);
        vm.stopPrank();
        oracle.setPrice(98e18); // value 9,800 -> threshold 8,428e6 < debt
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.DoesNotFitStandard.selector, 8590e6, 8428e6));
        guard.enterBoosted();
        // and it is liquidatable under the standard threshold
        vm.prank(keeper);
        (uint256 repaid,) = market.liquidate(alice, 1000e6, keeper);
        assertEq(repaid, 1000e6);
    }

    function test_enterBoostedWithExistingDebtThatFits() public {
        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        market.borrow(7000e6, alice);
        guard.enterBoosted();
        market.borrow(1900e6, alice); // boosted capacity now available
        vm.stopPrank();
        assertEq(market.debtOf(alice), 8900e6);
    }

    function test_boostedUnavailableWhenTierIsOff() public {
        SundownGuard.Params memory p = _p();
        p.boostedLltv = 0;
        SundownGuard g =
            new SundownGuard(p, address(oracle), address(cache), governance, guardian, deployer, 2 days, 18, 6);
        vm.prank(alice);
        vm.expectRevert(SundownGuard.NotBound.selector);
        g.enterBoosted();
        SundownMarketFactory f = new SundownMarketFactory(address(new SundownMarket()), governance);
        vm.prank(governance);
        address m = f.createMarket(_marketParams(address(g), 0.86e18, address(oracle)));
        vm.prank(deployer);
        g.bindMarket(m);
        vm.prank(alice);
        vm.expectRevert(SundownGuard.BoostedUnavailable.selector);
        g.enterBoosted();
    }

    function test_exitBoostedOnlyIfItFitsStandard() public {
        _boostedPosition(bob, 100e18, 9000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.DoesNotFitStandard.selector, 9000e6, 8600e6));
        guard.exitBoosted();
        vm.startPrank(bob);
        market.repay(500e6, bob);
        guard.exitBoosted();
        vm.stopPrank();
        assertFalse(guard.boosted(bob));
        vm.prank(bob);
        vm.expectRevert(SundownGuard.NotBoosted.selector);
        guard.exitBoosted();
    }

    function test_exitBoostedDuringStressIsAllowedWhenItFits() public {
        _boostedPosition(bob, 100e18, 8000e6);
        _blind(WEEKEND);
        oracle.setStatus(PriceStatus.ScheduledBlind);
        vm.prank(bob);
        guard.exitBoosted();
        assertFalse(guard.boosted(bob));
    }

    // ---------------------------------------------------------------- flag

    function test_flagIsInformationalAndOncePerWindow() public {
        _boostedPosition(bob, 100e18, 9300e6);
        vm.expectRevert(SundownGuard.NotAboveStressCap.selector);
        guard.flag(bob); // not in a stress period
        _startsIn(H, WEEKEND);
        vm.expectEmit(true, true, false, true);
        emit Flagged(bob, WID, 9300e6, 8935e6);
        guard.flag(bob);
        vm.expectRevert(SundownGuard.AlreadyFlagged.selector);
        guard.flag(bob);
        vm.expectRevert(SundownGuard.NotBoosted.selector);
        guard.flag(alice);
    }

    // ---------------------------------------------------------------- deleveraging

    function _setupFlagged() internal {
        _boostedPosition(bob, 100e18, 9300e6);
    }

    function test_deleverageTimelineBoundaries() public {
        _setupFlagged();
        // cure period: [S-H, S-H+C): not eligible
        _startsIn(H, WEEKEND);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
        _startsIn(H - C + 1, WEEKEND); // one second before the cure ends
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
        // exactly when the cure ends
        _startsIn(H - C, WEEKEND);
        (bool ok,,,,) = guard.quoteDeleverage(bob);
        assertTrue(ok);
        // last second before the window
        _startsIn(1, WEEKEND);
        (ok,,,,) = guard.quoteDeleverage(bob);
        assertTrue(ok);
        // the window is blind: no deleveraging
        _blind(WEEKEND);
        (ok,,,,) = guard.quoteDeleverage(bob);
        assertFalse(ok);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
    }

    function test_deleverageSellsOnlyWhatIsRequiredAtTheReducedFee() public {
        _setupFlagged();
        _startsIn(1 hours, WEEKEND);
        (bool ok, uint256 debt, uint256 stressCap, uint256 required, uint256 expectedSeized) =
            guard.quoteDeleverage(bob);
        assertTrue(ok);
        assertEq(debt, 9300e6);
        assertEq(stressCap, 8935e6);
        // t = 89.35 % - 0.5 % = 88.85 %; R = ceil((9300 - 8885) / (1 - 0.8885 * 1.02)) million units
        uint256 target = 10_000e6 * 0.8885e18 / WAD;
        uint256 growth = (0.8885e18 * 1.02e18 + WAD - 1) / WAD;
        uint256 expectR = ((debt - target) * WAD + (WAD - growth) - 1) / (WAD - growth);
        assertEq(required, expectR);
        assertEq(expectedSeized, expectR * 1.02e18 / WAD * 1e30 / 100e18);

        // asking for more than required reverts at the guard's hook
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.RepayExceedsRequired.selector, required + 1, required));
        market.liquidate(bob, required + 1, keeper);

        uint256 keeperStockBefore = stock.balanceOf(keeper);
        vm.expectEmit(true, true, true, false);
        emit Deleveraged(bob, keeper, WID, required, expectedSeized, debt, stressCap, required);
        vm.prank(keeper);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, required, keeper);
        assertEq(repaid, required);
        assertEq(seized, expectedSeized);
        assertEq(stock.balanceOf(keeper) - keeperStockBefore, seized);
        // position lands at or below the target and below the trigger
        uint256 newDebt = market.debtOf(bob);
        uint256 newValue = market.collateralOf(bob) * 100e18 / 1e30;
        assertLe(newDebt, newValue * 0.8885e18 / WAD + 2, "reaches the target");
        assertLt(newDebt * WAD / newValue, 0.8935e18, "below the stress cap");
        // and it is no longer eligible
        (ok,,,,) = guard.quoteDeleverage(bob);
        assertFalse(ok);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
    }

    function test_deleverageNeverTouchesStandardAccounts() public {
        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        market.borrow(8600e6, alice);
        vm.stopPrank();
        _startsIn(1 hours, WEEKEND);
        (bool ok,,,,) = guard.quoteDeleverage(alice);
        assertFalse(ok);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(alice, 100e6, keeper);
    }

    function test_deleverageDisabledWhenHaltedOrPriceNotFresh() public {
        _setupFlagged();
        _startsIn(1 hours, WEEKEND);
        oracle.setStatus(PriceStatus.Stale);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
        oracle.setStatus(PriceStatus.Reopening);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
        oracle.setStatus(PriceStatus.Fresh);
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
        (bool ok,,,,) = guard.quoteDeleverage(bob);
        assertFalse(ok);
    }

    function test_curedAccountsAreNotDeleveraged() public {
        _setupFlagged();
        _startsIn(H, WEEKEND);
        guard.flag(bob);
        vm.prank(bob);
        market.repay(500e6, bob); // 8,800 <= 8,935
        _startsIn(1 hours, WEEKEND);
        (bool ok,,,,) = guard.quoteDeleverage(bob);
        assertFalse(ok);
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(bob, 100e6, keeper);
    }

    function test_unhealthyAccountGetsTheOrdinaryBonusEvenInTheZone() public {
        _setupFlagged();
        _startsIn(1 hours, WEEKEND);
        oracle.setPrice(99e18); // value 9,900; threshold 9,207e6 < 9,300e6 debt: unhealthy
        vm.prank(keeper);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, 1000e6, keeper);
        assertEq(repaid, 1000e6);
        // ordinary 4 % bonus: 1,000e6 * 1.04 / $99 per token
        assertEq(seized, uint256(1000e6) * 1.04e18 / WAD * 1e30 / 99e18);
        // a deleverage (healthy pre-state) at the same time would have paid 2 %: not the case here
        (bool ok,,,,) = guard.quoteDeleverage(bob);
        assertFalse(ok, "ordinary territory, quote is not a deleverage");
    }

    function test_ordinaryLiquidationOutsideTheZoneUsesTheFlatBonus() public {
        _setupFlagged();
        oracle.setPrice(97e18); // value 9,700 -> threshold 9,021e6 < 9,300e6
        vm.prank(keeper);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, 2000e6, keeper);
        assertEq(repaid, 2000e6);
        assertEq(seized, uint256(2000e6) * 1.04e18 / WAD * 1e30 / 97e18);
    }

    function test_dustRuleMayCloseASmallPositionInOneCall() public {
        // 12 USDG debt: required repay is tiny and the market's dust rule (rest < 10e6) closes the whole position
        vm.startPrank(bob);
        guard.enterBoosted();
        market.depositCollateral(0.13e18, bob); // $13
        market.borrow(12e6, bob); // 92.3 %
        vm.stopPrank();
        _startsIn(1 hours, WEEKEND);
        (bool ok,, uint256 stressCap, uint256 required,) = guard.quoteDeleverage(bob);
        assertTrue(ok);
        assertGt(stressCap, 0);
        vm.prank(keeper);
        (uint256 repaid,) = market.liquidate(bob, required, keeper);
        // rest = debt - repaid < minDebt, so the market repaid the full debt: allowed by the dust exception
        assertEq(repaid, 12e6);
        assertEq(market.debtOf(bob), 0);
    }

    function testFuzz_deleverageReachesTheTarget(uint256 debtPct, uint256 priceUsd) public {
        debtPct = bound(debtPct, 8940, 9300); // basis points of $10,000 value: above the 89.35 % stress cap
        _setupFlagged();
        if (debtPct < 9300) {
            vm.prank(bob);
            market.repay(9300e6 - debtPct * 1e6, bob);
        }
        _startsIn(1 hours, WEEKEND);
        priceUsd = bound(priceUsd, 100, 104); // price may drift up a little before the window
        oracle.setPrice(priceUsd * 1e18);
        (bool ok, uint256 debt,, uint256 required,) = guard.quoteDeleverage(bob);
        if (!ok) return;
        uint256 maxCall = (debt + 1) / 2; // market close factor 50 %
        uint256 repay = required < maxCall ? required : maxCall;
        uint256 cvBefore = market.collateralOf(bob) * priceUsd * 1e18 / 1e30;
        vm.prank(keeper);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, repay, keeper);
        uint256 debtAfter = market.debtOf(bob);
        uint256 cvAfter = market.collateralOf(bob) * priceUsd * 1e18 / 1e30;
        assertEq(repaid + debtAfter, debt, "debt accounting");
        assertLe(repaid, required);
        assertGt(seized, 0);
        // never worsens: debt/cv does not rise
        assertLe(debtAfter * cvBefore, debt * cvAfter + debt + cvBefore + 2, "ltv not worse");
        if (repay == required) {
            assertLe(debtAfter, cvAfter * 0.8885e18 / WAD + 3, "reaches the target when uncapped");
        }
    }

    // ---------------------------------------------------------------- guardian and governance

    function test_guardianCanOnlyTighten() public {
        vm.startPrank(guardian);
        guard.disableBoostedEntry();
        guard.blockBorrows();
        vm.stopPrank();
        assertTrue(guard.boostedEntryDisabled());
        assertTrue(guard.borrowsBlocked());

        vm.prank(bob);
        vm.expectRevert(SundownGuard.BoostedEntryDisabled.selector);
        guard.enterBoosted();

        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        vm.expectRevert(SundownGuard.BorrowsBlocked.selector);
        market.borrow(1000e6, alice);
        vm.stopPrank();

        // guardian cannot loosen, queue, execute or cancel anything
        SundownGuard.Params memory p = _p();
        vm.startPrank(guardian);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.clearGuardianFlags();
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.queueParams(p);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.cancelParams();
        vm.stopPrank();
        // strangers cannot use the guardian powers
        vm.prank(alice);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.blockBorrows();
        vm.prank(alice);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.disableBoostedEntry();
    }

    function test_blockedBorrowsLeaveRepayAndWithdrawOpen() public {
        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        market.borrow(2000e6, alice);
        vm.stopPrank();
        vm.prank(guardian);
        guard.blockBorrows();
        vm.startPrank(alice);
        market.withdrawCollateral(10e18, alice);
        market.repay(500e6, alice);
        vm.stopPrank();
    }

    function test_governanceClearsGuardianFlags() public {
        vm.startPrank(guardian);
        guard.disableBoostedEntry();
        guard.blockBorrows();
        vm.stopPrank();
        vm.prank(governance);
        guard.clearGuardianFlags();
        assertFalse(guard.boostedEntryDisabled());
        assertFalse(guard.borrowsBlocked());
        vm.prank(bob);
        guard.enterBoosted();
    }

    function test_hooksAreMarketOnly() public {
        vm.expectRevert(SundownGuard.NotMarket.selector);
        guard.onBorrow(_ctx(), 1);
        vm.expectRevert(SundownGuard.NotMarket.selector);
        guard.onLiquidate(_ctx(), keeper, 1, 1);
    }

    function _ctx() internal view returns (AccountCtx memory c) {
        c.account = alice;
        c.priceWad = 100e18;
    }

    function test_timelockedParameterChange() public {
        SundownGuard.Params memory p = _p();
        p.gapWeekend = 0.1e18;
        vm.prank(governance);
        guard.queueParams(p);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.TooEarly.selector, uint64(block.timestamp + 2 days)));
        guard.executeParams(p);

        SundownGuard.Params memory wrong = _p();
        wrong.gapWeekend = 0.11e18;
        vm.warp(block.timestamp + 2 days);
        vm.prank(governance);
        vm.expectRevert(SundownGuard.HashMismatch.selector);
        guard.executeParams(wrong);

        vm.prank(alice);
        vm.expectRevert(SundownGuard.Unauthorized.selector);
        guard.executeParams(p);

        vm.prank(governance);
        guard.executeParams(p);
        assertEq(guard.stressFraction(WEEKEND), 1e18 - 0.1e18 - 0.015e18);
        vm.prank(governance);
        vm.expectRevert(SundownGuard.NothingQueued.selector);
        guard.executeParams(p);
    }

    function test_queueRejectsOutOfBoundsAndCancelWorks() public {
        SundownGuard.Params memory p = _p();
        p.gapLong = 0.6e18;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("gapVar")));
        guard.queueParams(p);

        p = _p();
        p.deleverageMargin = 0.01e18;
        vm.startPrank(governance);
        guard.queueParams(p);
        guard.cancelParams();
        vm.expectRevert(SundownGuard.NothingQueued.selector);
        guard.cancelParams();
        vm.stopPrank();
    }

    function test_parametersCannotRaiseTheLltvAboveTheMarket() public {
        SundownGuard.Params memory p = _p();
        p.boostedLltv = 0.94e18; // market lltv is 0.93
        vm.startPrank(governance);
        guard.queueParams(p);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.InvalidParam.selector, bytes32("lltvAboveMarket")));
        guard.executeParams(p);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- repay is never blockable

    function test_repayAlwaysWorksWhateverTheGuardSays() public {
        _boostedPosition(bob, 100e18, 9300e6);
        vm.prank(guardian);
        guard.blockBorrows();
        oracle.setStatus(PriceStatus.Stale);
        _blind(WEEKEND);
        vm.prank(bob);
        market.repay(1000e6, bob);
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(bob);
        market.repay(1000e6, bob);
    }

    /// @dev A volatile asset: the stress fraction (85.5 %) is below the standard LLTV (86 %), so a standard account
    /// can sit above the stress cap while healthy. It must never be deleveraged.
    function test_standardAccountAboveTheStressCapIsNeverDeleveraged() public {
        SundownGuard.Params memory p = _p();
        p.gapWeekend = 0.13e18; // 1 - 13 % - 1.5 % = 85.5 %
        vm.prank(governance);
        guard.queueParams(p);
        vm.warp(block.timestamp + 2 days);
        vm.prank(governance);
        guard.executeParams(p);
        assertEq(guard.stressFraction(WEEKEND), 0.855e18);

        vm.startPrank(alice);
        market.depositCollateral(100e18, alice);
        market.borrow(8590e6, alice); // 85.9 %: above 85.5 %, below the 86 % threshold
        vm.stopPrank();
        _startsIn(1 hours, WEEKEND);
        (bool ok,,,,) = guard.quoteDeleverage(alice);
        assertFalse(ok, "standard account is not deleverage-eligible");
        vm.prank(keeper);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(alice, 100e6, keeper);

        // the same position as a boosted account (entered before the stress period) IS eligible
        // entering while above the stress-fit cap is refused (it cannot be used to start in breach)
        _farWindow();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SundownGuard.DoesNotFitStandard.selector, 8590e6, 8550e6));
        guard.enterBoosted();
        // an account that entered first and then borrowed up to the boosted cap IS eligible
        _boostedPosition(bob, 100e18, 8590e6);
        _startsIn(1 hours, WEEKEND);
        (ok,,,,) = guard.quoteDeleverage(bob);
        assertTrue(ok, "boosted account above the stress cap is eligible");
    }

    function test_gasOfTheStressCapPath() public {
        vm.startPrank(bob);
        guard.enterBoosted();
        market.depositCollateral(100e18, bob);
        vm.stopPrank();
        _startsIn(H, WEEKEND);
        uint256 g0 = gasleft();
        vm.prank(bob);
        market.borrow(8000e6, bob);
        uint256 used = g0 - gasleft();
        emit log_named_uint("borrow gas with SundownGuard (boosted, stress)", used);
        assertLt(used, 300_000);
    }
}
