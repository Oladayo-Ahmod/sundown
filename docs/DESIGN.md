# Sundown M0 - Design Proposal

Status: **proposal, not implemented**. Every claim about the outside world is tagged **[V]** verified (see `DISCOVERY.md`), **[D]** documented by a primary vendor but not independently checked, or **[U]** unverified. Sections marked **CHANGE** deviate from the original brief because discovery contradicted or refined it and need your approval before M1.

## 1. Thesis and scope

Tokenized-stock collateral is priced by a 24/5 oracle that **goes blind over weekends and holidays** and reopens with a gap. Static LTV/LLTV (Aave, Morpho) prices that risk once, forever. Sundown makes the risk **session-aware**: borrow capacity tightens before a blind window, and liquidation after the gap is shaped around the thin, noisy reopen. The design is an isolated market with a pluggable `IRiskGuard`, so a **control market (FlatGuard)** and a **treatment market (SundownGuard)** differ *only* by the guard and can be replayed against the same price path.

Non-goals: a general lending protocol, a price oracle, a DEX, upgradeability of core accounting, governance tokens.

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

- State: per asset and class, a ring buffer of the last N=64 observations packed as `int16` bps (4 storage slots) plus EWMA of squared returns.
- Gap-VaR at confidence c (e.g. 99 %) = `max(floor_class, blend)` with `blend = a * z_c * sigma_ewma + (1 - a) * q_empirical`, `a` ramps with the observation count (`n/(n+k)` on the empirical part) so a cold start uses a governance-seeded prior (calibrated offline in `research/`, not claimed as measured).
- Cost: quantile over <= 64 values computed **once per record**, cached; reads are O(1). Insertion bounded (64), no unbounded loops.
- Recording is permissionless and two-phase with replay protection per `windowId`: (1) `snapshotPre(windowId)` callable only inside the blind window, captures the oracle's frozen last price; (2) `recordGap(windowId)` callable after the window ends, once the oracle has produced a post-window update (`updatedAt >= windowEnd`, bounded delay), computes r. Exactly one write per `(asset, windowId)`; missing observations are skipped, never fabricated.
- Data: only 2026-07-01 onward exists on this chain, so cold-start priors come from `research/` (equity history) and are labelled as offline analysis.

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
- Caps: supply cap, borrow cap, collateral cap (mirrors Aave's capped rollout; LlamaRisk used caps of $32M/$21M [S]).
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

Hooks are `view` where possible; permissionless recording lives on the guard/risk model, not in the market. The guard may restrict but never relax the market's hard solvency checks.

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

### Carry-forward notes (bind M3/M4)

- **N1** Oracle adapter uses calendar-aware freshness: the 0.5 % deviation is an irreducible price-error allowance; add an age-based haircut; distinguish scheduled (calendar) from unscheduled (outage) blindness.
- **N2** Post-window observations are censored by the deviation/heartbeat rule; `recordPostWindow` must handle a late first update and record the lag; M2 quantifies it.
- **N3** No sequencer-uptime feed on Robinhood Chain: optional config; downtime = unscheduled blindness. Arbitrum One keeps the Chainlink feed.
- **N4** Only the 32 feed-backed tokens are eligible collateral.
- **N5** The flat-LLTV control uses the **real** in-the-wild parameters: Morpho on Robinhood (38.5 %, 62.5 %, 77 %, 86 % LLTV) and Aave's reported 65-79 % collateral factor with 5.5 % max bonus (**secondary-source**, label as such).

## 9. Recommended next milestone

**M1 - `UsMarketCalendar`** (approved, in progress): it has no dependencies, is fully verifiable against an independent implementation, and everything downstream (blind windows, window ids, gap classes, guard timing) rests on its correctness. The trading-day model should be locked in M1 so M2/M5 don't build on a wrong blind-window definition.
