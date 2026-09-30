# Sundown M0 - Design Proposal

Status: **proposal, not implemented**. Every claim about the outside world is tagged **[V]** verified (see `DISCOVERY.md`), **[D]** documented by a primary vendor but not independently checked, or **[U]** unverified. Sections marked **CHANGE** deviate from the original brief because discovery contradicted or refined it and need your approval before M1.

## 1. Thesis and scope

Tokenized-stock collateral is priced by a 24/5 oracle that **goes blind over weekends and holidays** and reopens with a gap. Static LTV/LLTV (Aave, Morpho) prices that risk once, forever. Sundown makes the risk **session-aware**: borrow capacity tightens before a blind window, and liquidation after the gap is shaped around the thin, noisy reopen. The design is an isolated market with a pluggable `IRiskGuard`, so a **control market (FlatGuard)** and a **treatment market (SundownGuard)** differ *only* by the guard and can be replayed against the same price path.

**Evidence-first framing (D6, after the M2/M2.1 research in `research/CLAIMS.md`).** The measured benefit of the stress rule is *capacity expansion at counterfactual high LLTV*, not protection at conventional LLTV: at real flat LLTVs (<= 86 %) window-gap bad debt is negligible (0 at <= 65 %, 4.5 bps/yr at 86 %) and the rule is not distinguishable from zero. At counterfactual 93 % it buys about +2.6 pp of LTV at equal bad debt (CI [0.9, 4.1], mostly TSLA/NVDA). Sundown does not claim to be safer than Aave/Morpho, and every claim in the product and the UI must trace to a row of `CLAIMS.md`.

Non-goals: a general lending protocol, a price oracle, a DEX, upgradeability of core accounting, governance tokens, a premium-funded gap reserve (claim 13: not supported).

## 2. Architecture and trust boundaries

```
                 +-----------------------------+
 users/keepers ->|        SundownMarket        |<- admin: Timelock (params), Guardian (risk-reducing only)
                 | ERC-4626 vault + positions  |
                 +--+-----------+-----------+--+
                    |           |           |
              IRiskGuard   IEquityOracle   IRateModel (kinked)
             /          \        |
        FlatGuard   SundownGuard |
                         |   \   |
              GapRiskModel  UsMarketCalendar (pure library)
                                 |
                    ChainlinkEquityOracle  |  SimEquityFeed (sim only)
                                 |
              Chainlink AggregatorV3 proxy, token (uiMultiplier/oraclePaused), optional sequencer feed
```

Trust boundaries (what can lie / fail):

| Boundary | Trusted for | Not trusted for |
|---|---|---|
| Chainlink feed | price level, `updatedAt` | liveness (24 h heartbeat), sanity in thin sessions (may print 0), closure detection |
| Stock token (issuer) | ERC-20 semantics when not paused/blocked | availability: global pause, blocklist, `adminBurn`, beacon upgrade [V testnet source, U mainnet source] |
| Calendar library | the schedule only | ad-hoc closures (override by timelock), early-close behaviour of feeds [U] |
| Guard | policy | accounting; the market enforces solvency independent of the guard (the guard can only *restrict*) |
| Keepers/snapshotters | nothing: all permissionless entry points are replay-protected and bounded | |

Key rule: **the market, not the guard, owns accounting invariants.** A malicious/buggy guard can freeze borrowing but must never be able to create bad debt, mint shares or move funds.

## 3. Components

### 3.1 UsMarketCalendar (library, pure) - **CHANGE: trading-day blind-window model**

Pure, DST-aware America/New_York via closed-form UTC arithmetic (no table), 2020-2040, NYSE holidays by rule with observed-day logic, Easter (Anonymous Gregorian) for Good Friday, early closes, plus an owner/timelock-updatable ad-hoc closure bitmap (add-only for dates whose window has been announced).

Discovery changed the **blind-window definition** [V]: measured on Robinhood mainnet around Labor Day (Mon 2026-09-07) and Independence Day observed (Fri 2026-07-03), both feeds resumed at exactly 20:00 ET on the evening that opens the next *open* trading day. Rule:

> A trading day T opens at **20:00 ET on the previous calendar day** and closes at **20:00 ET on T**. Weekends and NYSE holidays are closed trading days. The oracle is *blind* over the maximal run of closed trading days: `[close of last open trading day, open of next open trading day]`.

Examples (ET): weekend Fri 20:00 -> Sun 20:00; Labor Day Fri 20:00 -> **Mon** 20:00; July 3 holiday Thu 20:00 -> Sun 20:00.

Session mapping, side by side (ET; our enum | Chainlink Data Streams `marketStatus` [D]):

| Our `Session` | Hours | `marketStatus` |
|---|---|---|
| Overnight (belongs to an open trading day) | 20:00-04:00 | 4 Overnight |
| PreMarket | 04:00-09:30 | 1 |
| Regular | 09:30-16:00 (13:00 on early close [U for feed]) | 2 |
| PostMarket | 16:00-20:00 | 3 |
| WeekendClosed | closed trading day that is Sat/Sun | 5 Closed |
| HolidayClosed | closed trading day that is an NYSE holiday / ad-hoc closure | 5 Closed |

`marketStatus` is **only in Data Streams reports, not in the push AggregatorV3 feed** [D], so on-chain session knowledge comes from this calendar. Halts are not in `marketStatus` [D].

**`WindowClass` (accepted, D1)**: the original `{Overnight, Weekend, LongWeekend}` assumed weeknight overnight is blind. For the 24/5 feed it is **not** (thin session, the feed can update). For consecutive trading days D1 < D2 the blind window is `[20:00 ET on D1, 20:00 ET on (D2 - 1 calendar day))`; consecutive weekdays give a zero-length window (no blindness). Class is by closed calendar days `n = D2 - D1 - 1`, **not by hours** (DST makes weekends 47 h or 49 h): `n=1` Short (mid-week holiday), `n=2` Weekend, `n>=3` Long (holiday weekends, Good Friday). A non-blind "thin overnight" risk is handled by the guard via a session haircut, not via blind windows. Verified only on post-launch history (see 8, D1 caveat).

**Blind-window start is a schedule bound, not the last price time** [V]: updates are deviation-triggered (0.5 %) with 24 h heartbeat; the last pre-closure update was hours before 20:00 ET (AAPL Fri 15:51 ET; NVDA 13:46 ET). `blindWindowAt(ts)` / `nextBlindWindow(ts)` return the *scheduled* interval; consumers anchor risk on the oracle's actual `updatedAt`. `windowId(ts)`: monotone id = a counter of closed-runs since a fixed epoch, computed in O(1) from the trading-day index.

Early-close days (13:00): **assumed to NOT move blind-window boundaries** (extended sessions still run to 20:00 ET). **UNVERIFIED**; implemented as a single config constant so it can be flipped (accepted, D1). First real tests: 2026-11-27, 2026-12-24. The API is `blindWindowAt` / `nextBlindWindow` / `windowId` / `isBlind` / `secondsUntilBlind`; `sessionAt` is display-only and must never feed risk logic.

### 3.2 GapRiskModel

Observations are **gap returns** r = ln(P_open / P_lastBeforeWindow) in bps, per `WindowClass`.

- **Estimator (binding, D7; supersedes the earlier ring-buffer/quantile blend)**: pooled-scaled EWMA, lambda 0.9. One `(num, den)` pair per asset: `num' = lambda*num + (loss/k_c)^2`, `den' = lambda*den + 1`, `sigma2 = num/den`; `gapVaR_c = multiplier_c * z_q * k_c * sqrt(sigma2)`, rounded up, class multipliers floored at 1, `K_MIN = 8` observations before the data-driven estimate replaces the seed. Class scales `k = {Short 0.76, Weekend 1, Long 0.92}`; **Short uses Weekend parameters** (41 windows per asset is too few). Quantile **q = 99.5 %** (the 99 % VaR realised ~98 % coverage out of sample; claim 5), **oracle buffer 50 bps**, safety buffer 100 bps. State is O(1) per asset: no ring buffer, no sorting. The integer/WAD reference is in `research/estimators.py`; seeds and bounds are in `deployments/risk_params.json` (a research artifact, not governance-approved).
- Stress rule: `maxBorrowLTV = min(LLTV, 1 - gapVaR_q - oracleBuffer - safetyBuffer)`, lookahead 24 h before a window.
- Honest limits (claims 5, 6): the estimator under-covers mega-caps (AAPL/GOOGL exceedance ~2.8-3.0 %) and over-covers high-vol names; no estimator forecasts regime breaks (Mar-2020: 24 % exceedance). Do not describe the VaR as calibrated at 99 %.
- Recording is permissionless and two-phase with replay protection per `windowId`: (1) `snapshotPre(windowId)` callable only inside the blind window, captures the oracle's frozen last price; (2) `recordGap(windowId)` callable after the window ends, once the oracle has produced a post-window update (`updatedAt >= windowEnd`, bounded delay), computes r. Exactly one write per `(asset, windowId)`. **Lag-capped recording (D7/N2)**: the post-window observation is the first update with `updatedAt >= windowEnd`; its **lag is stored**; an observation whose lag exceeds the cap (12 h, covering ~99 % in simulation) is **skipped, never imputed**. M1 measured a lag of 18-85 s in all 84 (window, feed) pairs, so censoring was not observed, but recording must still store the lag. Because early-close behavior is unverified (D10), recording must tolerate either window boundary.
- Data: the on-chain feed history starts 2026-06-22, so cold-start priors come from `research/` (2010-2026 equity history, daily proxy) and are labelled as offline analysis.

### 3.3 Oracle layer

- `IEquityOracle.read(asset) -> (priceWad, updatedAt, Status)` where `Status` is `Fresh | ScheduledBlind | Stale | Invalid | CorporateActionPending`.
- `ChainlinkEquityOracle` (production path; claim "integrated" only after a mainnet fork test): reads `latestRoundData()`; requires `answer > 0`, `updatedAt != 0`, `updatedAt <= block.timestamp`, per-asset absolute min/max bounds (guards the zero/atypical thin-session prints [D]); normalizes `decimals()` (never hardcoded; 8 on all observed feeds [V]); handles loan-token decimals (USDG 6 dp [V]); reads token `oraclePaused()` and `uiMultiplier()/newUIMultiplier()/effectiveAt()` to flag corporate actions [V on mainnet AAPL/NVDA/TSLA/SPY]; optional sequencer feed with grace period.
- **CHANGE (freshness)**: heartbeat staleness cannot detect closure [V]: 24 h heartbeat and quiet liquid names show 1-4 h ages in open sessions (SPY 4.4 h during regular hours). `Stale` is therefore defined as `age > maxAge` with `maxAge = heartbeat + grace` **only when the calendar says Live**; inside a scheduled blind window the status is `ScheduledBlind` regardless of age. Between them the guard applies an **age haircut** (monotone in age) rather than a binary cut-off. Parameters per asset, set by timelock.
- **CHANGE (sequencer)**: Chainlink lists no uptime feed for Robinhood Chain [D]; the sequencer feed is an **optional** constructor argument (Arbitrum One has one [V]). Robinhood Chain deployments run without it, compensated by a conservative grace window after any detected L2 block-time discontinuity [U design].
- Loan-token price: USDG is **exactly 1 USD by explicit, documented assumption** (accepted, D3). No loan-token oracle is built; the guardian can halt on a depeg. Documented in the threat model and README.
- **Freshness (binding note N1)**: outside blind windows age alone cannot signal trouble (24 h heartbeat). The adapter treats the 0.5 % deviation as an irreducible price-error allowance, adds an age-based haircut, and distinguishes *scheduled* blindness (calendar) from *unscheduled* blindness (outage).
- **Sequencer (N3)**: optional config; downtime is modeled as unscheduled blindness. Arbitrum One keeps the Chainlink sequencer feed.
- **Eligible collateral (N4)**: only the 32 tokens with a Chainlink feed.
- **Censored observations (N2)**: the first update after a window may be late if the price moved less than the 0.5 % threshold. `recordPostWindow` (M4 design) must handle this and record the lag; M2 must quantify the effect.
- `SimEquityFeed` (test fixture, `contracts/test/mocks`): AggregatorV3-shaped, replays deviation-triggered updates and blind windows per the measured behavior. Named `Sim*`, never used in deployment config for Robinhood mainnet.

### 3.4 SundownMarket (isolated, one collateral, one loan token)

- Supply side: ERC-4626 vault over the loan token with **virtual shares/assets offset** (OZ `_decimalsOffset`) against inflation attacks; share price changes only by interest and explicit bad-debt realization.
- Borrow side: per-account `collateral`, `borrowShares`; global `totalBorrowAssets`; kinked rate model (base, slope1, kink, slope2) accruing by `block.timestamp` delta; interest rounds up for borrowers, down for suppliers.
- Liquidation: partial, bounded close factor; seized collateral = `repaid * (1 + bonus) / price`, rounding in the protocol's favor; liquidator must be able to receive collateral (see transfer-restriction handling).
- **Bad debt**: when `collateral == 0 && debt > 0` after liquidation, anyone can call `realizeBadDebt(account)`: debt removed from `totalBorrowAssets` and from `totalSupplyAssets`, event emitted (explicit socialization to suppliers; no silent rounding).
- Caps: supply cap, borrow cap and a **per-market collateral cap derived from measured exit liquidity** (D9; table in `DISCOVERY.md`; mirrors Aave's capped rollout, LlamaRisk $32M/$21M [S]).
- **Loss-absorbing reserve: extension point only** (D8; claim 13/13b: a premium-funded reserve cannot self-start; it would need external seeding of >= ~2 % of debt at 86 %, >= ~7 % at 93 %). Not built.
- **Issuer-control failure policy (accepted, D2) [V testnet, U mainnet]**: HALT + FREEZE ACCRUAL.
  - Detection is permissionless and testable: `reportIssuerFailure()` probes the collateral token (pause state if exposed, otherwise a guarded 1-wei transfer probe in try/catch) and the loan token; the guardian can also halt.
  - While halted: no new borrows, no collateral withdrawals, no new supply; interest accrual is frozen (borrowers are not charged for something they cannot fix); repay and loan-token withdrawals stay open if the token permits; liquidation is disabled only while the token actually reverts.
  - Resumption is explicit and evented. A maximum freeze duration applies, after which the timelock must act; what lenders can and cannot recover is documented.
  - `adminBurn` and blocklisting are **not mitigable on-chain**: residual risk in `THREAT_MODEL.md`, disclosed in the UI, bounded only by per-market collateral caps.

### 3.5 IRiskGuard and the control/treatment pair

```solidity
interface IRiskGuard {
    function borrowCapacity(address account, MarketView calldata m, Quote calldata q) external view returns (uint256 maxBorrow);
    function canWithdrawCollateral(address account, uint256 amount, MarketView calldata m, Quote calldata q) external view returns (bool);
    function liquidationTerms(address account, MarketView calldata m, Quote calldata q) external view returns (LiquidationTerms memory); // {allowed, bonusBps, closeFactorBps}
}
```

*(Interface superseded by `docs/MARKET_DESIGN.md`, which takes account-level context so a standard/boosted tier can live in the guard.)* **Enforcement finding (D8, claims 11-12):** a cap on new borrows/withdrawals alone has *no effect* on bad debt, a priced gap premium is rejected, and the only effective candidate is **hard pre-window deleveraging of existing debt with a cure window**, offered as an **opt-in boosted tier**; at >= 93 % it is heavy in event frequency (about 19 forced events per 100 borrowers per year uniform, 80 clustered). Final decision in M4a after M2.2. Hooks are `view` where possible; permissionless recording lives on the guard/risk model, not in the market. The guard may restrict but never relax the market's hard solvency checks.

- **FlatGuard (control)**: static LTV/LLT, fixed bonus, fixed close factor - an Aave-style parameterization. Revert in blind/stale states mirrors what a standard market does with its oracle (still liquidates on frozen price) - kept *identical* to the control semantics so the comparison is honest.
- **SundownGuard (treatment)**:
  1. *Pre-window tightening*: within lookahead `H` before `windowStart` and during the window, `maxBorrow = collateralValue * (1 - gapVaR(class)) * LLTV_base` (stress health factor >= 1 against the upcoming window's gap-VaR); collateral withdrawal likewise.
  2. *Post-gap settling window* of length `S` after the first fresh post-window price: bonus ramps linearly `bonusMin -> bonusMax` over `S` to give borrowers a cure period and avoid a feeding frenzy on thin reopen liquidity, with a **deep-insolvency override** (`HF < hfDeep`): immediate `bonusMax`, no ramp, so lenders are protected. *This is a hypothesis; the replay must compare bad-debt and borrower-loss outcomes against FlatGuard before we claim a benefit.*
  3. *Unscheduled blindness*: `Stale | Invalid | CorporateActionPending` => halt-like (no new borrow, no collateral withdrawal; liquidation only via deep-insolvency path against a valid last price or paused entirely - pick in 8).
  4. *Permissionless record/snapshot* entry points with per-`windowId` replay protection, gas bounded.

Because both markets run the same `SundownMarket` bytecode, the same oracle sim and the same IRM parameters, the replay isolates the guard.

## 4. Assumptions (each tagged)

| # | Assumption | Tag |
|---|---|---|
| A1 | Robinhood mainnet id 4663 / testnet 46630, public RPC reachable | [V] |
| A2 | Robinhood stock tokens: 18 dp ERC-20, 194 active, canonical addresses from registry | [V] |
| A3 | Chainlink push AggregatorV3 feeds, 8 dp, 24 h heartbeat, 0.5 % deviation on Robinhood mainnet, covering 32 of 194 tokens | [V] (page data + live reads) |
| A4 | Feeds are blind Fri 20:00 ET -> Sun 20:00 ET and across NYSE holidays per the trading-day rule | [V] two holidays; early closes [U] |
| A5 | No `marketStatus` onchain for push feeds | [D] |
| A6 | No sequencer uptime feed on Robinhood Chain | [D]; non-existence not provable on-chain [U] |
| A7 | Cancun opcodes available on target chains | [V] |
| A8 | Stock token transfers can revert for pause/blocklist; `adminBurn` exists; tokens are beacon-upgradeable | testnet source [V]; mainnet [U] |
| A9 | Anyone can hold and liquidate on-chain; the issuer does not block lending markets (Morpho Blue not blocked today) | [V] today; future policy [U] |
| A10 | Mint/burn window Mon 02:00 -> Sat 02:00 CET limits arbitrage/redemption of liquidated collateral | [D]; effect on liquidator PnL [U] |
| A11 | Enough on-chain liquidity to liquidate stock tokens at the sizes we cap | [U] (thin liquidity risk; RFQ-first venue) |
| A12 | USDG is a $1 loan asset; 6 dp | dp [V]; peg treatment [U] |
| A13 | Foundry deploy + Blockscout verify works on Robinhood chain | [D], not exercised [U] |
| A14 | Stylus runs on these chains | ArbWasm answers [V]; activation/gas [U] |
| A15 | Fork tests against Robinhood mainnet need an archive RPC | [V] public RPC is non-archive |
| A16 | 20:00 ET open is the same instant (DST-aware) for feed and calendar | [V] two observations in EDT; EST [U] (first test: after 2026-11-01) |
| A17 | Equity data for the gap-VaR prior comes from `research/` and is offline analysis, not oracle data | design choice |
| A18 | Aave/Morpho parameters in `DISCOVERY.md` | Morpho [V api], Aave [S] |

## 5. Invariants (to be encoded as Foundry invariants/properties)

Token conservation
- I1 `loanToken.balanceOf(market) >= totalSupplyAssets - totalBorrowAssets - (realized bad debt not yet reflected)` (never lends out more than exists).
- I2 `sum(collateral[a]) == collateralToken.balanceOf(market)` minus donations (`>=`), donations never credited to anyone.
- I3 Sum of borrow shares == `totalBorrowShares`; sum of supply shares == vault `totalSupply`.

Accounting
- I4 `totalBorrowAssets` only changes by borrow, repay, accrue, liquidate, `realizeBadDebt`.
- I5 Accrual is monotone in time and never decreases `totalBorrowAssets`.
- I6 Bad debt realization decreases `totalSupplyAssets` exactly by the written-off amount; `badDebtRealized` accumulator equals the sum of events.

Guard enforcement
- I7 `borrow` never leaves an account above `min(marketLLTV, guardCapacity)`; the guard can only tighten.
- I8 No guard can increase an account's debt, move funds, or alter shares.
- I9 FlatGuard and SundownGuard markets with identical state/oracle produce identical results outside restricted states (differential property).

Calendar partition
- I10 For all `ts` in [2020, 2040] exactly one `Session`; sessions partition time.
- I11 `windowId` is monotone non-decreasing; `ts` within a blind window => `blindWindow(ts)` contains `ts`.
- I12 `nextRegularOpen(ts) > ts` and `sessionAt(nextRegularOpen(ts)) == Regular`.
- I13 Ad-hoc closure update cannot shorten or remove an already announced window.

ERC-4626
- I14 Share price (`totalAssets/totalSupply`) is non-decreasing except through `realizeBadDebt`.
- I15 First-depositor/donation cannot steal from later depositors: for any donation `d` and deposit `x` the depositor receives at least `x - 1` assets value on redeem (virtual shares).
- I16 Rounding: deposit/mint round against the depositor, redeem/withdraw against the redeemer.

Risk model
- I17 `recordGap` writes at most once per `(asset, windowId)`.
- I18 Gap-VaR is bounded `[floor, cap]` and monotone in the observed worst loss (with bounded changes per observation).

## 6. Threat model outline

| Area | Threat | Planned mitigation / test |
|---|---|---|
| Oracle staleness | Heartbeat 24 h; quiet names appear stale; attacker borrows against old price during Live | age haircut + `maxAge` only in Live; fuzz with `SimEquityFeed` |
| Atypical prints | zero/outlier value with fresh timestamp in thin sessions [D] | absolute bounds + jump guard that tolerates open-gap via the settling logic; tests with zero/outlier |
| Corporate action | multiplier change/pause, splits | `oraclePaused()` + `newUIMultiplier()/effectiveAt()` => `CorporateActionPending` halt |
| Sequencer downtime | stale feeds after outage; unfair liquidation on resume | optional sequencer feed + grace; where absent, post-discontinuity grace [U] |
| Snapshot manipulation | choose when to snapshot; poison the VaR with a bad observation | one write per window id, snapshot only inside blind window (price frozen), post record requires fresh post-window update and bounded delay, VaR bounded, rate-limited influence |
| Donation/inflation | ERC-4626 share inflation, collateral donation | virtual shares offset; collateral accounting by internal ledger, not balances |
| Liquidation griefing | dust positions, close-factor games, front-running the cure window, sandwiching | min liquidation size, bounded close factor, bonus accounting caps, no oracle-update-dependent ordering inside our control |
| Mint/burn window & basis risk | issuer redemption closed Sat 02:00 -> Mon 02:00 CET; DeFi price of token vs feed (multiplier drift, `shared-svr` OEV) | cap exposure, liquidator-liquidity haircut in bonus ceiling, replay with basis shocks |
| Thin liquidation liquidity | RFQ-first venue, gap down, no exit for seized tokens | caps scaled to measured depth [U], deep-insolvency bonus ceiling, bad-debt realization path |
| Issuer controls | pause/blocklist can lock collateral; `adminBurn` can burn the market's collateral; beacon upgrade can change token logic [V testnet] | `collateralFrozen` mode, caps, lender disclosure, tests with `SimStockToken` hooks; accepted residual risk to be disclosed, not "mitigated" |
| Admin/guardian | param abuse, closure abuse | timelock with delay for all risk-increasing changes; guardian only risk-reducing and time-bounded; calendar closures add-only |
| Calendar bugs | DST, observed-holiday errors, early closes | differential tests vs independent Python implementation (`exchange_calendars` + `zoneinfo`), fuzz properties |
| Decimals | 18/8/6 mixes | decimals read at deploy, property tests across decimals |
| Supply-chain | Chainlink Terms/permission: Chainlink asks integrators to contact them before use [D] | disclose; no claim of Chainlink endorsement |

## 7. Milestone plan (total budget ~40 h; M0 consumed outside the 40)

| M | Scope | Est. | Exit evidence |
|---|---|---|---|
| M1 | `UsMarketCalendar` + wrapper for ad-hoc closures, trading-day blind-window model, differential fixtures vs Python | 5 h | 100 % line / >95 % branch, 20k random cases, named DST/holiday tests, gas per function |
| M2 | `GapRiskModel` + offline research calibration (`research/`), packed ring buffer, record/snapshot flow | 5 h | unit/fuzz, EWMA/quantile vs Python reference, gas |
| M3 | `IEquityOracle`, `ChainlinkEquityOracle`, `SimEquityFeed`, `SimStockToken`, sequencer-optional logic | 4 h | **mainnet fork test against real feeds** (needs archive/RPC) -> only then "integrated" |
| M4 | `SundownMarket` core (4626, IRM, borrow, liquidation, bad debt) with FlatGuard | 7 h | invariants I1-I6, I14-I16, fuzz, gas snapshot |
| M5 | `SundownGuard` + control/treatment harness | 5 h | I7-I9, I17-I18, behavior tests |
| M6 | Adversarial/invariant campaign (+ fizz/echidna if time), threat-model walkthrough | 4 h | invariant runs, slither clean-or-triaged |
| M7 | `sim/` replay (weekend gaps, thin liquidity) + `web/` (Next.js 15) | 6 h | reproducible replay report, dashboard |
| M8 | Robinhood testnet deployment + verification, deployments JSON | 2 h | verified contracts, README with real addresses |
| M9 | Hardening, docs, demo script, final audit pass | 2 h | handoff |

### Stylus go/no-go criterion (decide at end of M2)

Default **NO-GO**. GO only if **all** hold: (1) `cargo stylus check`/deploy is verified on a devnode or private RPC on the target chain (currently **unverified**: both public RPCs reject the check); (2) a Solidity reference implementation exists and the Stylus version is **bit-identical** under differential fuzz; (3) a *measured* benefit that matters (e.g. the 64-element quantile record function exceeds a practical gas budget or is >= 5x cheaper) rather than novelty; (4) no new trust assumption, no extra admin power; (5) the time to integrate is <= 3 h with M3-M9 unaffected. If any fails, ship Solidity and document the Stylus experiment as research.

## 8. Accepted decisions

Accepted by the owner after the M0 handoff.

**D1 - Blind-window rule and classes: APPROVED.**
- A trading day D opens at 20:00 ET on the calendar day before D and closes at 20:00 ET on D. Weekends and NYSE holidays are closed trading days.
- For consecutive trading days D1 < D2 the blind window is `[20:00 ET on D1, 20:00 ET on (D2 - 1 calendar day))`. Consecutive weekdays give a zero-length window.
- Class by closed calendar days `n = D2 - D1 - 1`: n=1 Short, n=2 Weekend, n>=3 Long. By calendar-day count, **not hours** (weekends are 47 h / 49 h across DST).
- Caveat: verified only on post-launch history (Robinhood mainnet launched 2026-07-01: two holidays plus ~13 weekends). M1 adds an empirical feed-consistency test.
- Early-close days: assume **no** change to window boundaries. **UNVERIFIED**; one-line config constant.

**D2 - Issuer-control failure: HALT + FREEZE ACCRUAL**, with the refinements in 3.4.

**D3 - USDG = exactly 1 USD** (explicit assumption, no loan-token feed; guardian halt on depeg; documented in threat model and README).

**D4 - No archive RPC required.** Fork tests run against public RPCs at the latest block (unpinned) and are optional/skipped when no RPC env is set. Historical evidence comes from `Sim*` replays and research data. An archive key in `.env` is used opportunistically.

**D5 - Collateral set.** Research universe: AAPL, NVDA, TSLA, SPY, QQQ, MSFT plus ~6 more large caps. Deployed markets: a subset of 4 (target TSLA, NVDA, AAPL, SPY) that **must** be among the 32 feed-backed tokens and have meaningful on-chain liquidity; exit-liquidity depth is to be recorded in `DISCOVERY.md` (not yet done).

**Deferred.** Stylus (M8) stays optional and blocks nothing; no Docker/devnode work now.

**Still open (owner).** Mainnet token source for `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` and `0xe10b6f6B275de231345c20D14Ab812db62151b00` to be pasted; not blocking M1/M2, **needed before M3**.

**D6 - Framing: evidence-first, rigorous, replayable.** Capacity-expansion claims apply only to counterfactual 90-95 % LLTV (about +2.6 pp at 93 %, CI [0.9, 4.1], mostly TSLA/NVDA). At real LLTVs <= 86 % the gap rule is not distinguishable from zero, and we say so. D1's verification coverage is stated exactly as `CALENDAR_NOTES.md` section 11: **12 weekends + 2 Long holiday windows; no EST, no Short, no early-close observations.**

**D7 - Binding research findings.** q = 99.5 % (or a wider buffer); 50 bps oracle buffer; lag-capped observation recording (store the lag, skip over the cap, never impute); calendar-aware freshness. M1 measured a first-update lag of 18-85 s after window end, so N2 censoring was not observed, but recording must still store the lag.

**D8 - Enforcement.** A cap on new borrows alone is useless; a priced premium is rejected; the only candidate is hard pre-window deleveraging with a cure window, as an opt-in boosted tier. Final decision in M4a after the M2.2 results (not started).

**D9 - Liquidation design and exit liquidity are first-class.** Per-market collateral caps derived from pool depth; Dutch-ramp bonus and depth-sized partial liquidations are being evaluated in M2.2.

**D10 - Early-close days.** Until observed, the guard treats window boundaries conservatively (capacity tightening may start earlier than 20:00 ET on early-close days; observation recording tolerates either behavior). Flag for M4a; no change to the calendar library.

**D11 - Hot paths.** Cache window bounds and `windowId` at guard level (keyed by `windowId`); do not call `secondsUntilBlind` or `nextBlindWindow` per user action.

**D12 - Market design approvals (MARKET_DESIGN section 17).** A1 yes: `openzeppelin-contracts-upgradeable` v5.7.0, clone-safe ERC-4626 only. A2 yes: market and vault are one contract. A3 yes: factory creation is owner-only. A4 yes, with the **guard address immutable per market** (trust is fixed at creation); the guard is bounded by the market's bonus cap, close factor and non-worsening rule. A6 yes: immutable collateral cap in token units. A7, A8, A10, A12: recommended defaults (market passes `haircutWad` and uses the raw price for seizure; shared `WindowCache`; no fee/reserve; `minDebt` and `closeFactor` 50 % / `criticalHealth` 0.95).

**D13 - Collateral shortfall: option B plus halt (A5).** No `collateralScale` index (complexity and bug risk; no issuer action observed since launch). The issuer-failure probe also detects shortfall (`collateral.balanceOf(market)` below the ledger total) and puts the market into a Halted state that lasts until resolved: no new borrows, withdrawals or supply; liquidations simply revert if the token reverts; repay stays open. Phantom collateral after an `adminBurn` is a documented residual risk (THREAT_MODEL.md, UI). **No resolution mechanism in v1.**

**D14 - Freeze limit (A9).** 30 days: accrual is frozen for the first 30 days of a halt; after that **accrual resumes by itself while the halt persists** until the guardian (probes passing) or governance (timelock) resumes. **No `windDown()` in v1**; the gap is documented (a permanently reverting token leaves collateral-backed loans unrecoverable).

**D15 - Scope cuts and deployment (A11).** No Dutch-ramp bonus, no depth-sized partial liquidation, no empirical-quantile estimator, no Stylus. Liquidation bonus is **flat and configurable within [3 %, 5.5 %], default 4 %**; nothing below 3 % ships without live keeper evidence. Deploy all four markets (SPY, NVDA, AAPL, TSLA) at **demonstration scale on Arbitrum Sepolia with `SimEquityFeed`** (labeled simulation). The exit-liquidity table is published as the **recommended production caps**; no production-scale liquidity claim except NVDA. Any Robinhood Chain use is a read-only validation of the Chainlink adapter against live feeds.

**D16 - Boosted tier.** Configured in the guard per market, for SPY (90 % and 93 %) and AAPL (90 %) only; TSLA and NVDA standard tier only. M4a details it.

**D17 - Execution budget for 3b.** 3b-1 core <= 6 h, 3b-2 oracle <= 3 h (fork test optional, skipped if it costs > 30 min), 3b-3 hardening <= 4 h. Proceed between steps without waiting only if all validations pass and nothing deviates from `MARKET_DESIGN.md`; stop on any deviation, failed validation or direction-changing discovery; report after every step. 3b-3 invariant priority: collateral conservation, vault accounting identity, debts <= totalBorrow, no borrow above guard capacity, liquidation never worsens a position, share price never falls except via `BadDebtRealized`, repay never blockable, halt semantics; any others cut are named in the report.

**D18 - No onchain observation pipeline or EWMA in v1.** GapVaR is a per-asset, per-window-class (Short/Weekend/Long) WAD parameter taken from `deployments/risk_params.json` at q = 99.5 %, settable only through the timelock within hard bounds. The EWMA estimator is documented as roadmap; the integer reference stays offchain and tested.

**D19 - `SundownGuard`.** Replaces `FlatGuard`'s role for boosted markets (`FlatGuard` stays as the control). Per-market parameters: `standardLLTV`, `boostedLLTV` (0 = no boosted tier), `gapVaR[3]`, `oracleBuffer` (50 bps), `safetyBuffer`, flat liquidation bonus in [3 %, 5.5 %] (default 4 %), `deleverageFee` (1 %, <= bonus cap), `preWindowHorizon` (default 6 h), `cureWindow` (default 3 h); all with onchain bounds and timelock-delayed changes. Hot paths read window bounds and `windowId` through `WindowCache` (D11); no per-action calendar scans.

**D20 - Boosted tier entry.** Per-account opt-in via `enterBoosted()`; not allowed during the pre-window horizon or a blind window; exit allowed anytime if the position fits the standard tier. Eligible markets: SPY (90 % and 93 % variants) and AAPL (90 %). TSLA and NVDA markets have `boostedLLTV = 0`.

**D21 - Stress rule and deleveraging.** From `preWindowHorizon` before a blind window the effective borrow cap for boosted accounts is `min(tierLLTV, 1 - gapVaR[class] - oracleBuffer - safetyBuffer)`; new borrows and HF-lowering withdrawals above it revert with a custom error carrying the numbers. Accounts above the stress cap at horizon start are flagged (event). Cure window: flagged borrowers may repay or add collateral. After the cure window ends and before the window starts, anyone may call `deleverage(account)`: it sells only enough collateral to reach the stress cap minus a small margin, charges `deleverageFee` (reduced fee), obeys the market's non-worsening rule and bonus cap, emits an event with the numbers, and is impossible while the market is Halted or the oracle is unscheduled-blind. Standard-tier accounts are never deleveraged.

**D22 - Liquidation otherwise unchanged.** Market rules with the flat bonus; no Dutch ramp, no depth-sized partial liquidation (M2.2 showed no lender benefit).

**D23 - Unscheduled blindness (adapter flag).** Block new borrows and HF-lowering withdrawals for boosted and standard accounts; deleveraging disabled; repay stays open.

**D24 - Governance.** Parameter changes via timelock within bounds. The guardian can only tighten (disable boosted entry, block new borrows) and never loosen or move funds. Every power is tested.

**D10 (restated).** On early-close days capacity tightening may start earlier than 20:00 ET; implemented as a single conservative config and documented as unverified.

**D25 - Replay harness (`sim/`).** Deploy a control market (`FlatGuard` at the boosted LLTV) and a Sundown boosted market from the same implementation with `SimEquityFeed` (simulation), seed the same synthetic borrower population, replay the worst K real AAPL and SPY events from `sim/replay_events.json`, and print lender loss, liquidations, deleverage events and borrower capacity; compare against the Python reference/credit simulation for matching scenarios and report the tolerance honestly. Anvil first; Sepolia broadcast only on the owner's instruction.

**Review rules for M4a/M4b.** M4a may flow into M4b without waiting only after (1) the design is committed, (2) an adversarial self-review is posted with the design summary, and (3) nothing deviates from D18-D25. Stop on a deviation, failed validation or direction-changing discovery. M4b budget <= 5 h; cut list in order: replay polish, extra fuzz, then deleveraging (if cut, report immediately: with no enforcement the product is a measurement tool). No public-network deployment.

**D26 - Calibration: through-the-cycle static `gapVaR` (GUARD_DESIGN section 11, option 2).** Per asset and window class (Short/Weekend/Long), the full-sample empirical q99.5 downside gap, read-only from `research/results/class_stats.csv` (column `loss_q99.5_bps`; method: `np.quantile(x, 1 - q, method="lower")` of the log gap `ln(open_D2 / close_D1)` in bps, loss = -gap; sample 2010-01-04 to 2026-10-01, includes March 2020; split-adjusted daily proxy, a conservative superset of blind exposure). Never invented; if absent, stop. Product framing everywhere: **"session-aware LLTV: boosted weekday capacity, tighter weekend capacity"**, not loss prevention. Report per asset and tier the resulting stress cap and whether it binds. Deploy only boosted variants where the cap binds; a non-binding 90 % variant is not deployed as boosted (labeled unenforced if kept). TSLA and NVDA stay standard-tier only.

**D27 - Option 3 deferred.** No guardian power to raise `gapVaR` in v1: tightening a parameter can trigger forced sales of boosted users (griefing / compromised-key risk). Roadmap: a guardian tightening that takes effect only at the next window boundary, with a snapshot taken at the horizon start (`THREAT_MODEL.md`).

**D28 - Deleverage realization approved as built.** Deleverage = guard-authorized `market.liquidate` plus a `quoteDeleverage` view; no wrapper. The critical-health limitation for standard accounts in a boosted market (the 100 % close-factor trigger uses the market `lltv`) is accepted and documented.

**D29 - Deleverage fee and keeper economics (A16).** The replay computes the keeper break-even per market: the fee required to cover exit slippage at the demonstration position size (from the depth table) plus gas. Default fee = `max(2 %, break-even)` bounded by the bonus cap. If no fee within the bonus cap is profitable at a position size, state the position-size / collateral cap that makes it viable, or state that enforcement may silently not execute at that size. Enforcement depends on a keeper; the demo keeper is the replay script; a production keeper service is out of scope and listed as a limitation. (Supersedes the 1 % default in D19.)

**D30 - Replay evidence stated exactly as measured.** AAPL 93 %, the 10 worst events, a seeded 20-borrower population: control loss $3,824 over 4 events, session-aware $1,224 over 1 event (-68 %), standard 86 % $0 at 7.5 % lower capacity; the 2020-03-16 gap still produced a loss. The replay runs in forge's in-process EVM with a fixture window cache, **not on a public chain**; it is labeled so everywhere. SPY 93 % and AAPL 90 % are not deployed as boosted.

**D31 - Author emails.** History is not rewritten and nothing is added; the owner links both emails on GitHub.

**D32 - Secret scan.** Full-history scan (gitleaks if installed, else `git log -p` with grep for private keys, 64-hex strings, API-key patterns and RPC URLs with keys), plus a check of tracked files for `.env`, broadcast artifacts and keystores; reported before any push; the owner pushes.

**D33 - Deployment scope: Arbitrum Sepolia (421614) only; Arbitrum One is cut.** Test fixtures (all named and labeled as simulation): `SimUSDG` (6 decimals, public faucet with a per-address limit), `SimStock` tokens for SPY, AAPL, NVDA and TSLA (18 decimals, symbols prefixed "s", public faucet with a limit, the same pause and per-address block surface as the real issuer token so the halt demo is real code), one `SimEquityFeed` per asset (8 decimals, owner-set price). Production code deployed: calendar and wrapper, `WindowCache`, `ChainlinkEquityOracle` (pointed at the sim feed and labeled so; real-feed validation stays the optional fork test), factory and implementation, `FlatGuard`, `SundownGuard`. Markets: SPY, NVDA, TSLA, AAPL (standard, FlatGuard), AAPL boosted 93 % (SundownGuard, D26 gapVaR) and AAPL control 93 % (FlatGuard at 93 %). Collateral caps in token units from the exit-liquidity table scaled to demonstration size; recommended production caps are published in docs only. Deploy with `forge script` using a cast keystore (`--account`), never a raw key in env or logs; write `deployments/421614.json`; verify every contract on Arbiscan (Etherscan v2 key via env); idempotent scripts; dry-run on a fork first.

**D34 - Live evidence (`docs/SEPOLIA_DEMO.md`, produced by a rerunnable script).** Every step timestamped with the calendar's window state at that moment; in-window behavior is captured before the window ends (Sun 2026-10-04 20:00 ET). Covers faucet, supply, collateral, a standard borrow; the boosted market denying a borrow above the stress cap (decoded custom-error numbers) and a successful borrow below it; a price move leading to a liquidation on the control market; the issuer-failure demo (pause, `reportIssuerFailure` to Halted, repay still works, unpause, resume); the oracle adapter rejecting a stale or invalid answer; Arbiscan links for every transaction. It states plainly what cannot be shown live before the deadline (pre-window horizon, cure window, deleveraging need a window start on Fri 2026-10-09 20:00 ET) and points to `REPLAY_RESULTS.md` and the forge tests.

**D35 - `scripts/preflight.sh`.** Tests (including fork when the env is set), snapshot check, slither, contract code present and verified at every address in `deployments/421614.json`, calendar fixture check, replay reproducibility, secret check; its output is reported.

### Carry-forward notes (bind M3/M4)

- **N1** Oracle adapter uses calendar-aware freshness: the 0.5 % deviation is an irreducible price-error allowance; add an age-based haircut; distinguish scheduled (calendar) from unscheduled (outage) blindness.
- **N2** Post-window observations are censored by the deviation/heartbeat rule; `recordPostWindow` must handle a late first update and record the lag; M2 quantifies it. *M1 evidence (docs/CALENDAR_NOTES.md section 11): in 14 observed windows x 6 feeds the first update arrived 18-85 s after the window end, so censoring was not observed; it remains possible on a quiet open and must still be handled.*
- **N3** No sequencer-uptime feed on Robinhood Chain: optional config; downtime = unscheduled blindness. Arbitrum One keeps the Chainlink feed.
- **N4** Only the 32 feed-backed tokens are eligible collateral.
- **N5** The flat-LLTV control uses the **real** in-the-wild parameters: Morpho on Robinhood (38.5 %, 62.5 %, 77 %, 86 % LLTV) and Aave's reported 65-79 % collateral factor with 5.5 % max bonus (**secondary-source**, label as such).

## 9. Recommended next milestone

**M1 - `UsMarketCalendar`** (approved, in progress): it has no dependencies, is fully verifiable against an independent implementation, and everything downstream (blind windows, window ids, gap classes, guard timing) rests on its correctness. The trading-day model should be locked in M1 so M2/M5 don't build on a wrong blind-window definition.
