# Sundown M0 - Feasibility Discovery

Date of all observations: **2026-10-02** (Fri, ~12:50-14:45 ET). Chain state, prices and registries move; re-verify before relying on any number here.

## Labels

| Label | Meaning |
|---|---|
| **verified-onchain** | I read it from the chain myself (`cast`, `eth_getLogs`) in this session |
| **verified-api** | I fetched it from a primary vendor API/page in this session |
| **documented** | Stated by a primary vendor doc I fetched, not independently confirmed |
| **secondary** | Press/aggregator report only |
| **unverified** | Not checked, or the check failed; needs follow-up |

Raw commands/scripts were run from a scratch directory and are not committed (they are throwaway probes). Chain data I used for claims is reproducible with the calls quoted below.

---

## a. Chains

| | Arbitrum One | Arbitrum Sepolia | Robinhood Chain (mainnet) | Robinhood Chain Testnet |
|---|---|---|---|---|
| Chain ID | 42161 - **verified-onchain** | 421614 - **verified-onchain** | **4663** - verified-onchain | **46630** - verified-onchain |
| Public RPC | `https://arb1.arbitrum.io/rpc` - verified-onchain | `https://sepolia-rollup.arbitrum.io/rpc` - verified-onchain | `https://rpc.mainnet.chain.robinhood.com` - verified-onchain | `https://rpc.testnet.chain.robinhood.com` - verified-onchain |
| Explorer | Arbiscan (unverified) | Sepolia Arbiscan (unverified) | `robinhoodchain.blockscout.com` - documented. **Returns HTTP 403 to automation** (Cloudflare) | `explorer.testnet.chain.robinhood.com` - verified-api (Blockscout v2 API reachable) |
| Gas token | ETH | ETH | ETH - documented | ETH - documented |
| Stack | Nitro | Nitro | Arbitrum Orbit (Nitro), ETH blobs for DA - documented | same |
| Cancun opcodes (`PUSH0`, `TLOAD`, `MCOPY`) | supported - **verified-onchain** (eth_call, with an `INVALID` negative control that errors) | supported - verified-onchain | supported - verified-onchain | supported - verified-onchain |
| Stylus precompile `ArbWasm.stylusVersion()` | 3 - verified-onchain | 3 - verified-onchain | 3 - verified-onchain | 3 - verified-onchain |
| Permissioning | open | open | "permissionless", anyone may deploy - documented | same |

Additional notes:

- Provider recommended by Robinhood: Alchemy (`robinhood-mainnet.g.alchemy.com/v2/{KEY}`). Public endpoints are rate-limited, **not archive** (`historical state ... is not available` on `eth_call --block`), and intermittently drop connections. `eth_getLogs` works in 100k-block chunks (verified-onchain). Block rate ~10 blocks/s on Robinhood mainnet (derived from `cast find-block`).
- Foundry deploy and Blockscout verification are **documented** with the exact commands (`forge create ... --broadcast`, `forge verify-contract --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`, `--chain-id 4663`). I have **not** deployed anything (needs funded key) -> **unverified** end to end.
- Testnet faucet: Robinhood-operated `faucet.testnet.chain.robinhood.com` and QuickNode `faucet.quicknode.com/robinhood/testnet` appear in search results only -> **secondary/unverified**.
- Robinhood mainnet launched 2026-07-01 (secondary: The Defiant, fintech.global; consistent with the first Chainlink feed update I observed on 2026-07-02).
- Chain-ID conflict seen in secondary sources (4663 vs 46630): resolved by on-chain `eth_chainId`: **4663 mainnet, 46630 testnet**.
- Robinhood chain contracts (L1 rollup, bridge, gateways, Permit2 at `0x000000000022D473030F116dDEE9F6B43aC78BA3`, L2 Multicall `0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1`) are listed at <https://docs.robinhood.com/chain/protocol-contracts> - documented.

Sources: <https://docs.robinhood.com/chain/connecting>, <https://docs.robinhood.com/chain/deploy-smart-contracts>, <https://docs.robinhood.com/chain/protocol-contracts>.

## b. Stock tokens

### Mainnet (chain 4663) - verified-api + verified-onchain

- Registry: `GET https://api.robinhood.com/rhj/assets` -> **194 assets, all status ACTIVE, all deployed only on chain 4663**, all `tokenDecimals = 18`, all report `TRADING_STATUS_TRADABLE` for the overnight session (verified-api).
- Examples (address, from the registry; all verified-onchain for `decimals()==18`): AAPL `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`, NVDA `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, TSLA `0x322F0929c4625eD5bAd873c95208D54E1c003b2d`, MSFT `0xe93237C50D904957Cf27E7B1133b510C669c2e74`, SPY `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C`, QQQ `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68`, GOOGL `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3`, AMZN `0x12f190a9F9d7D37a250758b26824B97CE941bF54`, META `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35`, COIN `0x6330D8C3178a418788dF01a47479c0ce7CCF450b`.
- Docs warn: only addresses on the Token Contracts page / registry are canonical; same-ticker tokens at other addresses are not Robinhood Stock Tokens (documented).
- Loan token candidate: **USDG** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals** (verified-onchain), WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`. The 18-decimal collateral / 6-decimal loan / 8-decimal price mix must be handled explicitly.
- Stock tokens are **tokenised debt securities** issued by Robinhood Assets (Jersey) Ltd; not offered to US persons (documented). Eligibility/KYC applies to the *primary market and the Robinhood app*; the token itself is a plain ERC-20 that anyone can hold on-chain (Chainlink's SVR doc: "once the tokens are onchain, anyone can hold them and anyone can liquidate").

### Corporate-action multiplier (ERC-8056) - documented + verified-onchain

- `uiMultiplier()` (18 dp, 1e18 = 1.0), `newUIMultiplier()`, `effectiveAt()`, `balanceOfUI()`, `totalSupplyUI()`, event `UIMultiplierUpdated`. Raw `balanceOf` does **not** change on corporate actions: tokens are not rebasing.
- Live: 45 of 194 tokens have a multiplier != 1.0 (e.g. AAPL 1.000566..., NVDA 1.000775..., SPY 1.001718..., CRWD 4.0 after a split) (verified-api). Dividends accrue into the multiplier, so **a token's price drifts upward vs the underlying share price** (documented).
- Chainlink feeds already include the multiplier (price per token), so consumers must not multiply again (documented).
- Mainnet token exposes `oraclePaused()` (verified-onchain: `false` on AAPL/NVDA/TSLA/SPY); testnet token does **not** (reverts) - testnet runs an older token version.

### Mint/burn window - documented

- Primary mint/burn by Authorised Participants (at launch only BBVI), KYB-onboarded: **Mon 02:00 CET/CEST -> Sat 02:00 CET/CEST** (DST-dependent). Outside this window no mint/burn; users can still trade on secondary venues.
- Secondary venues: RFQ aggregators (0x RFQ, 1inch Fusion, LiFi), Uniswap-style AMMs, propAMM (Rialto), Lighter orderbook (documented). "Tokenized stocks trade via RFQ at launch" -> on-chain AMM liquidity may be thin. **Liquidation liquidity is unverified** (see Threat model).

### Transfer restrictions that affect a lending market (important) - now verified on mainnet source

Sources (all **verified-api**, fetched 2026-10-02 from Sourcify v2, `exact_match` for both creation and runtime bytecode, solc 0.8.33, verified 2026-09-08):
`https://sourcify.dev/server/v2/contract/4663/0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2?fields=all` (implementation `Stock`) and
`https://sourcify.dev/server/v2/contract/4663/0xe10b6f6B275de231345c20D14Ab812db62151b00?fields=all` (`AccessControlsRegistry`).
Browser links for the same contracts: <https://robinhoodchain.blockscout.com/address/0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2?tab=contract> and <https://robinhoodchain.blockscout.com/address/0xe10b6f6B275de231345c20D14Ab812db62151b00?tab=contract> (Blockscout itself returns 403 to automation).

`Stock` (mainnet implementation) behaves as the testnet code did:

- `transfer`, `transferFrom`, `approve`, `permit`, `mint`, `burn` all revert with `IsPaused()` when `paused()` is true, and with `Blocked(account)` when **any of `from`, `to` or `msg.sender`** (and `spender` for approve/permit) is blocked. *A pause or a block can make liquidation transfers revert, including to/from the lending market and a liquidator.*
- `paused()` = the token's own flag OR the registry-wide flag, so **one registry call (`pause()`, `PAUSER_ROLE`) freezes all 194 tokens**. `tokenPaused()` exposes only the token flag. `pause()/unpause()` on a token need `TOKEN_PAUSER_ROLE`.
- `adminBurn(address from, uint256 amount)` (`ADMIN_BURNER_ROLE`) burns from **any** address with no pause, block, balance-vs-allowance or approval condition. *The issuer can burn the collateral held by the market.* `burn(from, amount)` (`BURNER_ROLE`) is subject to pause/block.
- `updateMultiplier(...)` (`MULTIPLIER_UPDATER_ROLE`, reverts while paused), `pauseOracle()/unpauseOracle()` (`ORACLE_PAUSER_ROLE`), `setMetadata` (`METADATA_UPDATER_ROLE`).
- `decimals()` is the OZ default 18 (no override in `Stock.sol`). `terms()` returns `https://robinhood.com/stocktoken/rhj`.
- Transfers are ordinary otherwise: no allowlist, no transfer fee, no hook that calls the receiver.

`AccessControlsRegistry` (`0xe10b6f6B275de231345c20D14Ab812db62151b00`) is **both** the EIP-1967 beacon (`implementation()`, `upgradeTo` by `BEACON_UPGRADER_ROLE`) and the access-control/blocklist/global-pause contract (`blockAccounts/unblockAccounts` by `BLOCKER_ROLE`, `pause/unpause` by `PAUSER_ROLE`, plain OpenZeppelin `AccessControl`). Its `implementation()` is `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`. Tokens are beacon proxies, so **one upgrade changes the logic of all tokens at once**; there is no timelock in the registry code.

**Role holders (verified-onchain, from the registry's `RoleGranted/RoleRevoked` logs over the whole chain history, current state):** every privileged role is held by an **EOA**, not a multisig or timelock contract (checked with `eth_getCode`): `DEFAULT_ADMIN_ROLE` `0xd6f8378f8e440c65f8382f5f2728c78dfd55b66d`; `BEACON_UPGRADER_ROLE` `0xcd8c6182e7c6ca3b5156d6a90a67719d7e2be094`; `BLOCKER_ROLE` `0x913ca87347391218e5de2c17c5a0aeba8b0b28fd`; `ADMIN_BURNER_ROLE` `0x957b6de6525c63349f7619743ef1e0ad93cd74d4`; `PAUSER_ROLE` `0xe7bcb188254bc6ebbff63014dfed4cd4a024f22a`; `TOKEN_PAUSER_ROLE` `0xfccf56b674113d9c4eb0f9b3370930ced9e6ab23`; `ORACLE_PAUSER_ROLE` `0x7369d100c00f28e45d779ac9d4b1c7afa61e4abc`; `MULTIPLIER_UPDATER_ROLE` `0x92905e8d0e2301ba143215b8d86d63ffd4188143`; `MINTER_ROLE` `0x2b94105fff37630f98e1f24811dad588fc5c3a87`; `BURNER_ROLE` `0x6e40b50a40c1db42a85a0e8fe8ff7d9cbfc2d8c1`; `METADATA_UPDATER_ROLE` `0xcba16c2b9048af033c5b34e43dd1d47d1358524a`; `TOKEN_DEPLOYER_ROLE` `0x5516b3451d4d6c9f63353fe7bc9537477ecce000`; `FACTORY_UPGRADER_ROLE` `0x697e774d60c1a3769f2ed0b919aacf17be0ae553`. (An EOA could itself be a 7702-style delegate; not checked.) The default admin can grant any role to anyone.

**Registry history (verified-onchain):** registry deployed ~2026-05-21 (`Upgraded` block 7,796 to the current implementation); `Blocked` was emitted 246 times between 2026-06-08 and 2026-06-29 (175 addresses are blocked now, 177 ever; 4 `Unblocked`); one global `Paused` on 2026-06-30 17:01Z for about one minute (launch-day), then `Unpaused`; `Upgraded` again 2026-07-01 00:38Z to the **same** implementation address; **no pause, upgrade or block events since launch** (through block 78.5M). So issuer controls exist, were exercised before and at launch, and have been quiet for three months. This does not bound the risk.

Live state (verified-onchain 2026-10-02): registry `paused() == false`, `tokenPaused() == false` for AAPL/NVDA/TSLA/MSFT/SPY/QQQ/GOOGL; the registry does **not** block Morpho Blue `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`, the Uniswap v3 factory-created pools were not checked for blocking, `0xdEaD` is not blocked.

**What the market needs from this (feeds D2 and MARKET_DESIGN):** pause state (`paused()` is exposed: cheap, exact probe), blocklist (`isBlocked` lives on the *registry*, not the token; probe by `registry.isBlocked(market)` where `registry = token.ACCESS_CONTROLLED_REGISTRY()`, or by a try/catch 1-wei transfer), `adminBurn` (not detectable ahead of time; only observable as a balance drop, so the market must account collateral internally and tolerate `balanceOf(market) < sum(collateral)`), transfer hooks (none beyond pause/block), upgrade authority (one EOA-held beacon upgrader for all tokens), decimals (18).

## c. Oracles

### Chainlink on Robinhood Chain mainnet

Documented by Chainlink and Robinhood, and confirmed by live reads:

- **Push `AggregatorV3Interface`** feeds via proxy (not Data Streams pull) for each token: `latestRoundData()`, 8 decimals (verified-onchain: `decimals()==8` for NVDA, TSLA, AAPL, SPY). Price = **token** price = underlying share price x `uiMultiplier` (documented).
- Chainlink's page <https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood> lists **35** "Robinhood X / USD" 24/5 feeds on Robinhood Chain Mainnet, all `heartbeat = 86400 s`, `deviation = 0.5 %`, 8 decimals (verified-api, parsed from page data). Only **32 of the 194 tokens** have a feed (the other 3 are non-token names: `DELL-USD`, `SGOV-USD`, `USAR-USD`). The page tells integrators to contact Chainlink Labs before integrating.
- Feed proxies (verified-api; descriptions verified-onchain for some): AAPL `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`, NVDA `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`, TSLA `0x4A1166a659A55625345e9515b32adECea5547C38`, SPY `0x319724394D3A0e3669269846abE664Cd621f9f6A`, QQQ `0x80901d846d5D7B030F26B480776EE3b29374C2ae`, AMZN `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C`, GOOGL `0xF6f373a037c30F0e5010d854385cA89185AE638b`, META `0x7C38C00C30BEe9378381E7B6135d7283356D71b1`, MSFT `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E`, COIN `0xA3a468A452940B7D6b69991207B508c609a98Ef2`. Aggregator for AAPL `0xBb11A21267cFDb63d4935d99a499133DD1744ACb` emits `AnswerUpdated`.
- Feed paths contain `shared-svr` -> **SVR (Smart Value Recapture) feeds**; Chainlink states liquidations on these feeds are open to anyone while primary mint/redeem may be permissioned (documented).
- **Nothing on Arbitrum One or Arbitrum Sepolia**: Chainlink's tokenized-equity feed page lists Base Mainnet (generic) and, in the provider catalog, Robinhood Chain Mainnet only (documented). **No Robinhood Chain testnet feeds are listed** (documented/absence; unverified onchain).
- Data Streams (pull) 24/5 US equities streams exist; verifier proxy on Robinhood Chain: `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (documented). A Data Streams report requires a licensed off-chain fetch plus on-chain `verify()`; not a drop-in for a permissionless borrow flow.

### marketStatus

- `marketStatus` (0 Unknown, 1 Pre, 2 Regular, 3 Post, 4 Overnight, 5 Closed for 24/5 feeds; 0/2/5 only for standard-hours feeds) exists **only inside Data Streams v11 reports**, **not** in the push AggregatorV3 feed (documented: <https://docs.chain.link/data-streams/market-hours>). Halts are **not** reflected in `marketStatus` (documented). -> On-chain session knowledge on a push-feed integration must come from our own calendar; `marketStatus` is only usable via report verification.

### 24/5 session model (documented) and its measured on-chain behavior (verified-onchain)

Documented schedule: Pre 04:00-09:30, Regular 09:30-16:00, Post 16:00-20:00, Overnight 20:00-04:00 (ET), feed "open" Sun 20:00 ET -> Fri 20:00 ET, **Closed ~Fri 20:00 -> Sun 20:00 ET and on NYSE holidays**. "Feeds do not publish updates, including heartbeat updates, while markets are closed" and hold the last value (documented).

I measured this with `eth_getLogs(AnswerUpdated)` on the AAPL and NVDA aggregators:

| Window | Last update before | First update after | Reading |
|---|---|---|---|
| Labor Day weekend (Mon 2026-09-07 holiday) | AAPL Fri 09-04 19:51Z (15:51 ET); NVDA Fri 09-04 17:46Z | **Tue 09-08 00:00Z = Mon 09-07 20:00 ET** (both feeds) | blind until 20:00 ET **on the holiday itself** |
| Independence Day observed (Fri 2026-07-03) | AAPL Thu 07-02 16:15Z; NVDA Thu 07-02 19:55Z | **Mon 07-06 00:00Z = Sun 07-05 20:00 ET** (both feeds) | blind from Thursday to normal Sunday reopen |

Consistent rule (fits both observations): a *trading day* T runs from **20:00 ET on the previous calendar day** to **20:00 ET on T**; trading days that are weekends/NYSE holidays are closed. The blind window is therefore `[20:00 ET close of last open trading day, 20:00 ET of the evening before the next open trading day]`.

Consequences:

1. **Weeknight overnight (20:00-04:00 ET) is not a blind period** for the 24/5 feed; it is a thin-liquidity period (gap *risk* but the feed can update). Only weekends/holidays are blind.
2. The **actual last update before a closure is not schedule-determined**. Updates are deviation (0.5 %) or 24 h heartbeat triggered, so even in open sessions gaps of 10-18 h occur (e.g. AAPL Wed 09-02 21:23Z -> Thu 09-03 13:33Z). Live today (Friday during regular hours) `updatedAt` ages were 13 min (AAPL), 46 min (NVDA), 83 min (TSLA) and **4.4 h (SPY)**. **A heartbeat-based staleness check cannot distinguish "market closed" from "quiet market"**, and a tight check would revert borrows on liquid names during normal hours. The oracle adapter must combine (calendar session, last `updatedAt`, price bounds) instead of a single staleness threshold.
3. The last pre-closure price may be hours old, i.e. **blind start >= scheduled close - ~hours**. The gap that matters for risk is `[last_update, next_open_price]`.

Unverified: behavior on **early-close days** (e.g. day after Thanksgiving, Christmas Eve) and on the *trading-day-after* a holiday for post-market/overnight. Only two holiday observations exist so far (above); both consistent with the rule. Further evidence can be pulled from the same aggregators for Nov 2026 once those events occur, and from the full 2026-07-01..today range now (Memorial/Juneteenth predate launch).

### Other oracle risks (documented by Chainlink)

- Overnight/extended sessions: fewer providers; feeds may report **zero** or atypical values with fresh timestamps -> bounds checks required.
- Smoothing-induced tracking lag (seconds to tens of seconds) around transitions.
- Corporate actions pause the feed (`oraclePaused()` on token; "advisory, not enforced on-chain"), freezing at last good value, possibly for days; splits shift the underlying price by integer factors.
- Weekend/holiday last value "may not match the official close".

### L2 sequencer uptime feed

- **Arbitrum One:** `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` - documented; live read verified-onchain (`answer = 0` (up), `startedAt = 1779307607`).
- **Arbitrum Sepolia:** not listed by Chainlink -> unverified/likely absent.
- **Robinhood Chain (mainnet/testnet): not in Chainlink's supported list** (the page states Chainlink "is no longer expanding L2 Sequencer Uptime Feeds to additional networks") even though Robinhood's docs recommend checking one. -> **Treat as unavailable**; verified absence in docs only; I cannot enumerate the chain to prove no deployment exists. Sundown must not hard-depend on it; use a configurable optional sequencer feed + a different liveness heuristic (e.g. `block.timestamp` gaps / L1 `ArbSys` data) - decision in DESIGN.

Sources: <https://docs.chain.link/data-feeds/tokenized-equity-feeds>, <https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood>, <https://docs.chain.link/data-streams/market-hours>, <https://docs.chain.link/data-streams/rwa-streams/24-5-us-equities-user-guide>, <https://docs.chain.link/data-feeds/l2-sequencer-feeds>, <https://docs.robinhood.com/chain/oracles-and-price-feeds>, <https://docs.robinhood.com/chain/data-streams>.

## d. Testnet reality

- **Arbitrum Sepolia:** no Robinhood stock tokens and no Chainlink tokenized-equity or sequencer feeds (documented absence; unverified onchain).
- **Robinhood Testnet (46630):** has **5 Robinhood-style stock tokens** - AMZN `0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02`, TSLA `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E`, AMD `0x71178BAc73cBeb415514eB542a8995b82669778d`, PLTR `0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0`, NFLX `0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93` (all 18 dp; verified-api explorer; AMZN verified-onchain `uiMultiplier = 1e18`), testnet USDG `0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec` (6 dp). These are older-version tokens (no `oraclePaused`). A third-party Aave-style app ("Edel": `eTSLA`, `variableDebtTSLA`, ...) already lists them as collateral on testnet. **No Chainlink feeds on testnet are listed** -> price source on testnet is unverified/absent.
- **Honest minimal simulation fixture set** (all under `contracts/test/mocks`, named `Sim*`, documented as simulation, never claimed as integrations):
  1. `SimEquityFeed` - AggregatorV3-shaped feed whose price path and update schedule follow the *measured* 24/5 behaviour above (deviation-triggered updates, blind weekends/holidays, last-value hold).
  2. `SimSequencerFeed` - settable up/down + `startedAt`.
  3. `SimStockToken` - ERC-20 (18 dp) with `uiMultiplier`, `paused`, `blocked`, `adminBurn` hooks to test the transfer-restriction threat model.
  4. `SimUSDG` (6 dp) and a minimal swap venue stub for liquidation-liquidity scenarios (labelled as a fixture, not a DEX integration).
- The **Chainlink adapter stays unlabeled "integrated"** until a fork test passes against real feeds: the fork profile reads Robinhood mainnet `latestRoundData()` (verified feasible today). Testnet cannot validate it.

## e. Stylus toolchain (this machine: WSL2 Ubuntu)

| Item | Result |
|---|---|
| rustc / cargo | 1.91.0 (verified) |
| wasm target | `wasm32-unknown-unknown` installed (verified) |
| cargo-stylus | 0.10.9, installed with `cargo install --locked` after a transient DNS failure (verified) |
| Hello-world (`cargo stylus new`) | wasm build OK (release, 109 B + 18.5 KB `.wasm`, **6.0 KB** compressed contract), `cargo stylus export-abi` OK, host unit test `cargo test --lib` **1 passed** using `stylus-sdk` `stylus-test` feature as **dev-dependency only** (enabling it in normal deps breaks the wasm build) (verified) |
| `cargo stylus check` vs Arbitrum Sepolia public RPC | **fails**: `execution reverted` (cause unknown) |
| `cargo stylus check` vs Robinhood testnet public RPC | **fails**: `program activation failed: stylus activations not allowed for this request` (public RPC restricts activation simulation) |
| nitro-devnode via Docker | **blocked**: Docker Desktop 29.7.2 installed on Windows but daemon not running and no `docker` in WSL (unverified). **ACTION FOR YOU:** start Docker Desktop and enable WSL integration for Ubuntu (Settings -> Resources -> WSL integration), or tell me to skip Stylus. |

Not committed (throwaway in `/tmp`). Conclusion: Stylus *compiles and unit-tests locally*; on-chain activation/gas behaviour is **unverified**, and the activation rejection on both public RPCs means a private RPC or devnode is required for any evidence. See DESIGN go/no-go.

## f. Prior art

Aave and Morpho are **complementary** reference points; none of the below is Sundown's claim to novelty except dynamic, session-aware risk.

### Aave V4 "Equities Hub" on Base (secondary - press; parameters not yet checked against Aave governance)

- Live 2026-09-25 on **Base** (not Robinhood Chain), seven **Coinbase** tokenized stocks (AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc) as collateral for **USDC**.
- Risk provider LlamaRisk: collateral factors **65-79 %** (V4 uses one factor for both borrow limit and liquidation threshold), supply cap **$32M USDC**, borrow cap **$21M**, aggregate collateral limit ~$29M, **max liquidation bonus 5.5 %**.
- Oracle: Chainlink tokenized-equity feed operating window **Sun 20:00 ET -> Fri 20:00 ET**; weekends/holidays hold the last price; the market remains open for deposit/borrow/liquidation. LlamaRisk explicitly flags weekend gap risk to USDC lenders and absorbs it with the conservative static collateral factors. (secondary: techflowpost, kucoin, cryptoslate; I could fetch only techflowpost). **Unverified against the primary Aave governance post/LlamaRisk report.**

### Morpho Blue on Robinhood Chain (verified-api, Morpho GraphQL `api.morpho.org/graphql`, chainId 4663)

- Morpho Blue `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`. The API returned a 100-market page of **permissionless markets**, mostly empty/dust; stock-collateral/USDG markets use LLTV **38.5 %, 62.5 %, 77 %, 86 %** (static per market, not session-aware); oracles are per-market addresses (**not inspected**, so how each oracle handles blind windows is **unverified**).
- Largest stock-collateral market observed: AAPL/USDG `0xdeb4782d...`, LLTV 62.5 %, supply ~$197k, borrowed ~$197k (~100 % utilization) at query time.
- Robinhood Earn lends USDG via Morpho vaults (curator Steakhouse Financial) - secondary (search snippets).

### Positioning

Both venues manage weekend risk with **static** parameters (a conservative LTV/LLTV and a fixed bonus cap). Sundown's proposed contribution is *dynamic, calendar-aware* risk (stress-based borrow capacity tightening before a blind window, a post-gap settling window), implemented as an isolated market with a pluggable guard so it can be A/B tested against a static guard. It should be presented as complementary: a risk layer and a measurement tool, not as "safer than Aave" until the replay evidence exists.

## g. Exit liquidity (decision D5, M3 step 3a)

**Method (verified-onchain, `research/exit_liquidity.py`, results in `research/results/exit_liquidity.json`, RPC head block 78,536,996 = Fri 2026-10-02 21:01Z = 17:01 ET, i.e. just after the regular close).** Pools are discovered on-chain with the Uniswap v3 factory `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` (`getPool(stock, USDG, fee)` for fee tiers 100/500/3000/10000; no third-party index). For each pool: `slot0`, `liquidity`, `tickSpacing`, `fee`, `tickBitmap` and `ticks(liquidityNet)` within +/-3 bitmap words. The simulator sells the stock for USDG through the exact v3 swap (tick crossing, fee on input); it is unit-tested (`research/tests/test_exit_liquidity.py`: closed form, numerical integration across tick boundaries in both directions, monotonicity, fee and oracle-basis effects) and the tests caught two bugs in my first version (an exhausted-range error and floating-point cancellation), fixed before these numbers. **Slippage is measured against the Chainlink oracle price** (what the lender marks collateral at), so fee + price impact + pool-to-oracle basis are all included. Depth that cannot absorb the size inside the scanned window is treated as zero (conservative).

**Maximum position notional (USD, at the oracle price) that can be sold with slippage <= s, summed over v3 pools** (each pool at its own slippage, so the aggregate average slippage is <= s):

| Asset | v3 pools (live) | s <= 1 % | s <= 3 % | s <= 5 % | Share of the 3 % figure from the deepest pool | Oracle age at read |
|---|---|---|---|---|---|---|
| TSLA | 3 of 4 tiers | $50.6k | $189.9k | $304.0k | 95 % (`0xf4ac...e3`, fee 0.3 %) | 1.1 h |
| NVDA | 4 of 4 | $262.4k | $1.119M | $1.861M | 99 % (`0xd4eb...a3`, fee 0.05 %) | 3.9 h |
| AAPL | 3 of 4 | $85.8k | $196.6k | $220.0k | 78 % (`0xaae0...d6d`, fee 0.05 %) | 4.4 h |
| SPY | 2 of 4 | $143.6k | $249.9k | $250.5k | 94 % (`0xa7bb...167`, fee 0.05 %) | 8.5 h |

Per-pool numbers, ticks scanned, ladder slippage at $10k-$1M and the pool addresses are in the JSON. Observations:

- **Depth is thin and concentrated in one pool per asset.** Even NVDA, the deepest, absorbs about $1.1M at 3 %; TSLA, AAPL and SPY about $0.2M each. A full liquidation of a collateral pool larger than that exceeds what v3 can absorb at an acceptable price.
- **Basis matters:** an NVDA fee-0.01 % pool (`0xb75d...333`) sits **11.8 % below** the oracle and contributes nothing at <= 5 %; AAPL pools sit 0.1-0.6 % below the oracle; the oracle ages were 1-8.5 h (heartbeat/deviation behavior, see section c), and after hours both sides move.
- **Not covered, stated plainly:** Uniswap v4 pools (DexScreener lists many; they only add depth, so these are lower bounds for those venues), RFQ/aggregator routing, other DEXes, liquidity outside the scanned ticks, and the fact that liquidity changes minute to minute. Weekend/holiday depth is likely worse (market makers quote off a frozen oracle) and is unmeasured.
- **Comparison with the secondary snapshot** (`research/results/pool_depth_snapshot.json`, DexScreener TVL: TSLA $1.59M over 11 pools, NVDA $4.82M over 21, AAPL $1.71M over 15, SPY $7.68M over 17): TVL counts non-USDG quote pairs and v4 pools and overstates *USDG exit depth*; the exact v3 USDG figures above are the ones to use for caps.

**Derived per-market collateral-cap rule (proposal, for approval in MARKET_DESIGN):** `collateralCapUsd = alpha * maxNotional(3 %)`, with `alpha = 0.5` initially. Rationale: a liquidator's margin is `(1 + bonus) * (1 - s) - 1`; at the 5.5 % Aave-style bonus, `s = 3 %` leaves ~2.4 % margin, and `alpha = 0.5` leaves headroom for a partial liquidation of the whole book plus other sellers. With today's numbers this gives caps of about TSLA $95k, NVDA $560k, AAPL $98k, SPY $125k, **about $0.9M of collateral across the four candidate markets**. This is the honest size of the opportunity on current on-chain liquidity and it should be shown to users; Morpho's AAPL/USDG market already has ~$197k supplied (section f).

---

## Findings that change or constrain the plan (summary)

1. **Blind windows follow the trading-day model**, not "Friday 16:00 -> Monday 09:30"; weeknight overnight is not blind for 24/5 feeds. `UsMarketCalendar.blindWindow` must be defined on the 24/5 trading-day rule (verified on two holidays). Early-close behavior is unverified.
2. **Heartbeat staleness is useless as a closure detector** (24 h heartbeat, 0.5 % deviation; liquid-name gaps of hours during open sessions). Need session-aware freshness logic.
3. **Stock tokens carry issuer controls** (global pause, per-address blocklist, `adminBurn`, beacon-upgradeable). These are first-class threat-model items and need `Sim*` hooks in tests.
4. **Only 32 of 194 tokens have a Chainlink feed**; scope the market to feed-backed tokens (start with 4-6 liquid names).
5. **No sequencer uptime feed on Robinhood Chain** -> optional/configurable.
6. **Testnet cannot validate the production oracle path**; fork tests against mainnet are the only real-feed evidence. The public RPC is non-archive: fork tests run at the latest block, unpinned, and are optional/skipped without RPC env (decision D4); an archive key is used only if present.
7. **USDG has 6 decimals** vs 18 (token) vs 8 (feed): decimals normalization is a core correctness surface.
8. **Mainnet token source is now verified** (Sourcify): the issuer controls (global pause, blocklist, `adminBurn`, beacon upgrade) exist on mainnet exactly as on testnet and every privileged role is held by an EOA.
9. **Exit liquidity is the binding constraint on market size** (about $0.9M of collateral across TSLA/NVDA/AAPL/SPY at a 3 % exit): section g.

## Open actions for the user

1. ~~Paste the mainnet token source~~ - resolved via Sourcify (section b).
2. Start Docker Desktop + enable WSL integration only if you want the Stylus devnode check (deferred; blocks nothing).
3. If you can: Aave governance/LlamaRisk primary document for the Base Equities Hub parameters (still secondary-source).
4. ~~Archive RPC key~~ - not required (D4).
