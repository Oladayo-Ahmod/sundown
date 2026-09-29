// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {MarketBase} from "./MarketBase.sol";
import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {FlatGuard} from "../src/guards/FlatGuard.sol";
import {HaltReason, ISundownMarket, MarketParams, MarketState} from "../src/interfaces/ISundownMarket.sol";
import {PriceStatus} from "../src/interfaces/IEquityOracle.sol";
import {KinkedRate} from "../src/lib/KinkedRate.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {AccountCtx} from "../src/interfaces/IRiskGuard.sol";

contract SundownMarketTest is MarketBase {
    // ---------------------------------------------------------------- creation and validation

    function test_factoryCreatesInitializedClone() public view {
        assertTrue(factory.isMarket(address(market)));
        assertEq(factory.marketCount(), 1);
        assertEq(factory.marketAt(0), address(market));
        assertEq(factory.predictMarket(_params()), address(market));
        assertEq(market.name(), "Sundown TSLA/USD");
        assertEq(market.symbol(), "sdTSLA");
        assertEq(market.asset(), address(usd));
        assertEq(market.decimals(), 12); // 6 + offset 6
        SundownMarket.Config memory c = market.config();
        assertEq(c.collateralToken, address(stock));
        assertEq(c.guard, address(guard));
        assertEq(c.lltvWad, 0.8e18);
        assertEq(c.collateralDecimals, 18);
        assertEq(c.loanDecimals, 6);
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_implementationIsLockedAndCloneInitializesOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(_params());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize(_params());
    }

    function test_factoryRejectsZeroImplementation() public {
        vm.expectRevert(SundownMarketFactory.ZeroAddress.selector);
        new SundownMarketFactory(address(0), governance);
    }

    function test_onlyOwnerCreatesAndDuplicatesRevert() public {
        MarketParams memory p = _params();
        p.shareSymbol = "other";
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.createMarket(p);
        vm.prank(governance);
        address m2 = factory.createMarket(p);
        assertTrue(m2 != address(market));
        vm.prank(governance);
        vm.expectRevert(Errors.FailedDeployment.selector); // same parameters -> same clone address
        factory.createMarket(p);
    }

    function _expectInvalid(MarketParams memory p, bytes32 field) internal {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.InvalidParam.selector, field));
        factory.createMarket(p);
    }

    function test_parameterValidation() public {
        MarketParams memory p = _params();
        p.collateralToken = address(usd);
        _expectInvalid(p, "tokens");
        p = _params();
        p.lltvWad = 0;
        _expectInvalid(p, "lltv");
        p = _params();
        p.lltvWad = 0.99e18;
        _expectInvalid(p, "lltv");
        p = _params();
        p.closeFactorWad = 0;
        _expectInvalid(p, "closeFactor");
        p = _params();
        p.criticalHealthWad = 1e18;
        _expectInvalid(p, "criticalHealth");
        p = _params();
        p.maxBonusWad = 0.02e18;
        _expectInvalid(p, "maxBonus");
        p = _params();
        p.maxBonusWad = 0.06e18;
        _expectInvalid(p, "maxBonus");
        p = _params();
        p.collateralCap = 0;
        _expectInvalid(p, "collateralCap");
        p = _params();
        p.kinkWad = 1e18;
        _expectInvalid(p, "kink");
        p = _params();
        p.slope2AprWad = 6e18;
        _expectInvalid(p, "apr");
        p = _params();
        p.guard = address(0);
        vm.prank(governance);
        vm.expectRevert(ISundownMarket.ZeroAddress.selector);
        factory.createMarket(p);
    }

    function test_flatGuardBounds() public {
        vm.expectRevert(abi.encodeWithSelector(FlatGuard.InvalidParam.selector, bytes32("bonus")));
        new FlatGuard(0.75e18, 0.029e18);
        vm.expectRevert(abi.encodeWithSelector(FlatGuard.InvalidParam.selector, bytes32("bonus")));
        new FlatGuard(0.75e18, 0.056e18);
        vm.expectRevert(abi.encodeWithSelector(FlatGuard.InvalidParam.selector, bytes32("ltv")));
        new FlatGuard(1e18, 0.04e18);
        new FlatGuard(0.75e18, 0.03e18);
        new FlatGuard(0.75e18, 0.055e18);
    }

    // ---------------------------------------------------------------- vault

    function test_vaultDepositWithdrawAndShares() public {
        _lend(1000e6);
        assertEq(market.balanceOf(lender), 1000e6 * 1e6); // virtual shares 1e6: first deposit mints assets * 1e6
        assertEq(market.totalAssets(), 1000e6);
        assertEq(market.idleAssets(), 1000e6);
        vm.prank(lender);
        market.withdraw(400e6, lender, lender);
        assertEq(usd.balanceOf(lender), 1_000_000e6 - 600e6);
        assertEq(market.idleAssets(), 600e6);
        uint256 shares = market.balanceOf(lender);
        vm.prank(lender);
        market.redeem(shares, lender, lender);
        assertEq(market.totalAssets(), 0);
        assertEq(market.idleAssets(), 0);
    }

    function test_maxWithdrawAndRedeemLimitedByIdle() public {
        _lend(10_000e6);
        _borrow(100e18, 7000e6);
        assertEq(market.idleAssets(), 3000e6);
        assertEq(market.maxWithdraw(lender), 3000e6);
        uint256 maxShares = market.maxRedeem(lender);
        assertApproxEqAbs(market.previewRedeem(maxShares), 3000e6, 1);
        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, lender, 3001e6, 3000e6)
        );
        market.withdraw(3001e6, lender, lender);
    }

    function test_donationDoesNotMoveSharePrice() public {
        _lend(1000e6);
        uint256 supplyBefore = market.totalAssets();
        usd.mint(address(market), 5000e6); // direct transfer: not credited
        assertEq(market.totalAssets(), supplyBefore);
        assertEq(market.idleAssets(), 1000e6);
        assertEq(market.convertToAssets(market.balanceOf(lender)), 1000e6);
    }

    function test_firstDepositorInflationAttackFails() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        usd.mint(attacker, 20_000e6);
        usd.mint(victim, 10_000e6);
        vm.startPrank(attacker);
        usd.approve(address(market), type(uint256).max);
        market.deposit(1, attacker); // 1 wei
        usd.transfer(address(market), 10_000e6); // donation: ignored by the ledger
        vm.stopPrank();
        vm.startPrank(victim);
        usd.approve(address(market), type(uint256).max);
        uint256 shares = market.deposit(10_000e6, victim);
        vm.stopPrank();
        assertGt(shares, 0);
        // the victim can redeem (almost) everything; the attacker lost the donation
        assertApproxEqAbs(market.previewRedeem(shares), 10_000e6, 2);
        assertLe(market.previewRedeem(market.balanceOf(attacker)), 2);
    }

    function test_feeOnTransferLoanTokenRejected() public {
        MockFeeToken fee = new MockFeeToken();
        MarketParams memory p = _params();
        p.loanToken = address(fee);
        p.shareSymbol = "fee";
        vm.prank(governance);
        SundownMarket m = SundownMarket(factory.createMarket(p));
        fee.mint(lender, 1000e18);
        vm.startPrank(lender);
        fee.approve(address(m), type(uint256).max);
        vm.expectRevert(ISundownMarket.UnsupportedToken.selector);
        m.deposit(100e18, lender);
        vm.stopPrank();
    }

    function test_feeOnTransferCollateralRejected() public {
        MockFeeToken fee = new MockFeeToken();
        MarketParams memory p = _params();
        p.collateralToken = address(fee);
        p.shareSymbol = "fee2";
        vm.prank(governance);
        SundownMarket m = SundownMarket(factory.createMarket(p));
        fee.mint(borrower, 100e18);
        vm.startPrank(borrower);
        fee.approve(address(m), type(uint256).max);
        vm.expectRevert(ISundownMarket.UnsupportedToken.selector);
        m.depositCollateral(10e18, borrower);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- collateral

    function test_collateralDepositCapAndWithdraw() public {
        stock.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        market.depositCollateral(1000e18, borrower);
        assertEq(market.totalCollateral(), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.CollateralCapExceeded.selector, 1000e18 + 1, 1000e18));
        market.depositCollateral(1, borrower);
        market.withdrawCollateral(400e18, borrower);
        assertEq(market.collateralOf(borrower), 600e18);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.InsufficientCollateral.selector, 601e18, 600e18));
        market.withdrawCollateral(601e18, borrower);
        vm.stopPrank();
    }

    function test_collateralZeroAndZeroAddressReverts() public {
        vm.startPrank(borrower);
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.depositCollateral(0, borrower);
        vm.expectRevert(ISundownMarket.ZeroAddress.selector);
        market.depositCollateral(1, address(0));
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.withdrawCollateral(0, borrower);
        vm.expectRevert(ISundownMarket.ZeroAddress.selector);
        market.withdrawCollateral(1, address(0));
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.borrow(0, borrower);
        vm.expectRevert(ISundownMarket.ZeroAddress.selector);
        market.borrow(1, address(0));
        vm.stopPrank();
    }

    function test_withdrawCollateralChecksCapacityWithDebt() public {
        _lend(100_000e6);
        _borrow(100e18, 3000e6); // needs collateral value >= 4000 => >= 40 tokens
        vm.startPrank(borrower);
        market.withdrawCollateral(60e18, borrower);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, 3000e6, 2_999_999_925));
        market.withdrawCollateral(1e12, borrower); // 39.999999 tokens left -> value 3,999,999,900 -> cap 2,999,999,925
        vm.stopPrank();
    }

    function test_withdrawCollateralWithoutDebtNeedsNoOracle() public {
        stock.mint(borrower, 10e18);
        vm.startPrank(borrower);
        market.depositCollateral(10e18, borrower);
        vm.stopPrank();
        oracle.setStatus(PriceStatus.Invalid);
        vm.prank(borrower);
        market.withdrawCollateral(10e18, borrower);
        assertEq(market.collateralOf(borrower), 0);
    }

    // ---------------------------------------------------------------- borrow

    function test_borrowCapacityIsFlatLtv() public {
        _lend(100_000e6);
        vm.startPrank(borrower);
        market.depositCollateral(100e18, borrower); // $10,000 -> 75 % = 7,500
        market.borrow(7500e6, borrower);
        assertEq(market.debtOf(borrower), 7500e6);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, 7500e6 + 1, 7500e6));
        market.borrow(1, borrower);
        vm.stopPrank();
        assertEq(usd.balanceOf(borrower), 100_000e6 + 7500e6);
        assertEq(market.totalBorrowAssets(), 7500e6);
        assertEq(market.idleAssets(), 92_500e6);
    }

    function test_borrowMinDebtAndIdle() public {
        _lend(1000e6);
        vm.startPrank(borrower);
        market.depositCollateral(100e18, borrower);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.BelowMinDebt.selector, 5e6, 10e6));
        market.borrow(5e6, borrower);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.InsufficientIdle.selector, 2000e6, 1000e6));
        market.borrow(2000e6, borrower);
        vm.stopPrank();
    }

    function test_borrowRevertsOnUnusablePrices() public {
        _lend(100_000e6);
        vm.prank(borrower);
        market.depositCollateral(100e18, borrower);
        PriceStatus[3] memory bad = [PriceStatus.Invalid, PriceStatus.CorporateAction, PriceStatus.SequencerDown];
        for (uint256 i; i < bad.length; ++i) {
            oracle.setStatus(bad[i]);
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(bad[i])));
            market.borrow(100e6, borrower);
        }
        oracle.setStatus(PriceStatus.Fresh);
        oracle.setPrice(0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.Fresh)));
        market.borrow(100e6, borrower);
    }

    function test_controlIgnoresBlindStaleAndHaircut() public {
        _lend(100_000e6);
        vm.prank(borrower);
        market.depositCollateral(100e18, borrower);
        oracle.setHaircut(0.5e18);
        PriceStatus[3] memory ok = [PriceStatus.ScheduledBlind, PriceStatus.Reopening, PriceStatus.Stale];
        for (uint256 i; i < ok.length; ++i) {
            oracle.setStatus(ok[i]);
            vm.prank(borrower);
            market.borrow(100e6, borrower);
        }
        assertEq(market.debtOf(borrower), 300e6);
    }

    // ---------------------------------------------------------------- interest

    function test_interestAccruesAndLendersEarn() public {
        _lend(100_000e6);
        _borrow(100e18, 7400e6);
        uint256 supplyBefore = market.totalAssets();
        vm.warp(block.timestamp + 365 days);
        market.accrue();
        // util 7.4 % -> APR 0.04 * 0.074 / 0.8 = 0.37 %; 7400e6 * (e^0.0037 - 1) ~ 27.430 USD
        uint256 interest = market.totalBorrowAssets() - 7400e6;
        assertGt(interest, 27_430_000);
        assertLt(interest, 27_431_000);
        assertEq(market.totalAssets(), supplyBefore + interest);
        assertEq(market.debtOf(borrower), 7400e6 + interest);
        assertGt(market.convertToAssets(market.balanceOf(lender)), 100_000e6);
    }

    function test_totalAssetsViewIncludesPendingInterest() public {
        _lend(100_000e6);
        _borrow(100e18, 7400e6);
        vm.warp(block.timestamp + 30 days);
        uint256 view_ = market.totalAssets();
        market.accrue();
        assertEq(market.totalAssets(), view_);
        assertEq(market.debtOf(borrower), market.totalBorrowAssets());
    }

    // ---------------------------------------------------------------- repay

    function test_repayPartialFullAndForOthers() public {
        _lend(100_000e6);
        _borrow(100e18, 5000e6);
        vm.prank(borrower);
        (uint256 paid, uint256 burned) = market.repay(1000e6, borrower);
        assertEq(paid, 1000e6);
        assertEq(burned, 1000e6 * 1e6);
        assertEq(market.debtOf(borrower), 4000e6);
        // anyone repays for anyone
        vm.prank(liquidator);
        market.repay(500e6, borrower);
        assertEq(market.debtOf(borrower), 3500e6);
        // overpay is capped at the debt
        usd.mint(borrower, 10_000e6);
        vm.prank(borrower);
        (paid,) = market.repay(10_000e6, borrower);
        assertEq(paid, 3500e6);
        assertEq(market.debtOf(borrower), 0);
        assertEq(market.totalBorrowAssets(), 0);
        assertEq(market.totalBorrowShares(), 0);
        vm.prank(borrower);
        vm.expectRevert(ISundownMarket.NothingToRepay.selector);
        market.repay(1, borrower);
    }

    function test_repaySharesAndDust() public {
        _lend(100_000e6);
        _borrow(100e18, 5000e6);
        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.BelowMinDebt.selector, 5e6, 10e6));
        market.repay(4995e6, borrower); // would leave 5 USD
        uint256 paid = market.repayShares(1000e6 * 1e6, borrower);
        assertEq(paid, 1000e6);
        paid = market.repayShares(type(uint256).max, borrower); // capped at all shares
        assertEq(paid, 4000e6);
        vm.expectRevert(ISundownMarket.NothingToRepay.selector);
        market.repayShares(1, borrower);
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.repayShares(0, borrower);
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.repay(0, borrower);
        vm.stopPrank();
    }

    function test_repayNeverReadsOracle() public {
        _lend(100_000e6);
        _borrow(100e18, 5000e6);
        oracle.setStatus(PriceStatus.Invalid);
        vm.prank(borrower);
        market.repay(5000e6, borrower);
        assertEq(market.debtOf(borrower), 0);
    }

    // ---------------------------------------------------------------- liquidation

    function _setup7400() internal {
        _lend(100_000e6);
        _borrow(100e18, 7400e6);
    }

    function test_liquidateRevertsWhenHealthy() public {
        _setup7400();
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(borrower, 1000e6, liquidator);
        oracle.setPrice(92e18); // cv 9200 * 0.8 = 7360 < 7400 -> liquidatable
        assertLt(market.healthFactor(borrower), 1e18);
        oracle.setPrice(93e18); // 7440 >= 7400
        assertGt(market.healthFactor(borrower), 1e18);
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.NotLiquidatable.selector);
        market.liquidate(borrower, 1000e6, liquidator);
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.NoDebt.selector);
        market.liquidate(liquidator, 1, liquidator);
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.liquidate(borrower, 0, liquidator);
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.ZeroAddress.selector);
        market.liquidate(borrower, 1, address(0));
    }

    function test_liquidatePartialByCloseFactor() public {
        _setup7400();
        oracle.setPrice(90e18); // cv 9000, threshold 7200 < 7400; HF 0.973 > 0.95 -> 50 % close factor
        uint256 supplyBefore = market.totalAssets();
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, 7400e6, liquidator);
        assertEq(repaid, 3700e6);
        // 3700 * 1.04 = 3848 USD of collateral at $90
        assertEq(seized, 42_755_555_555_555_555_555);
        assertEq(stock.balanceOf(liquidator), seized);
        assertEq(market.debtOf(borrower), 3700e6);
        assertEq(market.collateralOf(borrower), 100e18 - seized);
        assertEq(market.totalBorrowAssets(), 3700e6);
        assertEq(market.idleAssets(), 100_000e6 - 7400e6 + 3700e6);
        assertEq(market.totalAssets(), supplyBefore); // no loss for lenders
        assertEq(market.totalCollateral(), 100e18 - seized);
    }

    function test_liquidateFullBelowCriticalHealth() public {
        _setup7400();
        oracle.setPrice(80e18); // cv 8000, threshold 6400, HF 0.865 < 0.95 -> whole debt
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, type(uint256).max, liquidator);
        assertEq(repaid, 7400e6);
        assertEq(seized, 96_200_000_000_000_000_000); // 7400 * 1.04 / 80 = 96.2 tokens
        assertEq(market.debtOf(borrower), 0);
        assertEq(market.totalBorrowAssets(), 0);
        assertEq(market.totalBorrowShares(), 0);
        assertEq(market.collateralOf(borrower), 3_800_000_000_000_000_000);
    }

    function test_liquidationBonusCappedByNonWorseningRule() public {
        _setup7400();
        oracle.setPrice(76e18); // cv 7600 vs debt 7400: a 4 % bonus would seize 7696 > 7600
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, 7400e6, liquidator);
        assertEq(repaid, 7400e6);
        // bonus capped at cv/debt - 1 = 2.7027 %: seizes just under the whole collateral, never more value
        assertEq(seized, 99_999_999_986_842_105_263);
        assertLt(seized, 100e18);
        assertEq(market.debtOf(borrower), 0);
    }

    function test_liquidateInsolventSeizesAllAndLeavesBadDebt() public {
        _setup7400();
        oracle.setPrice(60e18); // cv 6000 < debt 7400
        uint256 supplyBefore = market.totalAssets();
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, 7400e6, liquidator);
        assertEq(seized, 100e18); // all collateral
        assertEq(repaid, 5_769_230_769); // 6000 / 1.04: the liquidator never pays for collateral that is not there
        assertEq(market.collateralOf(borrower), 0);
        assertEq(market.debtOf(borrower), 1_630_769_231);
        // the loss is NOT yet recognized: it stays in totalAssets until realizeBadDebt
        assertEq(market.totalAssets(), supplyBefore - 0);

        uint256 sharePriceBefore = market.convertToAssets(1e12);
        vm.expectEmit(true, false, false, true, address(market));
        emit ISundownMarket.BadDebtRealized(borrower, 1_630_769_231, supplyBefore - 1_630_769_231);
        uint256 written = market.realizeBadDebt(borrower);
        assertEq(written, 1_630_769_231);
        assertEq(market.badDebtRealized(), 1_630_769_231);
        assertEq(market.totalAssets(), supplyBefore - 1_630_769_231);
        assertLt(market.convertToAssets(1e12), sharePriceBefore); // the ONLY path that lowers the share price
        assertEq(market.totalBorrowAssets(), 0);
        assertEq(market.totalBorrowShares(), 0);
    }

    function test_realizeBadDebtRules() public {
        _setup7400();
        vm.expectRevert(ISundownMarket.HasCollateral.selector);
        market.realizeBadDebt(borrower);
        vm.expectRevert(ISundownMarket.NoDebt.selector);
        market.realizeBadDebt(liquidator);
    }

    /// @dev A second market with its own approvals, sharing the fixture's tokens, oracle and lender balances.
    function _newMarket(MarketParams memory p) internal returns (SundownMarket m) {
        vm.prank(governance);
        m = SundownMarket(factory.createMarket(p));
        address[3] memory who = [lender, borrower, liquidator];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            usd.approve(address(m), type(uint256).max);
            stock.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_liquidationDustRuleForcesFullRepay() public {
        MarketParams memory p = _params();
        p.minDebt = 3800e6; // a 50 % partial liquidation of 7400 would leave 3700 < 3800
        p.shareSymbol = "dust";
        SundownMarket m = _newMarket(p);
        vm.prank(lender);
        m.deposit(100_000e6, lender);
        vm.startPrank(borrower);
        m.depositCollateral(100e18, borrower);
        m.borrow(7400e6, borrower);
        vm.stopPrank();
        oracle.setPrice(90e18); // liquidatable, HF 0.973 > critical -> close factor 50 %
        vm.prank(liquidator);
        (uint256 repaid,) = m.liquidate(borrower, 7400e6, liquidator);
        assertEq(repaid, 7400e6, "dust remainder forces a full repay");
        assertEq(m.debtOf(borrower), 0);
    }

    function test_liquidationRevertsOnUnusablePrice() public {
        _setup7400();
        oracle.setPrice(60e18);
        oracle.setStatus(PriceStatus.CorporateAction);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.CorporateAction))
        );
        market.liquidate(borrower, 1000e6, liquidator);
    }

    function test_marketBonusCapOverridesGuard() public {
        MarketParams memory p = _params();
        p.maxBonusWad = 0.03e18;
        p.shareSymbol = "cap3";
        FlatGuard g = new FlatGuard(0.75e18, 0.055e18);
        p.guard = address(g);
        SundownMarket m = _newMarket(p);
        vm.prank(lender);
        m.deposit(100_000e6, lender);
        vm.startPrank(borrower);
        m.depositCollateral(100e18, borrower);
        m.borrow(7400e6, borrower);
        vm.stopPrank();
        oracle.setPrice(80e18);
        vm.prank(liquidator);
        (, uint256 seized) = m.liquidate(borrower, 7400e6, liquidator);
        assertEq(seized, 95_275_000_000_000_000_000); // 7400 * 1.03 / 80: the market cap (3 %) beats the guard (5.5 %)
    }

    // ---------------------------------------------------------------- halt

    function test_guardianHaltGatesAndResume() public {
        _lend(100_000e6);
        _borrow(100e18, 5000e6);
        vm.expectRevert(ISundownMarket.Unauthorized.selector);
        market.guardianHalt();
        vm.prank(guardian);
        vm.expectEmit(true, true, false, true, address(market));
        emit ISundownMarket.MarketHalted(HaltReason.Guardian, guardian);
        market.guardianHalt();
        assertEq(uint8(market.state()), uint8(MarketState.Halted));
        assertEq(uint8(market.haltReason()), uint8(HaltReason.Guardian));
        vm.prank(guardian);
        vm.expectRevert(ISundownMarket.AlreadyHalted.selector);
        market.guardianHalt();

        // blocked while halted
        assertEq(market.maxDeposit(lender), 0);
        assertEq(market.maxMint(lender), 0);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, lender, 1e6, 0));
        market.deposit(1e6, lender);
        vm.startPrank(borrower);
        vm.expectRevert(ISundownMarket.NotActive.selector);
        market.borrow(100e6, borrower);
        vm.expectRevert(ISundownMarket.NotActive.selector);
        market.withdrawCollateral(1e18, borrower);
        // allowed while halted: repay, collateral deposit, lender exits
        market.repay(1000e6, borrower);
        market.depositCollateral(1e18, borrower);
        vm.stopPrank();
        vm.prank(lender);
        market.withdraw(1000e6, lender, lender);
        // liquidation has no halt gate (debt 4000 vs 101 tokens: liquidatable below ~$49)
        oracle.setPrice(40e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 1000e6, liquidator);

        vm.expectRevert(ISundownMarket.Unauthorized.selector);
        market.resume();
        vm.prank(guardian);
        vm.expectEmit(true, false, false, false, address(market));
        emit ISundownMarket.MarketResumed(guardian, 0);
        market.resume();
        assertEq(uint8(market.state()), uint8(MarketState.Active));
        assertEq(uint8(market.haltReason()), uint8(HaltReason.None));
        assertEq(market.haltedAt(), 0);
        vm.prank(guardian);
        vm.expectRevert(ISundownMarket.NotHalted.selector);
        market.resume();
    }

    function test_governanceCanResumeUnconditionally() public {
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(governance);
        market.resume();
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_accrualFrozenThirtyDaysThenResumesWhileHalted() public {
        _lend(100_000e6);
        _borrow(100e18, 7400e6);
        vm.prank(guardian);
        market.guardianHalt();
        uint256 debt0 = market.totalBorrowAssets();
        vm.warp(block.timestamp + 29 days);
        market.accrue();
        assertEq(market.totalBorrowAssets(), debt0, "frozen for the first 30 days");
        assertEq(market.debtOf(borrower), debt0);
        vm.warp(block.timestamp + 2 days); // day 31: exactly one day of interest
        uint256 util = uint256(debt0) * 1e18 / (market.idleAssets() + debt0);
        KinkedRate.Params memory ip = KinkedRate.Params(0, 0.04e18, 0.75e18, 0.8e18);
        uint256 f = KinkedRate.compoundFactor(KinkedRate.ratePerSecond(ip, util), 1 days);
        uint256 expected = (debt0 * f + 1e18 - 1) / 1e18;
        assertGt(expected, 0);
        market.accrue();
        assertEq(market.totalBorrowAssets(), debt0 + expected, "accrual resumes by itself after 30 days");
        // resume books nothing extra at the same timestamp
        vm.prank(governance);
        market.resume();
        assertEq(market.totalBorrowAssets(), debt0 + expected);
    }

    function test_resumeBooksInterestFromDayThirty() public {
        _lend(100_000e6);
        _borrow(100e18, 7400e6);
        vm.prank(guardian);
        market.guardianHalt();
        uint256 debt0 = market.totalBorrowAssets();
        vm.warp(block.timestamp + 40 days);
        vm.prank(governance);
        market.resume();
        assertGt(market.totalBorrowAssets(), debt0); // 10 days of interest
        // and no more interest is charged retroactively for the first 30 days: compare with 10 days
        uint256 util = uint256(debt0) * 1e18 / (100_000e6 - 7400e6 + debt0);
        KinkedRate.Params memory ip = KinkedRate.Params(0, 0.04e18, 0.75e18, 0.8e18);
        uint256 f = KinkedRate.compoundFactor(KinkedRate.ratePerSecond(ip, util), 10 days);
        assertEq(market.totalBorrowAssets(), debt0 + (debt0 * f + 1e18 - 1) / 1e18);
    }

    // ---------------------------------------------------------------- remaining branches

    function test_decimalsAboveEighteenRejected() public {
        MockERC20 big = new MockERC20("Big", "BIG", 19);
        MarketParams memory p = _params();
        p.collateralToken = address(big);
        _expectInvalid(p, "collateralDecimals");
        p = _params();
        p.loanToken = address(big);
        _expectInvalid(p, "loanDecimals");
    }

    function test_nonStandardDecimalsScaleCollateralValue() public {
        // 8-decimal collateral priced at $100 vs the 6-decimal loan token: value = c * 100e18 / 10^(8 + 18 - 6)
        MockERC20 wbtc = new MockERC20("W", "W", 8);
        MarketParams memory p = _params();
        p.collateralToken = address(wbtc);
        p.shareSymbol = "d8";
        SundownMarket m = _newMarket(p);
        wbtc.mint(borrower, 10e8);
        vm.prank(lender);
        m.deposit(100_000e6, lender);
        vm.startPrank(borrower);
        wbtc.approve(address(m), type(uint256).max);
        m.depositCollateral(1e8, borrower); // one whole token = $100
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.ExceedsCapacity.selector, 75e6 + 1, 75e6));
        m.borrow(75e6 + 1, borrower);
        m.borrow(75e6, borrower);
        vm.stopPrank();
        assertEq(m.debtOf(borrower), 75e6);
    }

    function test_liquidationThatRoundsToZeroReverts() public {
        _setup7400();
        oracle.setPrice(1); // one wei per token: collateral value rounds down to zero
        vm.prank(liquidator);
        vm.expectRevert(ISundownMarket.ZeroAmount.selector);
        market.liquidate(borrower, 7400e6, liquidator);
    }

    function test_flatGuardHooksAreCallableNoOps() public {
        AccountCtx memory c;
        guard.onBorrow(c, 1);
        guard.onLiquidate(c, liquidator, 1, 1);
        assertEq(guard.liquidationBonus(c, 1), 0.04e18);
    }

    function test_resumeRejectsStrangers() public {
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(borrower);
        vm.expectRevert(ISundownMarket.Unauthorized.selector);
        market.resume();
    }

    // ---------------------------------------------------------------- misc views

    function test_healthFactorWithoutDebtIsMax() public view {
        assertEq(market.healthFactor(borrower), type(uint256).max);
    }

    function test_positionOfAndGuardHooksCalled() public {
        _lend(100_000e6);
        _borrow(100e18, 1000e6);
        SundownMarket.Position memory pos = market.positionOf(borrower);
        assertEq(pos.collateral, 100e18);
        assertGt(pos.borrowShares, 0);
    }
}
