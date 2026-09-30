// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {MarketCalendar} from "../src/MarketCalendar.sol";
import {SundownMarket} from "../src/SundownMarket.sol";
import {SundownMarketFactory} from "../src/SundownMarketFactory.sol";
import {FlatGuard} from "../src/guards/FlatGuard.sol";
import {SundownGuard} from "../src/guards/SundownGuard.sol";
import {ChainlinkEquityOracle} from "../src/oracle/ChainlinkEquityOracle.sol";
import {WindowCache} from "../src/oracle/WindowCache.sol";
import {MarketParams} from "../src/interfaces/ISundownMarket.sol";
import {SimEquityFeed} from "sim/SimEquityFeed.sol";
import {SimIssuerRegistry, SimStock, SimUSDG} from "sim/SimTokens.sol";

/// @title DeploySepolia
/// @notice Deploys the Sundown demonstration on Arbitrum Sepolia (421614). Production contracts (calendar, window
/// cache, oracle adapter, factory, markets, guards) are deployed unchanged; every token and price feed is a
/// SIMULATION fixture (SimUSDG, SimStock, SimEquityFeed, SimIssuerRegistry). Idempotent: addresses recorded in
/// `deployments/421614.json` that still have code are reused, only what is missing is deployed.
///
/// Usage (the key never touches the environment or the logs; the keystore is a `cast wallet import` account):
///   SUNDOWN_GUARDIAN=<address> forge script script/DeploySepolia.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
///     --account <keystore> --password-file <file> --sender <deployer> [--broadcast --verify]
/// Set WRITE_DEPLOYMENT=true to write `deployments/421614.json` (addresses; tx hashes and blocks are merged from the
/// broadcast artifacts by scripts/finalize_deployment.py).
contract DeploySepolia is Script {
    uint256 internal constant CHAIN_ID = 421_614;
    string internal constant FILE = "../deployments/421614.json";

    // demonstration parameters (docs/SEPOLIA_DEMO.md; recommended production caps are published in docs only)
    uint64 internal constant STANDARD_LLTV = 0.86e18;
    uint64 internal constant BOOSTED_LLTV = 0.93e18;
    uint256 internal constant MIN_DEBT = 10e6;

    struct Asset {
        string sym;
        string name;
        int256 price8; // starting simulated price, 8 decimals (snapshot of the real feed, research/results/exit_liquidity.json)
        uint256 capTokens; // demonstration collateral cap (10 % of the recommended production cap), whole tokens
        uint256 faucetTokens; // per-address faucet limit, whole tokens
    }

    string[] internal _keys;
    address[] internal _vals;
    string internal _existing;
    bool internal _hasFile;

    address internal deployer;
    address internal guardian;

    // ---------------------------------------------------------------- state helpers

    function _load() internal {
        _hasFile = vm.isFile(FILE);
        if (_hasFile) _existing = vm.readFile(FILE);
    }

    function _known(string memory name) internal view returns (address a) {
        if (!_hasFile) return address(0);
        string memory key = string.concat(".contracts.", name);
        if (!vm.keyExistsJson(_existing, key)) return address(0);
        a = vm.parseJsonAddress(_existing, key);
        if (a.code.length == 0) a = address(0);
    }

    function _put(string memory name, address a) internal returns (address) {
        for (uint256 i; i < _keys.length; ++i) {
            if (keccak256(bytes(_keys[i])) == keccak256(bytes(name))) {
                _vals[i] = a;
                return a;
            }
        }
        _keys.push(name);
        _vals.push(a);
        return a;
    }

    function _get(string memory name) internal view returns (address) {
        for (uint256 i; i < _keys.length; ++i) {
            if (keccak256(bytes(_keys[i])) == keccak256(bytes(name))) return _vals[i];
        }
        revert(string.concat("missing ", name));
    }

    function _assets() internal pure returns (Asset[4] memory a) {
        // price snapshot and caps: research/results/exit_liquidity.json at block 78,536,996 (Robinhood Chain)
        a[0] = Asset("SPY", "SIM SPDR S&P 500 (simulation)", 77_071_000_000, 16, 5);
        a[1] = Asset("AAPL", "SIM Apple (simulation)", 33_382_000_000, 29, 10);
        a[2] = Asset("NVDA", "SIM NVIDIA (simulation)", 23_500_000_000, 238, 50);
        a[3] = Asset("TSLA", "SIM Tesla (simulation)", 37_045_000_000, 25, 8);
    }

    // ---------------------------------------------------------------- entry point

    function run() external {
        require(block.chainid == CHAIN_ID, "Arbitrum Sepolia only");
        guardian = vm.envAddress("SUNDOWN_GUARDIAN");
        _load();

        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        require(deployer != address(0) && guardian != address(0) && guardian != deployer, "roles");

        _infrastructure();
        Asset[4] memory assets = _assets();
        for (uint256 i; i < assets.length; ++i) {
            _asset(assets[i]);
        }
        _guards();
        for (uint256 i; i < assets.length; ++i) {
            _market(string.concat(assets[i].sym, "_standard"), assets[i], "FlatGuard_86");
        }
        _market("AAPL_boosted_93", assets[1], "SundownGuard_AAPL93");
        _market("AAPL_control_93", assets[1], "FlatGuard_93");
        _bindBoosted();
        vm.stopBroadcast();

        _report();
        if (vm.envOr("WRITE_DEPLOYMENT", false)) _write();
    }

    // ---------------------------------------------------------------- components

    function _infrastructure() internal {
        address a = _known("SimUSDG");
        if (a == address(0)) a = address(new SimUSDG(deployer, 100_000e6));
        _put("SimUSDG", a);

        a = _known("SimIssuerRegistry");
        if (a == address(0)) a = address(new SimIssuerRegistry(deployer));
        _put("SimIssuerRegistry", a);

        a = _known("MarketCalendar");
        if (a == address(0)) a = address(new MarketCalendar(deployer, 1 days));
        _put("MarketCalendar", a);

        a = _known("WindowCache");
        if (a == address(0)) a = address(new WindowCache(_get("MarketCalendar")));
        _put("WindowCache", a);

        a = _known("SundownMarketImplementation");
        if (a == address(0)) a = address(new SundownMarket());
        _put("SundownMarketImplementation", a);

        a = _known("SundownMarketFactory");
        if (a == address(0)) a = address(new SundownMarketFactory(_get("SundownMarketImplementation"), deployer));
        _put("SundownMarketFactory", a);
    }

    function _asset(Asset memory x) internal {
        string memory stockKey = string.concat("SimStock_", x.sym);
        address a = _known(stockKey);
        if (a == address(0)) {
            a = address(
                new SimStock(
                    x.name,
                    string.concat("s", x.sym),
                    SimIssuerRegistry(_get("SimIssuerRegistry")),
                    deployer,
                    x.faucetTokens * 1e18
                )
            );
        }
        _put(stockKey, a);

        string memory feedKey = string.concat("SimEquityFeed_", x.sym);
        a = _known(feedKey);
        if (a == address(0)) {
            a = address(new SimEquityFeed(deployer, string.concat("SIM ", x.sym, " / USD (simulation)"), x.price8));
        }
        _put(feedKey, a);

        string memory oracleKey = string.concat("ChainlinkEquityOracle_", x.sym);
        a = _known(oracleKey);
        if (a == address(0)) {
            a = address(
                new ChainlinkEquityOracle(
                    ChainlinkEquityOracle.Config({
                        feed: _get(feedKey),
                        collateralToken: _get(stockKey),
                        windowCache: _get("WindowCache"),
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
                )
            );
        }
        _put(oracleKey, a);
    }

    function _guards() internal {
        address a = _known("FlatGuard_86");
        if (a == address(0)) a = address(new FlatGuard(STANDARD_LLTV, 0.04e18));
        _put("FlatGuard_86", a);

        a = _known("FlatGuard_93");
        if (a == address(0)) a = address(new FlatGuard(BOOSTED_LLTV, 0.04e18));
        _put("FlatGuard_93", a);

        a = _known("SundownGuard_AAPL93");
        if (a == address(0)) {
            // D26: full-sample empirical q99.5 downside gap for AAPL (research/results/class_stats.csv, 2010-2026)
            SundownGuard.Params memory p = SundownGuard.Params({
                standardLltv: STANDARD_LLTV,
                boostedLltv: BOOSTED_LLTV,
                gapShort: 28_299e12,
                gapWeekend: 91_529e12,
                gapLong: 59_700e12,
                oracleBuffer: 0.005e18,
                safetyBuffer: 0.01e18,
                bonus: 0.04e18,
                deleverageFee: 0.02e18,
                deleverageMargin: 0.005e18,
                preWindowHorizon: 6 hours,
                cureWindow: 3 hours
            });
            a = address(
                new SundownGuard(
                    p,
                    _get("ChainlinkEquityOracle_AAPL"),
                    _get("WindowCache"),
                    deployer,
                    guardian,
                    deployer,
                    2 days,
                    18,
                    6
                )
            );
        }
        _put("SundownGuard_AAPL93", a);
    }

    function _params(string memory id, Asset memory x, address guard_, uint64 lltv)
        internal
        view
        returns (MarketParams memory)
    {
        return MarketParams({
            collateralToken: _get(string.concat("SimStock_", x.sym)),
            loanToken: _get("SimUSDG"),
            oracle: _get(string.concat("ChainlinkEquityOracle_", x.sym)),
            guard: guard_,
            guardian: guardian,
            governance: deployer,
            lltvWad: lltv,
            closeFactorWad: 0.5e18,
            criticalHealthWad: 0.95e18,
            maxBonusWad: 0.055e18,
            collateralCap: uint128(x.capTokens * 1e18),
            minDebt: uint128(MIN_DEBT),
            baseAprWad: 0,
            slope1AprWad: 0.04e18,
            slope2AprWad: 0.75e18,
            kinkWad: 0.8e18,
            shareName: string.concat("Sundown ", id, " (SIMULATION)"),
            shareSymbol: string.concat("sd-", id)
        });
    }

    function _market(string memory id, Asset memory x, string memory guardKey) internal {
        string memory key = string.concat("Market_", id);
        address m = _known(key);
        if (m == address(0)) {
            uint64 lltv = keccak256(bytes(guardKey)) == keccak256("FlatGuard_86") ? STANDARD_LLTV : BOOSTED_LLTV;
            MarketParams memory p = _params(id, x, _get(guardKey), lltv);
            SundownMarketFactory f = SundownMarketFactory(_get("SundownMarketFactory"));
            address predicted = f.predictMarket(p);
            m = predicted.code.length > 0 ? predicted : f.createMarket(p);
        }
        _put(key, m);
    }

    function _bindBoosted() internal {
        SundownGuard g = SundownGuard(_get("SundownGuard_AAPL93"));
        if (address(g.market()) == address(0)) g.bindMarket(_get("Market_AAPL_boosted_93"));
    }

    // ---------------------------------------------------------------- output

    function _report() internal view {
        console2.log("Arbitrum Sepolia demonstration deployment (SIMULATION fixtures + production code)");
        console2.log("deployer", deployer);
        console2.log("guardian", guardian);
        for (uint256 i; i < _keys.length; ++i) {
            console2.log(_keys[i], _vals[i]);
        }
        console2.log("config hash");
        console2.logBytes32(_configHash());
    }

    /// @dev Hash of every number and role that defines the demonstration.
    function _configHash() internal view returns (bytes32) {
        Asset[4] memory a = _assets();
        return keccak256(
            abi.encode(
                CHAIN_ID,
                STANDARD_LLTV,
                BOOSTED_LLTV,
                MIN_DEBT,
                deployer,
                guardian,
                a[0].price8,
                a[1].price8,
                a[2].price8,
                a[3].price8,
                a[0].capTokens,
                a[1].capTokens,
                a[2].capTokens,
                a[3].capTokens
            )
        );
    }

    function _write() internal {
        string memory contracts = "contracts";
        string memory inner;
        for (uint256 i; i < _keys.length; ++i) {
            inner = vm.serializeAddress(contracts, _keys[i], _vals[i]);
        }
        string memory root = "root";
        vm.serializeUint(root, "chainId", CHAIN_ID);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "guardian", guardian);
        vm.serializeBytes32(root, "configHash", _configHash());
        vm.serializeString(
            root,
            "status",
            "SIMULATION fixtures (SimUSDG, SimStock, SimEquityFeed, SimIssuerRegistry) plus production Sundown contracts; not real tokens or feeds"
        );
        string memory out = vm.serializeString(root, "contracts", inner);
        vm.writeJson(out, FILE);
    }
}
