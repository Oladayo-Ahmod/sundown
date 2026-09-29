// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {SundownMarket} from "../../src/SundownMarket.sol";
import {SundownMarketFactory} from "../../src/SundownMarketFactory.sol";
import {SundownGuard} from "../../src/guards/SundownGuard.sol";
import {MarketParams} from "../../src/interfaces/ISundownMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEquityOracle} from "../mocks/MockEquityOracle.sol";
import {MockWindowCache} from "../mocks/MockWindowCache.sol";
import {GuardHandler} from "./GuardHandler.sol";

/// @dev Stateful invariants of a market protected by {SundownGuard} (docs/GUARD_DESIGN.md section 6, G1-G8).
contract GuardInvariantsTest is StdInvariant, Test {
    SundownMarket internal market;
    SundownGuard internal guard;
    GuardHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockERC20 stock = new MockERC20("Stock", "STK", 18);
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        MockEquityOracle oracle = new MockEquityOracle(100e18);
        oracle.setWindowId(7);
        MockWindowCache cache = new MockWindowCache();
        cache.set(false, 7, uint64(block.timestamp + 3 days), uint64(block.timestamp + 5 days), 0, 1);
        address governance = makeAddr("governance");
        address guardian = makeAddr("guardian");
        guard = new SundownGuard(
            SundownGuard.Params({
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
                preWindowHorizon: 6 hours,
                cureWindow: 3 hours
            }),
            address(oracle),
            address(cache),
            governance,
            guardian,
            address(this),
            2 days,
            18,
            6
        );
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
        guard.bindMarket(address(market));
        handler = new GuardHandler(market, guard, oracle, cache, stock, usd, governance, guardian);
        targetContract(address(handler));
    }

    function invariant_G1_noBorrowAboveTheStressCap() public view {
        assertEq(handler.vCap(), 0, "borrow/withdraw left debt above the expected cap (stress, tier, Stale)");
    }

    function invariant_G2_deleverageNeverWorsensNorTouchesStandard() public view {
        assertEq(handler.vDelev(), 0, "deleverage exceeded the required repay or raised the LTV");
        assertEq(handler.vStandard(), 0, "a standard account was deleveraged");
    }

    function invariant_G3_guardianCannotLoosen() public view {
        assertEq(handler.vGuardian(), 0, "guardian cleared a flag, changed parameters, or a blocked borrow succeeded");
    }

    function invariant_G4_boostedEntryGating() public view {
        assertEq(handler.vEntry(), 0, "entry outside stress/halt/price/fit gating, or exit above the standard cap");
    }

    function invariant_G5_repayNeverBlockable() public view {
        assertEq(handler.vRepay(), 0, "a full repay reverted");
    }

    function invariant_G6_noDeleverageWhenHaltedStaleOrOutsideTheZone() public view {
        assertEq(handler.vZone(), 0, "deleverage while halted, not Fresh, or outside the zone");
    }

    function invariant_G7_parametersWithinBoundsAndOnlyChangedByExecute() public view {
        (
            uint64 std,
            uint64 boost,
            uint64 gs,
            uint64 gw,
            uint64 gl,
            uint64 ob,
            uint64 sb,
            uint64 bonus,
            uint64 fee,
            uint64 margin,
            uint32 horizon,
            uint32 cure
        ) = guard.params();
        assertGe(std, guard.MIN_STANDARD_LLTV());
        assertLe(std, guard.MAX_STANDARD_LLTV());
        assertTrue(boost == 0 || (boost >= std && boost <= guard.MAX_BOOSTED_LLTV()));
        assertLe(boost, 0.93e18, "never above the market lltv");
        assertLe(gs, guard.MAX_GAP_VAR());
        assertLe(gw, guard.MAX_GAP_VAR());
        assertLe(gl, guard.MAX_GAP_VAR());
        assertGe(ob, guard.MIN_ORACLE_BUFFER());
        assertLe(ob, guard.MAX_ORACLE_BUFFER());
        assertLe(sb, guard.MAX_SAFETY_BUFFER());
        assertGe(bonus, guard.MIN_BONUS());
        assertLe(bonus, guard.MAX_BONUS());
        assertGe(fee, guard.MIN_DELEVERAGE_FEE());
        assertLe(fee, bonus);
        assertLe(margin, guard.MAX_DELEVERAGE_MARGIN());
        assertGe(horizon, guard.MIN_HORIZON());
        assertLe(horizon, guard.MAX_HORIZON());
        assertLe(uint256(cure) + guard.MIN_DELEVERAGE_INTERVAL(), horizon);
        assertEq(
            keccak256(abi.encode(guard.currentParams())), handler.ghostParamsHash(), "changed outside executeParams"
        );
        assertEq(handler.vTimelock(), 0, "executed before eta or a non-queued proposal");
    }

    function invariant_G8_deleveragedEventIffPredicate() public view {
        assertEq(handler.vEvents(), 0, "Deleveraged emitted for an ordinary liquidation or missing for a deleverage");
    }

    function afterInvariant() public {
        emit log_named_uint("enter", handler.calls("enter"));
        emit log_named_uint("exit", handler.calls("exit"));
        emit log_named_uint("borrow", handler.calls("borrow"));
        emit log_named_uint("squeezeBorrow", handler.calls("squeezeBorrow"));
        emit log_named_uint("withdraw", handler.calls("withdraw"));
        emit log_named_uint("repay", handler.calls("repay"));
        emit log_named_uint("liquidate (all)", handler.calls("liquidate"));
        emit log_named_uint("deleverage (healthy pre-state)", handler.calls("deleverage"));
        emit log_named_uint("guardian", handler.calls("guardian"));
        emit log_named_uint("queue", handler.calls("queue"));
        emit log_named_uint("execute", handler.calls("execute"));
    }
}
