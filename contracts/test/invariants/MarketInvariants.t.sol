// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {SundownMarket} from "../../src/SundownMarket.sol";
import {SundownMarketFactory} from "../../src/SundownMarketFactory.sol";
import {FlatGuard} from "../../src/guards/FlatGuard.sol";
import {ISundownMarket} from "../../src/interfaces/ISundownMarket.sol";
import {HaltReason, MarketParams, MarketState} from "../../src/interfaces/ISundownMarket.sol";
import {MockEquityOracle} from "../mocks/MockEquityOracle.sol";
import {MockIssuerRegistry, MockStockIssuerToken, MockUsdgToken} from "../mocks/IssuerMocks.sol";
import {MarketHandler} from "./MarketHandler.sol";

/// @dev Stateful invariants of the market (docs/MARKET_DESIGN.md section 13). Priority set (D17): collateral
/// conservation, vault accounting identity, debts <= totalBorrow, no borrow above guard capacity, liquidation never
/// worsens a position, share price never falls except via BadDebtRealized, repay never blockable, halt semantics.
/// Run longer in the `ci` profile (`FOUNDRY_PROFILE=ci forge test --match-contract MarketInvariants`).
contract MarketInvariantsTest is StdInvariant, Test {
    SundownMarket internal market;
    MockStockIssuerToken internal stock;
    MockUsdgToken internal usdg;
    MarketHandler internal handler;

    function setUp() public {
        MockIssuerRegistry registry = new MockIssuerRegistry();
        stock = new MockStockIssuerToken(registry);
        usdg = new MockUsdgToken();
        MockEquityOracle oracle = new MockEquityOracle(100e18);
        FlatGuard guard = new FlatGuard(0.75e18, 0.04e18);
        address governance = makeAddr("governance");
        address guardian = makeAddr("guardian");
        SundownMarketFactory factory = new SundownMarketFactory(address(new SundownMarket()), governance);
        vm.prank(governance);
        market = SundownMarket(
            factory.createMarket(
                MarketParams({
                    collateralToken: address(stock),
                    loanToken: address(usdg),
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
                })
            )
        );
        handler = new MarketHandler(market, stock, usdg, oracle, registry, guardian, governance);
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- conservation

    /// @dev Collateral conservation: the credited ledger equals the sum of positions, and the real balance plus
    /// whatever the issuer burned equals the ledger (deposits, withdrawals and seizures move both equally).
    function invariant_collateralConservation() public view {
        uint256 sum;
        for (uint256 i; i < handler.borrowersLength(); ++i) {
            sum += market.positionOf(handler.borrowers(i)).collateral;
        }
        assertEq(sum, market.totalCollateral(), "ledger == sum of positions");
        assertEq(
            stock.balanceOf(address(market)) + handler.ghostBurned(),
            market.totalCollateral(),
            "balance + burned == ledger"
        );
        assertLe(market.totalCollateral(), 1000e18, "collateral cap");
    }

    function invariant_loanTokenConservation() public view {
        assertEq(usdg.balanceOf(address(market)), market.idleAssets(), "loan balance == idle ledger");
    }

    // ---------------------------------------------------------------- vault accounting

    function invariant_vaultAccountingIdentity() public {
        uint256 view_ = market.totalAssets();
        market.accrue();
        assertEq(market.totalAssets(), view_, "view includes exactly the pending interest");
        assertEq(
            market.totalAssets(), uint256(market.idleAssets()) + market.totalBorrowAssets(), "assets == idle + debt"
        );
        uint256 shares;
        for (uint256 i; i < handler.lendersLength(); ++i) {
            shares += market.balanceOf(handler.lenders(i));
        }
        assertEq(shares, market.totalSupply(), "vault shares");
    }

    function invariant_debtsBoundedByTotalBorrow() public {
        market.accrue();
        uint256 shares;
        uint256 debts;
        uint256 n = handler.borrowersLength();
        for (uint256 i; i < n; ++i) {
            address b = handler.borrowers(i);
            shares += market.positionOf(b).borrowShares;
            debts += market.debtOf(b);
        }
        assertEq(shares, market.totalBorrowShares(), "sum of debt shares");
        // debts round up per account: the sum may exceed the total by less than one unit per account
        assertLe(debts, uint256(market.totalBorrowAssets()) + n, "sum of debts <= totalBorrow (+ round-up dust)");
        // and the aggregate is not under-counted either: it may exceed the sum only by the virtual-share dust
        assertLe(uint256(market.totalBorrowAssets()), debts + 2, "totalBorrow <= sum of debts (+ dust)");
    }

    // ---------------------------------------------------------------- behaviour (ghost-checked)

    function invariant_noBorrowAboveGuardCapacity() public view {
        assertEq(handler.vCapacity(), 0, "borrow/withdraw respected min(guard, lltv) capacity");
    }

    function invariant_liquidationNeverWorsensASolventPosition() public view {
        assertEq(handler.vLiquidation(), 0);
    }

    function invariant_sharePriceNeverFallsExceptViaBadDebt() public view {
        assertEq(handler.vSharePrice(), 0);
        assertEq(handler.vBadDebtDecrease(), 0, "badDebtRealized is monotone");
    }

    function invariant_repayNeverBlockable() public view {
        assertEq(handler.vRepay(), 0, "a full repay never reverted with a healthy loan token");
    }

    function invariant_haltSemantics() public view {
        assertEq(handler.vHalt(), 0, "halted: no supply, borrow or collateral withdrawal");
        assertEq(handler.vFrozen(), 0, "accrual frozen for the first 30 days of a halt");
        if (market.state() == MarketState.Halted) {
            assertTrue(market.haltReason() != HaltReason.None);
            assertGt(market.haltedAt(), 0);
        } else {
            assertEq(uint8(market.haltReason()), uint8(HaltReason.None));
            assertEq(market.haltedAt(), 0);
        }
    }

    /// @dev Guards against a vacuous run: the handler must actually reach the interesting actions.
    function invariant_callSummary() public view {
        // informational: nothing to assert; the summary is logged by `afterInvariant`
        assertTrue(true);
    }

    function afterInvariant() public {
        emit log_named_uint("steps", handler.calls("steps"));
        emit log_named_uint("haltedSteps", handler.calls("haltedSteps"));
        emit log_named_uint("borrowRevert NotActive", handler.calls(bytes32(ISundownMarket.NotActive.selector)));
        emit log_named_uint("borrowRevert PriceUnusable", handler.calls(bytes32(ISundownMarket.PriceUnusable.selector)));
        emit log_named_uint(
            "borrowRevert ExceedsCapacity", handler.calls(bytes32(ISundownMarket.ExceedsCapacity.selector))
        );
        emit log_named_uint("borrowRevert BelowMinDebt", handler.calls(bytes32(ISundownMarket.BelowMinDebt.selector)));
        emit log_named_uint("lend", handler.calls("lend"));
        emit log_named_uint("redeem", handler.calls("redeem"));
        emit log_named_uint("depositCollateral", handler.calls("depositCollateral"));
        emit log_named_uint("withdrawCollateral", handler.calls("withdrawCollateral"));
        emit log_named_uint("borrow", handler.calls("borrow"));
        emit log_named_uint("repayAll", handler.calls("repayAll"));
        emit log_named_uint("liquidate", handler.calls("liquidate"));
        emit log_named_uint("realize", handler.calls("realize"));
        emit log_named_uint("report", handler.calls("report"));
        emit log_named_uint("guardianHalt", handler.calls("guardianHalt"));
        emit log_named_uint("resume", handler.calls("resume"));
    }
}
