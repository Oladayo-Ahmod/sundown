// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SundownMarket} from "../../src/SundownMarket.sol";
import {MarketState} from "../../src/interfaces/ISundownMarket.sol";
import {PriceStatus} from "../../src/interfaces/IEquityOracle.sol";
import {MockEquityOracle} from "../mocks/MockEquityOracle.sol";
import {MockIssuerRegistry, MockStockIssuerToken, MockUsdgToken} from "../mocks/IssuerMocks.sol";

/// @dev Drives a {SundownMarket} with lenders, borrowers, liquidators, an oracle mover, a time warper, the
/// guardian, governance and an issuer that can pause, block and burn. Every call is wrapped in try/catch (a
/// revert is a legitimate outcome); the handler records GHOST VIOLATIONS that the invariant contract asserts are
/// zero. The ghost checks are computed independently of the market's own code.
contract MarketHandler is Test {
    SundownMarket public immutable market;
    MockStockIssuerToken public immutable stock;
    MockUsdgToken public immutable usdg;
    MockEquityOracle public immutable oracle;
    MockIssuerRegistry public immutable registry;
    address public immutable guardian;
    address public immutable governance;

    address[] public lenders;
    address[] public borrowers;
    address[] public liquidators;

    // ghost violations (must stay 0)
    uint256 public vCapacity; // a borrow/withdraw left a position above min(guard ltv, lltv) at the used price
    uint256 public vLiquidation; // a solvent liquidation raised the position's loan-to-value
    uint256 public vSharePrice; // the share price fell without BadDebtRealized
    uint256 public vRepay; // a full repay reverted although the loan token was healthy
    uint256 public vHalt; // a halted market accepted supply, a borrow or a collateral withdrawal
    uint256 public vFrozen; // interest accrued during the first 30 days of a halt
    uint256 public vBadDebtDecrease; // badDebtRealized decreased

    // ghost bookkeeping
    uint256 public ghostBurned; // collateral burned out of the market by the issuer
    uint256 public lastBadDebt;
    bool private _realized;
    mapping(bytes32 => uint256) public calls;

    constructor(
        SundownMarket market_,
        MockStockIssuerToken stock_,
        MockUsdgToken usdg_,
        MockEquityOracle oracle_,
        MockIssuerRegistry registry_,
        address guardian_,
        address governance_
    ) {
        market = market_;
        stock = stock_;
        usdg = usdg_;
        oracle = oracle_;
        registry = registry_;
        guardian = guardian_;
        governance = governance_;
        for (uint256 i; i < 3; ++i) {
            lenders.push(_actor("lender", i, true));
            borrowers.push(_actor("borrower", i, false));
        }
        for (uint256 i; i < 2; ++i) {
            liquidators.push(_actor("liquidator", i, true));
        }
        // seed liquidity and collateral so the run exercises borrow/liquidate/repay rather than reverting
        vm.prank(lenders[0]);
        market.deposit(5_000_000e6, lenders[0]);
        for (uint256 i; i < 3; ++i) {
            vm.prank(borrowers[i]);
            market.depositCollateral(100e18, borrowers[i]);
        }
    }

    /// @dev Hostile / rare actions fire on about one call in `RARE` so the market spends most of its life usable.
    uint256 private constant RARE = 12;

    modifier rare(uint256 seed) {
        if (seed % RARE != 0) return;
        _;
    }

    function _actor(string memory label, uint256 i, bool loanFunded) private returns (address a) {
        a = makeAddr(string.concat(label, vm.toString(i)));
        stock.mint(a, 1_000_000e18);
        usdg.mint(a, loanFunded ? 100_000_000e6 : 1_000_000e6);
        vm.startPrank(a);
        stock.approve(address(market), type(uint256).max);
        usdg.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function lendersLength() external view returns (uint256) {
        return lenders.length;
    }

    function borrowersLength() external view returns (uint256) {
        return borrowers.length;
    }

    function liquidatorsLength() external view returns (uint256) {
        return liquidators.length;
    }

    // ---------------------------------------------------------------- helpers

    function _sharePrice() private view returns (uint256) {
        return market.convertToAssets(1e18);
    }

    function _post(uint256 priceBefore) private {
        ++calls["steps"];
        if (_halted()) ++calls["haltedSteps"];
        if (!_realized && _sharePrice() < priceBefore) ++vSharePrice;
        _realized = false;
        uint256 bad = market.badDebtRealized();
        if (bad < lastBadDebt) ++vBadDebtDecrease;
        lastBadDebt = bad;
    }

    function _halted() private view returns (bool) {
        return market.state() == MarketState.Halted;
    }

    function _capacity(address a) private view returns (uint256 cap) {
        (,, uint256 price) = _oracle();
        uint256 cv = uint256(market.positionOf(a).collateral) * price / 1e30;
        uint256 byGuard = cv * 0.75e18 / 1e18;
        uint256 byLltv = cv * 0.8e18 / 1e18;
        cap = byGuard < byLltv ? byGuard : byLltv;
    }

    function _oracle() private view returns (uint8 status, uint64 updatedAt, uint256 price) {
        (uint256 priceWad, uint64 upd,,, PriceStatus st) = oracle.data();
        return (uint8(st), upd, priceWad);
    }

    function _checkCapacity(address a) private {
        uint256 debt = market.debtOf(a);
        if (debt != 0 && debt > _capacity(a)) ++vCapacity;
    }

    // ---------------------------------------------------------------- lenders

    function lend(uint256 seed, uint256 amount) external {
        address a = lenders[seed % lenders.length];
        amount = bound(amount, 1e6, 300_000e6);
        uint256 p0 = _sharePrice();
        bool halted = _halted();
        vm.prank(a);
        try market.deposit(amount, a) {
            ++calls["lend"];
            if (halted) ++vHalt;
        } catch {}
        _post(p0);
    }

    function redeem(uint256 seed, uint256 pct) external {
        address a = lenders[seed % lenders.length];
        uint256 shares = market.balanceOf(a) * bound(pct, 1, 100) / 100;
        if (shares == 0) return;
        uint256 p0 = _sharePrice();
        vm.prank(a);
        try market.redeem(shares, a, a) {
            ++calls["redeem"];
        } catch {}
        _post(p0);
    }

    // ---------------------------------------------------------------- borrowers

    function depositCollateral(uint256 seed, uint256 amount) external {
        address a = borrowers[seed % borrowers.length];
        amount = bound(amount, 1e17, 60e18);
        uint256 p0 = _sharePrice();
        vm.prank(a);
        try market.depositCollateral(amount, a) {
            ++calls["depositCollateral"];
        } catch {}
        _post(p0);
    }

    function withdrawCollateral(uint256 seed, uint256 pct) external {
        address a = borrowers[seed % borrowers.length];
        uint256 amount = uint256(market.positionOf(a).collateral) * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        uint256 p0 = _sharePrice();
        bool halted = _halted();
        vm.prank(a);
        try market.withdrawCollateral(amount, a) {
            ++calls["withdrawCollateral"];
            if (halted) ++vHalt;
            _checkCapacity(a);
        } catch {}
        _post(p0);
    }

    function borrow(uint256 seed, uint256 amount) external {
        address a = borrowers[seed % borrowers.length];
        uint256 cap = _capacity(a);
        uint256 debt = market.debtOf(a);
        // bias toward leverage near the limit so liquidations and bad debt actually occur
        amount = cap > debt ? bound(amount, 1e6, cap - debt + 5e6) : bound(amount, 1e6, 5000e6);
        uint256 p0 = _sharePrice();
        bool halted = _halted();
        vm.prank(a);
        try market.borrow(amount, a) {
            ++calls["borrow"];
            if (halted) ++vHalt;
            _checkCapacity(a);
        } catch (bytes memory err) {
            ++calls[bytes32(bytes4(err))];
        }
        _post(p0);
    }

    /// @dev A full repay must succeed whenever the loan token is healthy, in EVERY market state and whatever the
    /// oracle says (repay never reads the oracle).
    function repayAll(uint256 seed, uint256 payerSeed) external {
        address target = borrowers[seed % borrowers.length];
        uint256 debt = market.debtOf(target);
        if (debt == 0) return;
        address payer = payerSeed % 2 == 0 ? target : liquidators[payerSeed % liquidators.length];
        if (usdg.balanceOf(payer) < debt) usdg.mint(payer, debt);
        bool healthy = !usdg.paused() && !usdg.isFrozen(address(market)) && !usdg.isFrozen(payer);
        uint256 p0 = _sharePrice();
        vm.prank(payer);
        try market.repay(debt, target) {
            ++calls["repayAll"];
        } catch {
            if (healthy) ++vRepay;
        }
        _post(p0);
    }

    // ---------------------------------------------------------------- liquidation and bad debt

    function liquidate(uint256 seed, uint256 liqSeed, uint256 amount) external {
        address target = borrowers[seed % borrowers.length];
        address liq = liquidators[liqSeed % liquidators.length];
        uint256 debt = market.debtOf(target);
        if (debt == 0) return;
        SundownMarket.Position memory pos = market.positionOf(target);
        if (pos.collateral == 0) return;
        // move the price so the target sits at a random loan-to-value in [0.78, 1.15] (includes insolvent)
        {
            uint256 ltv = bound(liqSeed, 0.78e18, 1.15e18);
            oracle.setPrice(debt * 1e30 * 1e18 / (uint256(pos.collateral) * ltv));
            oracle.setStatus(PriceStatus.Fresh);
        }
        (,, uint256 price) = _oracle();
        uint256 cv = uint256(pos.collateral) * price / 1e30;
        uint256 p0 = _sharePrice();
        amount = bound(amount, 1e6, debt + 1e6);
        vm.prank(liq);
        try market.liquidate(target, amount, liq) returns (uint256, uint256) {
            ++calls["liquidate"];
            uint256 debtAfter = market.debtOf(target);
            uint256 cvAfter = uint256(market.positionOf(target).collateral) * price / 1e30;
            // a solvent position (collateral value above debt) must not get worse: debt'/cv' <= debt/cv
            if (cv > debt) {
                uint256 slack = debt + cv + 2; // wei-level rounding
                if (debtAfter * cv > debt * cvAfter + slack) ++vLiquidation;
            }
        } catch {}
        _post(p0);
    }

    function realize(uint256 seed) external {
        address target = borrowers[seed % borrowers.length];
        uint256 p0 = _sharePrice();
        try market.realizeBadDebt(target) {
            ++calls["realize"];
            _realized = true;
        } catch {}
        _post(p0);
    }

    // ---------------------------------------------------------------- time, price, accrual

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 20 days));
        _post(0);
    }

    function accrueNow() external {
        uint256 before = market.totalBorrowAssets();
        bool halted = _halted();
        uint256 haltedAt = market.haltedAt();
        uint256 p0 = _sharePrice();
        market.accrue();
        if (halted && block.timestamp < haltedAt + 30 days && market.totalBorrowAssets() != before) ++vFrozen;
        _post(p0);
    }

    function setPrice(uint256 priceUsd) external {
        oracle.setPrice(bound(priceUsd, 20, 160) * 1e18);
        oracle.setStatus(PriceStatus.Fresh);
    }

    function setStatus(uint256 seed, uint256 s) external rare(seed) {
        oracle.setStatus(PriceStatus(bound(s, 0, 6)));
    }

    // ---------------------------------------------------------------- issuer, guardian, governance

    function stockPause(uint256 seed, bool on) external rare(seed) {
        stock.setTokenPaused(on);
    }

    function registryPause(uint256 seed, bool on) external rare(seed) {
        registry.setPaused(on);
    }

    function blockMarket(uint256 seed, bool on) external rare(seed) {
        registry.setBlocked(address(market), on);
    }

    function burnCollateral(uint256 seed, uint256 pct) external rare(seed) {
        uint256 bal = stock.balanceOf(address(market));
        uint256 amount = bal * bound(pct, 1, 50) / 100;
        if (amount == 0) return;
        stock.adminBurn(address(market), amount);
        ghostBurned += amount;
    }

    function usdgPause(uint256 seed, bool on) external rare(seed) {
        usdg.setPaused(on);
    }

    function freezeMarket(uint256 seed, bool on) external rare(seed) {
        usdg.setFrozen(address(market), on);
    }

    function report() external {
        try market.reportIssuerFailure() {
            ++calls["report"];
        } catch {}
    }

    function guardianHalt(uint256 seed) external rare(seed) {
        vm.prank(guardian);
        try market.guardianHalt() {
            ++calls["guardianHalt"];
        } catch {}
    }

    function resume(bool asGovernance) external {
        vm.prank(asGovernance ? governance : guardian);
        try market.resume() {
            ++calls["resume"];
        } catch {}
    }
}
