// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {FlatGuard} from "../src/guards/FlatGuard.sol";
import {MarketParams} from "../src/interfaces/ISundownMarket.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

/// @dev Shared fixture: an 18-decimal stock token at $100, a 6-decimal USD loan token, a flat-guard market
/// (borrow LTV 75 %, LLTV 80 %, bonus 4 %, close factor 50 %, critical health 0.95, min debt $10).
abstract contract MarketBase is Test {
    uint256 internal constant WAD = 1e18;

    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal stock;
    MockERC20 internal usd;
    MockEquityOracle internal oracle;
    FlatGuard internal guard;
    SundownMarket internal impl;
    SundownMarketFactory internal factory;
    SundownMarket internal market;

    function _params() internal view returns (MarketParams memory p) {
        p = MarketParams({
            collateralToken: address(stock),
            loanToken: address(usd),
            oracle: address(oracle),
            guard: address(guard),
            guardian: guardian,
            governance: governance,
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
            shareName: "Sundown TSLA/USD",
            shareSymbol: "sdTSLA"
        });
    }

    function setUp() public virtual {
        stock = new MockERC20("Stock", "STK", 18);
        usd = new MockERC20("USD", "USD", 6);
        oracle = new MockEquityOracle(100e18);
        guard = new FlatGuard(0.75e18, 0.04e18);
        impl = new SundownMarket();
        factory = new SundownMarketFactory(address(impl), governance);
        vm.prank(governance);
        market = SundownMarket(factory.createMarket(_params()));

        stock.mint(borrower, 10_000e18);
        usd.mint(lender, 1_000_000e6);
        usd.mint(liquidator, 1_000_000e6);
        usd.mint(borrower, 100_000e6);
        for (uint256 i; i < 3; ++i) {
            address a = i == 0 ? lender : i == 1 ? borrower : liquidator;
            vm.startPrank(a);
            usd.approve(address(market), type(uint256).max);
            stock.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _lend(uint256 assets) internal {
        vm.prank(lender);
        market.deposit(assets, lender);
    }

    /// @dev Borrower deposits `collateral` tokens and borrows `assets` loan units.
    function _borrow(uint256 collateral, uint256 assets) internal {
        vm.startPrank(borrower);
        market.depositCollateral(collateral, borrower);
        market.borrow(assets, borrower);
        vm.stopPrank();
    }
}
