// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {FlatGuard} from "../src/guards/FlatGuard.sol";
import {HaltReason, ISundownMarket, MarketParams, MarketState} from "../src/interfaces/ISundownMarket.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";
import {
    MockIssuerRegistry,
    MockStockIssuerToken,
    MockUsdgToken,
    MockBrickableToken,
    MockGuzzlerToken,
    MockNoReturnToken,
    MockReturnsFalseToken,
    MockReentrantToken
} from "./mocks/IssuerMocks.sol";

/// @dev Issuer-control policy (decisions D2, D13, D14): probes, halt semantics, resume rules, shortfall, and
/// hostile tokens. Collateral is a Robinhood-style stock token, the loan token a USDG-style token.
contract IssuerFailureTest is Test {
    MockIssuerRegistry internal registry;
    MockStockIssuerToken internal stock;
    MockUsdgToken internal usdg;
    MockEquityOracle internal oracle;
    FlatGuard internal guard;
    SundownMarketFactory internal factory;
    SundownMarket internal market;

    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function _params(address collateral, address loan) internal view returns (MarketParams memory) {
        return MarketParams({
            collateralToken: collateral,
            loanToken: loan,
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
            shareName: "Sundown",
            shareSymbol: "sd"
        });
    }

    function _create(address collateral, address loan, string memory symbol) internal returns (SundownMarket m) {
        MarketParams memory p = _params(collateral, loan);
        p.shareSymbol = symbol;
        vm.prank(governance);
        m = SundownMarket(factory.createMarket(p));
    }

    function setUp() public virtual {
        registry = new MockIssuerRegistry();
        stock = new MockStockIssuerToken(registry);
        usdg = new MockUsdgToken();
        oracle = new MockEquityOracle(100e18);
        guard = new FlatGuard(0.75e18, 0.04e18);
        factory = new SundownMarketFactory(address(new SundownMarket()), governance);
        market = _create(address(stock), address(usdg), "sdSTK");
        _fund(market, stock, usdg);
    }

    function _fund(SundownMarket m, MockStockIssuerToken c, MockUsdgToken l) internal {
        c.mint(borrower, 1000e18);
        l.mint(lender, 1_000_000e6);
        l.mint(liquidator, 1_000_000e6);
        l.mint(borrower, 100_000e6);
        vm.prank(lender);
        l.approve(address(m), type(uint256).max);
        vm.prank(liquidator);
        l.approve(address(m), type(uint256).max);
        vm.startPrank(borrower);
        l.approve(address(m), type(uint256).max);
        c.approve(address(m), type(uint256).max);
        vm.stopPrank();
    }

    function _position(uint256 collateral, uint256 debt) internal {
        vm.prank(lender);
        market.deposit(100_000e6, lender);
        vm.startPrank(borrower);
        market.depositCollateral(collateral, borrower);
        market.borrow(debt, borrower);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- detection

    function test_healthyTokensPass() public {
        _position(100e18, 5000e6);
        vm.recordLogs();
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.None));
        Vm.Log[] memory logs = vm.getRecordedLogs(); // the tokens emit Transfer logs for the self-transfer probes
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(market), "the market emits nothing when healthy");
        }
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_collateralTokenPauseHalts() public {
        _position(100e18, 5000e6);
        stock.setTokenPaused(true);
        vm.expectEmit(true, true, false, true, address(market));
        emit ISundownMarket.MarketHalted(HaltReason.CollateralPaused, address(this));
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralPaused));
        assertEq(uint8(market.state()), uint8(MarketState.Halted));
        assertEq(market.haltedAt(), block.timestamp);
        // idempotent: a second report returns the existing reason
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralPaused));
    }

    function test_registryWidePauseHalts() public {
        _position(100e18, 5000e6);
        registry.setPaused(true); // one registry call freezes every stock token
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralPaused));
    }

    function test_blockedMarketHalts() public {
        _position(100e18, 5000e6);
        registry.setBlocked(address(market), true);
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralBlocked));
    }

    function test_loanTokenPauseAndFreezeHalt() public {
        _position(100e18, 5000e6);
        usdg.setPaused(true);
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.LoanPaused));
        vm.prank(governance);
        market.resume();
        usdg.setPaused(false);
        usdg.setFrozen(address(market), true);
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.LoanFrozen));
    }

    function test_selfTransferProbeCatchesFailuresWithoutFlags() public {
        MockBrickableToken brick = new MockBrickableToken(18);
        MockBrickableToken loan = new MockBrickableToken(6);
        SundownMarket m = _create(address(brick), address(loan), "sdBRK");
        brick.mint(borrower, 100e18);
        vm.startPrank(borrower);
        brick.approve(address(m), type(uint256).max);
        m.depositCollateral(10e18, borrower);
        vm.stopPrank();
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.None));
        brick.setBricked(true); // no paused(), no registry: only the 1-wei self-transfer reveals it
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.ProbeFailure));
    }

    function test_loanSelfTransferProbe() public {
        MockBrickableToken loan = new MockBrickableToken(6);
        MockStockIssuerToken col = new MockStockIssuerToken(registry);
        SundownMarket m = _create(address(col), address(loan), "sdLOAN");
        loan.mint(lender, 1000e6);
        vm.startPrank(lender);
        loan.approve(address(m), type(uint256).max);
        m.deposit(1000e6, lender);
        vm.stopPrank();
        loan.setBricked(true);
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.ProbeFailure));
    }

    function test_emptyMarketIsNotFlaggedByTheTransferProbe() public {
        // no collateral and no idle assets: nothing to probe with, tokens healthy
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.None));
    }

    function test_insufficientGasRevertsInsteadOfFalsePositive() public {
        _position(100e18, 5000e6);
        vm.expectRevert(ISundownMarket.InsufficientGas.selector);
        market.reportIssuerFailure{gas: 500_000}();
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_gasGuzzlingTokenBecomesAProbeFailureNotABrick() public {
        MockGuzzlerToken guzzler = new MockGuzzlerToken();
        MockStockIssuerToken col = new MockStockIssuerToken(registry);
        // the guzzler is the LOAN token: its `transfer` burns all gas once armed
        SundownMarket m = _create(address(col), address(guzzler), "sdGZL");
        guzzler.mint(lender, 1000e6);
        vm.startPrank(lender);
        guzzler.approve(address(m), type(uint256).max);
        m.deposit(1000e6, lender);
        vm.stopPrank();
        guzzler.setGuzzle(true);
        uint256 g = gasleft();
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.ProbeFailure));
        assertLt(g - gasleft(), 1_000_000, "the probe's gas cap bounded the damage");
    }

    // ---------------------------------------------------------------- collateral shortfall (adminBurn), D13

    function test_adminBurnShortfallHaltsAndBlocksExitsButNotRepay() public {
        _position(100e18, 5000e6);
        stock.adminBurn(address(market), 40e18); // the issuer burns collateral held by the market
        assertEq(stock.balanceOf(address(market)), 60e18);
        assertEq(market.totalCollateral(), 100e18, "ledger now holds phantom collateral");
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralShortfall));

        // halted: no new borrows, no collateral withdrawals, no supply
        vm.startPrank(borrower);
        vm.expectRevert(ISundownMarket.NotActive.selector);
        market.borrow(100e6, borrower);
        vm.expectRevert(ISundownMarket.NotActive.selector);
        market.withdrawCollateral(1e18, borrower);
        vm.stopPrank();
        vm.prank(lender);
        vm.expectRevert();
        market.deposit(1e6, lender);
        // repay stays open
        vm.prank(borrower);
        market.repay(1000e6, borrower);
        assertEq(market.debtOf(borrower), 4000e6);
        // lenders can still exit idle liquidity
        vm.prank(lender);
        market.withdraw(1000e6, lender, lender);

        // the guardian cannot resume while the shortfall persists; governance can (an explicit override)
        vm.prank(guardian);
        vm.expectRevert(ISundownMarket.ProbesFailing.selector);
        market.resume();
        stock.mint(address(market), 40e18); // balance restored (e.g. a donation): the shortfall is resolved
        vm.prank(guardian);
        market.resume();
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_phantomCollateralRaceIsTheDocumentedResidualRisk() public {
        // Two borrowers each hold 50 tokens of credited collateral; the issuer burns half of the real balance.
        _position(50e18, 2000e6);
        address other = makeAddr("other");
        stock.mint(other, 50e18);
        vm.startPrank(other);
        stock.approve(address(market), type(uint256).max);
        market.depositCollateral(50e18, other);
        vm.stopPrank();
        stock.adminBurn(address(market), 50e18); // 50 real tokens remain for 100 credited
        market.reportIssuerFailure();
        assertEq(uint8(market.haltReason()), uint8(HaltReason.CollateralShortfall));
        // Resume (governance override) and exit: first come, first served; the second claimant is left with a
        // phantom claim. No mechanism resolves this in v1 (D13); the loss is bounded only by the collateral cap.
        vm.prank(governance);
        market.resume();
        usdg.mint(borrower, 10_000e6);
        vm.startPrank(borrower);
        market.repay(type(uint256).max, borrower);
        market.withdrawCollateral(50e18, borrower);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(); // nothing left to pay out
        market.withdrawCollateral(50e18, other);
        assertEq(market.collateralOf(other), 50e18, "phantom claim remains on the ledger");
    }

    // ---------------------------------------------------------------- resume rules and the freeze limit

    function test_guardianResumeNeedsHealthyTokensGovernanceDoesNot() public {
        _position(100e18, 5000e6);
        stock.setTokenPaused(true);
        market.reportIssuerFailure();
        vm.prank(guardian);
        vm.expectRevert(ISundownMarket.ProbesFailing.selector);
        market.resume();
        vm.prank(governance);
        market.resume(); // unconditional
        assertEq(uint8(market.state()), uint8(MarketState.Active));
        // and the failure is detected again
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralPaused));
    }

    function test_guardianHaltClearsOnceTokensAreHealthy() public {
        _position(100e18, 5000e6);
        vm.prank(guardian);
        market.guardianHalt();
        vm.prank(guardian);
        market.resume(); // tokens healthy: probes pass
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_liquidationOnlyRevertsWhileTheTokenReverts() public {
        _position(100e18, 7400e6);
        oracle.setPrice(60e18);
        stock.setTokenPaused(true);
        market.reportIssuerFailure();
        vm.prank(liquidator);
        vm.expectRevert(bytes("IsPaused")); // no halt gate: the collateral transfer itself reverts
        market.liquidate(borrower, 1000e6, liquidator);
        stock.setTokenPaused(false);
        vm.prank(liquidator);
        market.liquidate(borrower, 1000e6, liquidator); // works again while the market is still Halted
        assertEq(uint8(market.state()), uint8(MarketState.Halted));
    }

    function test_accrualFreezeAndResumeAfterThirtyDaysForTokenFailures() public {
        _position(100e18, 7400e6);
        stock.setTokenPaused(true);
        market.reportIssuerFailure();
        uint256 debt0 = market.totalBorrowAssets();
        vm.warp(block.timestamp + 29 days);
        market.accrue();
        assertEq(market.totalBorrowAssets(), debt0);
        vm.warp(block.timestamp + 5 days);
        market.accrue();
        assertGt(market.totalBorrowAssets(), debt0, "accrual resumes by itself from day 30");
    }

    // ---------------------------------------------------------------- odd and hostile tokens

    function test_noReturnTokenWorksAndProbePasses() public {
        MockNoReturnToken nr = new MockNoReturnToken();
        MockStockIssuerToken col = new MockStockIssuerToken(registry);
        SundownMarket m = _create(address(col), address(nr), "sdNR");
        nr.mint(lender, 100_000e6);
        col.mint(borrower, 100e18);
        vm.prank(lender);
        nr.approve(address(m), type(uint256).max);
        vm.prank(lender);
        m.deposit(100_000e6, lender);
        vm.startPrank(borrower);
        col.approve(address(m), type(uint256).max);
        m.depositCollateral(100e18, borrower);
        m.borrow(5000e6, borrower);
        nr.approve(address(m), type(uint256).max);
        vm.stopPrank();
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.None), "empty return data is a passing probe");
        vm.prank(borrower);
        m.repay(5000e6, borrower);
        assertEq(m.debtOf(borrower), 0);
    }

    function test_returnsFalseTokenIsAProbeFailureAndSafeErc20Reverts() public {
        MockReturnsFalseToken f = new MockReturnsFalseToken();
        MockStockIssuerToken col = new MockStockIssuerToken(registry);
        SundownMarket m = _create(address(col), address(f), "sdFALSE");
        f.mint(lender, 1000e6);
        vm.startPrank(lender);
        f.approve(address(m), type(uint256).max);
        m.deposit(1000e6, lender);
        vm.stopPrank();
        f.setFailing(true);
        assertEq(uint8(m.reportIssuerFailure()), uint8(HaltReason.ProbeFailure));
        vm.prank(lender);
        vm.expectRevert(); // SafeERC20 refuses a false return
        m.withdraw(100e6, lender, lender);
    }

    function _reentry(bytes memory callData, bool asLoan) internal returns (uint256 attempts, uint256 successes) {
        MockReentrantToken rt = new MockReentrantToken(asLoan ? 6 : 18);
        MockStockIssuerToken stk = new MockStockIssuerToken(registry);
        MockUsdgToken usd = new MockUsdgToken();
        SundownMarket m = asLoan
            ? _create(address(stk), address(rt), string.concat("rl", vm.toString(callData.length)))
            : _create(address(rt), address(usd), string.concat("rc", vm.toString(callData.length)));
        rt.mint(lender, 1_000_000e6);
        rt.mint(borrower, 1_000_000e18);
        usd.mint(lender, 1_000_000e6);
        stk.mint(borrower, 1000e18);
        vm.startPrank(lender);
        rt.approve(address(m), type(uint256).max);
        usd.approve(address(m), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(borrower);
        rt.approve(address(m), type(uint256).max);
        stk.approve(address(m), type(uint256).max);
        vm.stopPrank();
        rt.arm(address(m), callData);
        vm.prank(asLoan ? lender : borrower);
        if (asLoan) m.deposit(1000e6, lender);
        else m.depositCollateral(10e18, borrower);
        return (rt.attempts(), rt.successes());
    }

    function test_reentrancyFromTokenCallbacksIsBlocked() public {
        // a token that calls back into the market during its own transfer cannot re-enter any guarded function
        bytes[5] memory calls = [
            abi.encodeCall(ISundownMarket.accrue, ()),
            abi.encodeCall(ISundownMarket.depositCollateral, (1e18, borrower)),
            abi.encodeCall(ISundownMarket.repay, (1e6, borrower)),
            abi.encodeCall(ISundownMarket.guardianHalt, ()),
            abi.encodeCall(ISundownMarket.reportIssuerFailure, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (uint256 attempts, uint256 successes) = _reentry(calls[i], false);
            assertGt(attempts, 0, "the token did try to re-enter");
            assertEq(successes, 0, "every re-entrant call was rejected");
            (attempts, successes) = _reentry(calls[i], true);
            assertGt(attempts, 0);
            assertEq(successes, 0);
        }
    }
}
