// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleBase} from "./Oracle.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGuard} from "./mocks/MockGuard.sol";
import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {ISundownMarket, MarketParams} from "../src/interfaces/ISundownMarket.sol";
import {AccountCtx} from "../src/interfaces/IRiskGuard.sol";
import {PriceStatus} from "../src/interfaces/IEquityOracle.sol";
import {UsMarketCalendar as Cal} from "../src/lib/UsMarketCalendar.sol";

/// @dev The real {ChainlinkEquityOracle} (with a controllable mock feed, the real calendar and window cache)
/// driving a real {SundownMarket} through a recording guard.
contract OracleMarketTest is OracleBase {
    MockERC20 internal usd;
    MockGuard internal guard;
    SundownMarket internal market;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public override {
        super.setUp();
        usd = new MockERC20("USD", "USD", 6);
        guard = new MockGuard();
        SundownMarket impl = new SundownMarket();
        SundownMarketFactory factory = new SundownMarketFactory(address(impl), address(this));
        market = SundownMarket(
            factory.createMarket(
                MarketParams({
                    collateralToken: address(token),
                    loanToken: address(usd),
                    oracle: address(oracle),
                    guard: address(guard),
                    guardian: makeAddr("guardian"),
                    governance: makeAddr("governance"),
                    lltvWad: 0.8e18,
                    closeFactorWad: 0.5e18,
                    criticalHealthWad: 0.95e18,
                    maxBonusWad: 0.055e18,
                    collateralCap: 1000e18,
                    minDebt: 10e6,
                    baseAprWad: 0,
                    slope1AprWad: 0.04e18,
                    slope2AprWad: 0.75e18,
                    kinkWad: 0.8e18,
                    shareName: "Sundown MSTK",
                    shareSymbol: "sdMSTK"
                })
            )
        );
        usd.mint(lender, 1_000_000e6);
        usd.mint(liquidator, 1_000_000e6);
        token.mint(borrower, 1000e18);
        vm.prank(lender);
        usd.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usd.approve(address(market), type(uint256).max);
        vm.prank(borrower);
        token.approve(address(market), type(uint256).max);
        vm.prank(lender);
        market.deposit(500_000e6, lender);
        feed.set(370e8, block.timestamp - 10 minutes);
    }

    function _borrow(uint256 collateral, uint256 assets) internal {
        vm.startPrank(borrower);
        market.depositCollateral(collateral, borrower);
        market.borrow(assets, borrower);
        vm.stopPrank();
    }

    function test_marketForwardsFreshPriceHaircutAndWindowId() public {
        _borrow(10e18, 1000e6);
        AccountCtx memory c = guard.lastBorrowCtx();
        assertEq(uint8(c.status), uint8(PriceStatus.Fresh));
        assertEq(c.priceWad, 370e18);
        assertEq(c.haircutWad, 0.005e18);
        assertEq(c.updatedAt, T0 - 10 minutes);
        assertEq(c.windowId, Cal.dayIndex(2026, 9, 4));
        assertEq(c.collateralValue, 3700e6); // 10 tokens * $370 in 6-decimal loan units
        assertEq(c.debtAssets, 1000e6);
    }

    function test_marketForwardsStatusesThatTheGuardDecidesOn() public {
        vm.prank(borrower);
        market.depositCollateral(10e18, borrower);
        // scheduled blindness (Labor Day weekend): the price is the frozen Friday price
        vm.warp(1_788_700_000);
        feed.set(370e8, LD_START - 3 hours);
        vm.prank(borrower);
        market.borrow(100e6, borrower);
        assertEq(uint8(guard.lastBorrowCtx().status), uint8(PriceStatus.ScheduledBlind));
        // reopening: live again, price still older than the window end
        vm.warp(LD_END + 30);
        vm.prank(borrower);
        market.borrow(100e6, borrower);
        assertEq(uint8(guard.lastBorrowCtx().status), uint8(PriceStatus.Reopening));
        // fresh again after the first post-window update
        feed.set(372e8, LD_END + 25);
        vm.prank(borrower);
        market.borrow(100e6, borrower);
        assertEq(uint8(guard.lastBorrowCtx().status), uint8(PriceStatus.Fresh));
        assertEq(guard.lastBorrowCtx().priceWad, 372e18);
        // stale (unscheduled blindness): a guard that refuses new debt in this state blocks the borrow
        vm.warp(LD_END + 3 days);
        guard.set(0, true, 0.04e18); // a session-aware guard would return 0 capacity on Stale
        vm.prank(borrower);
        vm.expectPartialRevert(ISundownMarket.ExceedsCapacity.selector); // debt ~400 USD (+ 3 days of interest), cap 0
        market.borrow(100e6, borrower);
    }

    function test_unusablePricesBlockPriceDependentActionsButNotRepay() public {
        _borrow(10e18, 1000e6);
        token.setOraclePaused(true); // corporate action in progress
        vm.startPrank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.CorporateAction))
        );
        market.borrow(100e6, borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.CorporateAction))
        );
        market.withdrawCollateral(1e18, borrower);
        vm.stopPrank();
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.CorporateAction))
        );
        market.liquidate(borrower, 100e6, liquidator);
        // repay never reads the oracle
        usd.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        usd.approve(address(market), type(uint256).max);
        market.repay(1000e6, borrower);
        market.withdrawCollateral(10e18, borrower); // no debt left: no oracle read
        vm.stopPrank();
    }

    function test_collateralDepositNeverReadsTheOracle() public {
        feed.set(0, block.timestamp); // invalid feed
        vm.prank(borrower);
        market.depositCollateral(1e18, borrower);
        assertEq(market.collateralOf(borrower), 1e18);
    }

    function test_liquidationUsesTheFeedPrice() public {
        _borrow(100e18, 25_000e6); // $37,000 collateral at $370, debt $25,000
        guard.set(type(uint256).max, true, 0.04e18);
        feed.set(260e8, block.timestamp); // price drops to $260: cv 26,000, threshold 20,800 < 25,000
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, 25_000e6, liquidator);
        assertEq(repaid, 25_000e6); // health 0.832 < 0.95 -> whole debt
        // 25,000 * 1.04 = 26,000 USD at $260 -> 100 tokens = all collateral (bonus capped at cv/debt - 1 = 4 %)
        assertEq(seized, 100e18);
        assertEq(uint8(guard.lastLiquidateCtx().status), uint8(PriceStatus.Fresh));
    }

    function test_gasOfBorrowWithOracleAndWarmCache() public {
        vm.prank(borrower);
        market.depositCollateral(10e18, borrower);
        vm.prank(borrower);
        market.borrow(100e6, borrower); // warms the window cache and storage
        vm.prank(borrower);
        uint256 g = gasleft();
        market.borrow(100e6, borrower);
        uint256 used = g - gasleft();
        assertLt(used, 230_000, "borrow including oracle, cache and guard hook (design target 230k)");
    }
}
