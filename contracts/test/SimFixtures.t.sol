// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SimIssuerRegistry, SimStock, SimUSDG} from "sim/SimTokens.sol";
import {SimEquityFeed} from "sim/SimEquityFeed.sol";
import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {FlatGuard} from "../src/guards/FlatGuard.sol";
import {ChainlinkEquityOracle} from "../src/oracle/ChainlinkEquityOracle.sol";
import {HaltReason, ISundownMarket, MarketParams, MarketState} from "../src/interfaces/ISundownMarket.sol";
import {PriceStatus} from "../src/interfaces/IEquityOracle.sol";
import {MockWindowCache} from "./mocks/MockWindowCache.sol";

/// @dev The Sepolia simulation fixtures behave like the issuer surface the market and the oracle probe, and the
/// halt demo on them is real market code.
contract SimFixturesTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardianA = makeAddr("guardianA");

    SimIssuerRegistry internal registry;
    SimStock internal stock;
    SimUSDG internal usdg;
    SimEquityFeed internal feed;
    MockWindowCache internal cache;
    ChainlinkEquityOracle internal oracle;
    SundownMarket internal market;

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = new SimIssuerRegistry(owner);
        stock = new SimStock("SIM Apple (simulation)", "sAAPL", registry, owner, 50e18);
        usdg = new SimUSDG(owner, 100_000e6);
        feed = new SimEquityFeed(owner, "SIM AAPL / USD (simulation)", 333e8);
        cache = new MockWindowCache();
        cache.set(false, 1, uint64(block.timestamp + 3 days), uint64(block.timestamp + 5 days), 0, 1);
        oracle = new ChainlinkEquityOracle(
            ChainlinkEquityOracle.Config({
                feed: address(feed),
                collateralToken: address(stock),
                windowCache: address(cache),
                sequencerFeed: address(0),
                sequencerGrace: 0,
                maxAge: 25 hours,
                freeAge: 1 hours,
                corporateActionHorizon: 1 days,
                deviationWad: 0.005e18,
                ageHaircutWadPerHour: 0.002e18,
                maxAgeHaircutWad: 0.05e18,
                minPriceWad: 1e18,
                maxPriceWad: 1_000_000e18
            })
        );
        SundownMarketFactory factory = new SundownMarketFactory(address(new SundownMarket()), owner);
        address flat = address(new FlatGuard(0.86e18, 0.04e18));
        vm.prank(owner);
        market = SundownMarket(
            factory.createMarket(
                MarketParams({
                    collateralToken: address(stock),
                    loanToken: address(usdg),
                    oracle: address(oracle),
                    guard: flat,
                    guardian: guardianA,
                    governance: owner,
                    lltvWad: 0.86e18,
                    closeFactorWad: 0.5e18,
                    criticalHealthWad: 0.95e18,
                    maxBonusWad: 0.055e18,
                    collateralCap: 30e18,
                    minDebt: 10e6,
                    baseAprWad: 0,
                    slope1AprWad: 0.04e18,
                    slope2AprWad: 0.75e18,
                    kinkWad: 0.8e18,
                    shareName: "Sundown sAAPL/sUSDG (simulation)",
                    shareSymbol: "sdsAAPL"
                })
            )
        );
    }

    function _fund() internal {
        vm.startPrank(alice);
        usdg.faucet(50_000e6);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(50_000e6, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        stock.faucet(30e18);
        stock.approve(address(market), type(uint256).max);
        usdg.approve(address(market), type(uint256).max);
        market.depositCollateral(30e18, bob);
        market.borrow(5000e6, bob);
        vm.stopPrank();
    }

    function test_faucetsHaveACumulativePerAddressLimit() public {
        vm.startPrank(alice);
        stock.faucet(30e18);
        stock.faucet(20e18);
        vm.expectRevert(abi.encodeWithSelector(SimStock.FaucetLimit.selector, 50e18, 1, 50e18));
        stock.faucet(1);
        usdg.faucet(100_000e6);
        vm.expectRevert(abi.encodeWithSelector(SimUSDG.FaucetLimit.selector, 100_000e6, 1, 100_000e6));
        usdg.faucet(1);
        vm.stopPrank();
        assertEq(stock.balanceOf(alice), 50e18);
        assertEq(usdg.decimals(), 6);
        assertEq(stock.decimals(), 18);
        vm.prank(bob); // another address has its own allowance
        stock.faucet(50e18);
    }

    function test_issuerSurfaceMatchesWhatTheMarketProbes() public {
        assertEq(stock.ACCESS_CONTROLLED_REGISTRY(), address(registry));
        assertFalse(stock.paused());
        assertFalse(usdg.paused());
        assertFalse(usdg.isFrozen(alice));
        assertTrue(stock.IS_SIMULATION() && usdg.IS_SIMULATION() && registry.IS_SIMULATION() && feed.IS_SIMULATION());

        vm.prank(alice);
        stock.faucet(10e18);
        vm.prank(owner);
        registry.setBlocked(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimStock.Blocked.selector, bob));
        stock.transfer(bob, 1e18);
        vm.prank(owner);
        registry.setBlocked(bob, false);

        vm.prank(owner);
        stock.setTokenPaused(true);
        vm.prank(alice);
        vm.expectRevert(SimStock.IsPaused.selector);
        stock.transfer(bob, 1e18);
        vm.prank(owner);
        stock.setTokenPaused(false);
        vm.prank(owner);
        registry.setPaused(true); // registry-wide pause also pauses every SimStock
        assertTrue(stock.paused());
        vm.prank(owner);
        registry.setPaused(false);

        vm.prank(alice);
        usdg.faucet(10e6);
        vm.prank(owner);
        usdg.setFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimUSDG.Frozen.selector, bob));
        usdg.transfer(bob, 1e6);
    }

    function test_onlyTheOwnerControlsPauseBlockFreeze() public {
        vm.startPrank(alice);
        vm.expectRevert();
        stock.setTokenPaused(true);
        vm.expectRevert();
        registry.setBlocked(bob, true);
        vm.expectRevert();
        registry.setPaused(true);
        vm.expectRevert();
        usdg.setPaused(true);
        vm.expectRevert();
        usdg.setFrozen(bob, true);
        vm.stopPrank();
    }

    /// @dev The halt demo with real market code: pause, permissionless report, repay still works, unpause, resume.
    function test_haltDemoWithTheSimTokens() public {
        _fund();
        vm.prank(owner);
        stock.setTokenPaused(true);

        HaltReason reason = market.reportIssuerFailure();
        assertEq(uint8(reason), uint8(HaltReason.CollateralPaused));
        assertEq(uint8(market.state()), uint8(MarketState.Halted));

        // the guardian cannot resume while the probes fail
        vm.prank(guardianA);
        vm.expectRevert(ISundownMarket.ProbesFailing.selector);
        market.resume();

        // repay still works, with the collateral token paused
        vm.prank(bob);
        market.repay(1000e6, bob);
        assertEq(market.debtOf(bob), 4000e6 + (market.debtOf(bob) - 4000e6));

        vm.prank(owner);
        stock.setTokenPaused(false);
        vm.prank(guardianA); // probes pass again: the guardian may resume
        market.resume();
        assertEq(uint8(market.state()), uint8(MarketState.Active));
    }

    function test_blocklistingTheMarketHaltsIt() public {
        _fund();
        vm.prank(owner);
        registry.setBlocked(address(market), true);
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.CollateralBlocked));
    }

    function test_usdgPauseHaltsItAndFreezeToo() public {
        _fund();
        vm.prank(owner);
        usdg.setPaused(true);
        assertEq(uint8(market.reportIssuerFailure()), uint8(HaltReason.LoanPaused));
    }

    // ---------------------------------------------------------------- the sim feed and the oracle adapter

    function test_publishAtLetsADemoShowAStaleAndAnInvalidAnswer() public {
        assertEq(uint8(oracle.peek().status), uint8(PriceStatus.Fresh));

        vm.prank(owner);
        feed.publishAt(333e8, block.timestamp - 26 hours);
        assertEq(uint8(oracle.peek().status), uint8(PriceStatus.Stale));

        vm.prank(owner);
        feed.publishAt(0, block.timestamp); // a broken feed
        assertEq(uint8(oracle.peek().status), uint8(PriceStatus.Invalid));

        vm.prank(owner);
        feed.publish(333e8);
        assertEq(uint8(oracle.peek().status), uint8(PriceStatus.Fresh));
    }

    function test_publishAtRefusesTheFutureAndStrangers() public {
        vm.prank(owner);
        vm.expectRevert(SimEquityFeed.FutureTimestamp.selector);
        feed.publishAt(333e8, block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(SimEquityFeed.NotKeeper.selector);
        feed.publishAt(333e8, block.timestamp);
    }

    function test_invalidAnswerBlocksBorrowingInTheMarket() public {
        _fund();
        vm.prank(owner);
        feed.publishAt(0, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISundownMarket.PriceUnusable.selector, uint8(PriceStatus.Invalid)));
        market.borrow(100e6, bob);
    }
}
