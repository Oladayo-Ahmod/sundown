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

### Transfer restrictions that affect a lending market (important)

Source for the logic: the **testnet** implementation `Stock` (`0xBd14156E05c6AF28ad39aA53a2AB8eB9CDf657DA`, verified source on the testnet explorer, solc 0.8.33):

- `transfer`, `transferFrom`, `approve`, `permit`, `mint`, `burn` all revert if the token is **paused** (`IsPaused`) or if **any of `from`, `to`, `msg.sender`** is **blocked** in an external `AccessControlsRegistry`. -> *A blocked or paused state can make liquidation transfers revert, including transfers to/from the lending market contract or a liquidator.*
- `paused()` = token flag OR registry-wide pause flag. One registry pause freezes all tokens.
- `adminBurn(address from, uint256 amount)` guarded by `ADMIN_BURNER_ROLE` can burn from **any** address, with no balance/allowance condition -> *the issuer can burn collateral held by the lending market.*
- Tokens are **beacon proxies** (EIP-1967 beacon slot). On mainnet the beacon slot of AAPL/NVDA points to `0xe10b6f6B275de231345c20D14Ab812db62151b00`, which is **also** the `ACCESS_CONTROLLED_REGISTRY()` (verified-onchain). It returns `implementation() = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` (verified-onchain). So **one contract controls the implementation, the global pause and the blocklist for all 194 tokens**.
- Mainnet live state (verified-onchain): registry `paused() == false`, `tokenPaused() == false` for AAPL/NVDA/TSLA/MSFT/SPY/QQQ/GOOGL; the registry does **not** block Morpho Blue `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` nor `0xdEaD`.
- **Unverified:** the mainnet implementation source (Blockscout returns 403 to automation). The mainnet bytecode contains `mint`, `burn(address,uint256)`, `pause/unpause`, `hasRole`, `permit`, `uiMultiplier` family, `oraclePaused/pauseOracle/unpauseOracle`, `uid` selectors (verified-onchain selector scan), but I did not confirm that blocklist/pause gating in `transfer` is identical to the testnet code or that `adminBurn` exists on mainnet. **ACTION FOR YOU:** open `https://robinhoodchain.blockscout.com/address/0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2?tab=contract` and `.../0xe10b6f6B275de231345c20D14Ab812db62151b00?tab=contract`, paste the verified source (or at least the function list and the `_update`/`transfer` modifiers) so I can close this.

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

---

## Findings that change or constrain the plan (summary)

1. **Blind windows follow the trading-day model**, not "Friday 16:00 -> Monday 09:30"; weeknight overnight is not blind for 24/5 feeds. `UsMarketCalendar.blindWindow` must be defined on the 24/5 trading-day rule (verified on two holidays). Early-close behavior is unverified.
2. **Heartbeat staleness is useless as a closure detector** (24 h heartbeat, 0.5 % deviation; liquid-name gaps of hours during open sessions). Need session-aware freshness logic.
3. **Stock tokens carry issuer controls** (global pause, per-address blocklist, `adminBurn`, beacon-upgradeable). These are first-class threat-model items and need `Sim*` hooks in tests.
4. **Only 32 of 194 tokens have a Chainlink feed**; scope the market to feed-backed tokens (start with 4-6 liquid names).
5. **No sequencer uptime feed on Robinhood Chain** -> optional/configurable.
6. **Testnet cannot validate the production oracle path**; fork tests against mainnet are the only real-feed evidence. Chain-level RPC is non-archive so fork tests need an archive provider (Alchemy) for historical blocks.
7. **USDG has 6 decimals** vs 18 (token) vs 8 (feed): decimals normalization is a core correctness surface.
8. Public RPC / Blockscout automation limits mean some evidence requires you to paste data (see actions above).

## Open actions for the user

1. Paste the verified source (or function list + transfer modifiers) for mainnet implementation `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` and registry/beacon `0xe10b6f6B275de231345c20D14Ab812db62151b00` from Blockscout (403 for automation).
2. Start Docker Desktop + enable WSL integration if you want the nitro-devnode check; otherwise Stylus remains unverified on-chain.
3. If you can: Aave governance/LlamaRisk primary document for the Base Equities Hub parameters.
4. An archive RPC key (Alchemy) for fork tests (later milestones).
