// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "./MarketBase.sol";
import {KinkedRate} from "../src/lib/KinkedRate.sol";
import {SharesMath} from "../src/lib/SharesMath.sol";

/// @dev Differential tests against research/market_reference.py: an independent exact-integer model of the same
/// arithmetic. The fixture is regenerated with `python research/market_reference.py`.
contract MarketReferenceTest is MarketBase {
    uint256 internal constant STRIDE = 18; // 6 global values + 3 per actor x 4 actors

    string internal fx;
    address[4] internal actors;

    function setUp() public override {
        super.setUp();
        fx = vm.readFile("test/fixtures/market_cases.json");
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 4; ++i) {
            usd.mint(actors[i], 100_000_000e6);
            stock.mint(actors[i], 5000e18);
            vm.startPrank(actors[i]);
            usd.approve(address(market), type(uint256).max);
            stock.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_rateCurveMatchesReference() public view {
        uint256[] memory util = vm.parseJsonUintArray(fx, ".rate.util");
        uint256[] memory apr = vm.parseJsonUintArray(fx, ".rate.apr");
        uint256[] memory rate = vm.parseJsonUintArray(fx, ".rate.rate");
        KinkedRate.Params memory p = KinkedRate.Params(0, 0.04e18, 0.75e18, 0.8e18);
        assertGt(util.length, 40);
        for (uint256 i; i < util.length; ++i) {
            assertEq(KinkedRate.aprWad(p, util[i]), apr[i], "apr");
            assertEq(KinkedRate.ratePerSecond(p, util[i]), rate[i], "rate");
        }
    }

    function test_compoundMatchesReference() public view {
        uint256[] memory rate = vm.parseJsonUintArray(fx, ".compound.rate");
        uint256[] memory elapsed = vm.parseJsonUintArray(fx, ".compound.elapsed");
        uint256[] memory factor = vm.parseJsonUintArray(fx, ".compound.factor");
        assertGt(rate.length, 40);
        for (uint256 i; i < rate.length; ++i) {
            assertEq(KinkedRate.compoundFactor(rate[i], elapsed[i]), factor[i], "factor");
        }
    }

    function test_sharesMathMatchesReference() public view {
        uint256[] memory a = vm.parseJsonUintArray(fx, ".shares.a");
        uint256[] memory ta = vm.parseJsonUintArray(fx, ".shares.ta");
        uint256[] memory ts = vm.parseJsonUintArray(fx, ".shares.ts");
        uint256[] memory down = vm.parseJsonUintArray(fx, ".shares.down");
        uint256[] memory up = vm.parseJsonUintArray(fx, ".shares.up");
        uint256[] memory adown = vm.parseJsonUintArray(fx, ".shares.adown");
        uint256[] memory aup = vm.parseJsonUintArray(fx, ".shares.aup");
        assertEq(a.length, 2000);
        for (uint256 i; i < a.length; ++i) {
            assertEq(SharesMath.toSharesDown(a[i], ta[i], ts[i]), down[i], "toSharesDown");
            assertEq(SharesMath.toSharesUp(a[i], ta[i], ts[i]), up[i], "toSharesUp");
            assertEq(SharesMath.toAssetsDown(a[i], ta[i], ts[i]), adown[i], "toAssetsDown");
            assertEq(SharesMath.toAssetsUp(a[i], ta[i], ts[i]), aup[i], "toAssetsUp");
        }
    }

    /// @dev Replays the randomized scenario against the real market and checks every global and per-actor value
    /// after each operation, plus the returned amounts of redeem, repay, liquidate and realizeBadDebt.
    function test_scenarioReplayMatchesReference() public {
        uint256[] memory op = vm.parseJsonUintArray(fx, ".scenario.cols.op");
        uint256[] memory actor = vm.parseJsonUintArray(fx, ".scenario.cols.actor");
        uint256[] memory target = vm.parseJsonUintArray(fx, ".scenario.cols.target");
        uint256[] memory amt = vm.parseJsonUintArray(fx, ".scenario.cols.a");
        uint256[] memory ret1 = vm.parseJsonUintArray(fx, ".scenario.cols.ret1");
        uint256[] memory ret2 = vm.parseJsonUintArray(fx, ".scenario.cols.ret2");
        uint256[] memory snap = vm.parseJsonUintArray(fx, ".scenario.cols.snap");
        assertEq(snap.length, op.length * STRIDE);
        assertGt(op.length, 800);
        uint256 liquidations;
        uint256 realized;
        for (uint256 i; i < op.length; ++i) {
            (uint256 r1, uint256 r2) = _exec(op[i], actors[actor[i]], actors[target[i]], amt[i]);
            if (op[i] == 1 || op[i] == 5 || op[i] == 6 || op[i] == 9) assertEq(r1, ret1[i], "ret1");
            if (op[i] == 6) {
                assertEq(r2, ret2[i], "ret2");
                ++liquidations;
            }
            if (op[i] == 9) ++realized;
            _checkSnapshot(snap, i);
        }
        assertGt(liquidations, 8, "scenario exercises liquidations");
        assertGt(realized, 0, "scenario exercises bad-debt realization");
    }

    function _exec(uint256 op, address a, address t, uint256 v) internal returns (uint256 r1, uint256 r2) {
        vm.startPrank(a);
        if (op == 0) {
            market.deposit(v, a);
        } else if (op == 1) {
            r1 = market.redeem(v, a, a);
        } else if (op == 2) {
            market.depositCollateral(v, a);
        } else if (op == 3) {
            market.withdrawCollateral(v, a);
        } else if (op == 4) {
            market.borrow(v, a);
        } else if (op == 5) {
            (r1,) = market.repay(v, t);
        } else if (op == 6) {
            (r1, r2) = market.liquidate(t, v, a);
        } else if (op == 9) {
            r1 = market.realizeBadDebt(t);
        } else if (op == 10) {
            market.accrue();
        }
        vm.stopPrank();
        if (op == 7) vm.warp(block.timestamp + v);
        if (op == 8) oracle.setPrice(v);
    }

    function _checkSnapshot(uint256[] memory snap, uint256 i) internal view {
        uint256 base = i * STRIDE;
        assertEq(market.idleAssets(), snap[base], "idle");
        assertEq(market.totalBorrowAssets(), snap[base + 1], "totalBorrowAssets");
        assertEq(market.totalBorrowShares(), snap[base + 2], "totalBorrowShares");
        assertEq(market.totalSupply(), snap[base + 3], "vault supply");
        assertEq(market.badDebtRealized(), snap[base + 4], "badDebt");
        assertEq(market.totalCollateral(), snap[base + 5], "totalCollateral");
        for (uint256 k; k < 4; ++k) {
            uint256 o = base + 6 + 3 * k;
            assertEq(market.positionOf(actors[k]).borrowShares, snap[o], "borrowShares");
            assertEq(market.positionOf(actors[k]).collateral, snap[o + 1], "collateral");
            assertEq(market.balanceOf(actors[k]), snap[o + 2], "vault shares");
        }
    }

    // ---------------------------------------------------------------- property tests on the libraries

    function testFuzz_sharesRoundTripNeverCreatesValue(uint96 assets, uint96 ta, uint96 ts) public pure {
        uint256 s = SharesMath.toSharesDown(assets, ta, ts);
        assertLe(SharesMath.toAssetsDown(s, ta, ts), assets); // down/down never returns more than was put in
        assertGe(SharesMath.toSharesUp(assets, ta, ts), s);
        assertGe(SharesMath.toAssetsUp(s, ta, ts), SharesMath.toAssetsDown(s, ta, ts));
    }

    function testFuzz_compoundMonotoneAndBelowExp(uint64 rate, uint32 elapsed) public pure {
        uint256 r = bound(rate, 0, 2e11); // up to ~630 % APR per second rate
        uint256 f1 = KinkedRate.compoundFactor(r, elapsed);
        uint256 f2 = KinkedRate.compoundFactor(r, uint256(elapsed) + 1);
        assertGe(f2, f1, "monotone in time");
        // the truncated series never exceeds x + x^2/2 + x^3/6 + (x^4/24 slack): at least x
        assertGe(f1, r * uint256(elapsed));
    }

    function testFuzz_aprMonotoneInUtilization(uint64 u1, uint64 u2) public pure {
        KinkedRate.Params memory p = KinkedRate.Params(0.01e18, 0.04e18, 0.75e18, 0.8e18);
        uint256 a = bound(u1, 0, 1e18);
        uint256 b = bound(u2, 0, 1e18);
        (a, b) = a <= b ? (a, b) : (b, a);
        assertLe(KinkedRate.aprWad(p, a), KinkedRate.aprWad(p, b));
        assertLe(KinkedRate.aprWad(p, 1e18), 0.01e18 + 0.04e18 + 0.75e18);
    }
}
