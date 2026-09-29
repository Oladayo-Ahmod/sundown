# SundownGuard design (M4a)

Implements D18-D25 (`DESIGN.md` section 8) behind the existing `IRiskGuard` and `SundownMarket`. Status: **design, not implemented**. Control: `FlatGuard` (unchanged).

## 0. Headline finding: calibration decides whether the guard does anything

D18 sets `gapVaR` per asset and window class as a static WAD taken from `deployments/risk_params.json` at q = 99.5 %. Those values are the **calm-regime forecast at data end** (2026-10-01). The stress cap is `1 - gapVaR - oracleBuffer - safetyBuffer`, so with D19's 50 bps + 100 bps buffers it only binds a boosted tier when `gapVaR >= 1 - 1.5 % - tier`:

| Tier | Cap binds when gapVaR >= |
|---|---|
| 93 % | 5.5 % |
| 90 % | 8.5 % |

| Asset (q9950, data end) | Short | Weekend | Long | Stress cap (Weekend) | Binds 93 %? |
|---|---|---|---|---|---|
| SPY | 176.6 bps | 248.9 bps | 282.2 bps | 96.0 % | **no** |
| AAPL | 251.5 bps | 354.5 bps | 401.7 bps | 94.95 % | **no** |

Real worst blind-window losses from `sim/replay_events.json`: SPY 11.04 % (2020-03-16), 7.74 % (2020-03-09), 5.37 % (2015-08-24); AAPL 13.88 %, 10.87 %, 9.92 %, 9.15 %. A position at 93 % LTV is insolvent after a 7 % gap and one at 90 % after a 10 % gap. **With D18's literal values the stress rule never fires for SPY or AAPL, nothing is flagged or deleveraged, and a boosted account behaves exactly like the unprotected control at the boosted LLTV.** The research benefit (`CLAIMS.md`, `results/mech_b_hard_deleveraging.csv`, 4.3 % of windows flagged at 90 %) comes from the time-varying EWMA, which D18 defers.

The guard mechanics below are independent of this: `gapVaR` is a parameter. But the *calibration policy* is a product decision with three options (section 11), and the replay harness (D25) must report results for the options that are chosen. This is why M4b waits for a decision.

## 1. Fit with the existing interfaces (no change to `IRiskGuard` or the market)

| Need | Mechanism with the current code |
|---|---|
| Per-account state | Guard storage keyed by account; guard is bound to one market (`bindMarket`, one-shot) |
| Borrow / withdraw cap | `maxBorrowable(ctx)` is `view`, called by the market on borrow and on withdraw-with-debt with **post-action** state; the market enforces `min(guard, cv * lltv)`. Error carrying numbers: market's `ExceedsCapacity(debt, cap)` |
| Block both borrow and withdraw (unscheduled blindness, D23) | `maxBorrowable` returns 0 (every borrow and every collateral withdrawal with debt is HF-lowering) |
| Guardian "block new borrows" only | `onBorrow` (called by the market only on borrow) reverts |
| Deleveraging | A **guard-authorized market liquidation**: `liquidationAllowed` true in the deleverage zone, `liquidationBonus` returns `deleverageFee`, `onLiquidate` (receives the pre-state ctx) enforces `repaid <= requiredRepay` and emits `Deleveraged`. The market keeps enforcing close factor, bonus cap, dust rule and the non-worsening rule |
| `deleverage(account)` entry point (D21) | Realized as `market.liquidate(account, repay, receiver)` plus `guard.quoteDeleverage(account)` view (eligible, max repay, expected seized). No separate pull-and-sell contract: a second code path could diverge from the market's rules, and a keeper cannot be forced to sell anyway. **Reads D21 as semantics, not a literal function name; veto if you want a periphery wrapper** |
| Halt gate | The market has no halt gate on `liquidate` (I9), so the guard reads `market.state()` and refuses deleveraging while Halted |
| Hot path | `WindowCache.peek()` (warm after the market's own `oracle.price()` refreshed the shared cache); no calendar scan per action (D11) |
| Early-close days (D10) | The calendar library already holds the single config `EARLY_CLOSE_WINDOW_SOD` (UNVERIFIED); the guard measures the horizon from the cache's window start, so flipping it moves the horizon. No guard-level special case |

Because `maxBorrowable`/`liquidationAllowed` are views, "flagging" cannot be a state transition at horizon start (nobody executes it). **All eligibility is a pure function of (position, price status, window state, time).** `flag(account)` is an optional permissionless poke that only emits an event and records `flaggedWindow[account]`; it never gates anything.

## 2. State machine

Per account (derived, except the stored tier and `flaggedWindow`):

| State | Definition |
|---|---|
| Standard | `boosted[a] == false` (default). Never stress-capped, never deleveraged |
| Boosted | `boosted[a] == true`, outside the stress period |
| Flagged | Boosted, stress period active, `debt > floor(cv * stressCap)` |
| Cured | Boosted, `flaggedWindow[a] == windowId` (poked) and now `debt <= floor(cv * stressCap)` |
| Deleveraged | Event `Deleveraged` emitted for this window (counter in the event stream, no storage) |

Transitions: `enterBoosted()` Standard -> Boosted; `exitBoosted()` Boosted -> Standard; time moves Boosted -> Flagged at `windowStart - horizon` if above the cap; repay or add collateral moves Flagged -> Cured; after `windowStart - horizon + cure`, a Flagged account is deleverage-eligible until `windowStart`.

**Stress period** = `[start - horizon, start)` before a window, the window itself (`blind`), and `status == Reopening`. Boosted cap = `min(boostedLLTV, stressFraction)` inside it, `boostedLLTV` outside.

## 3. Math and rounding

`cv` = `collateral * price / valueScale` (market, rounded down). WAD = 1e18.

- `stressFraction = max(0, WAD - gapVaR[cls] - oracleBuffer - safetyBuffer)` (`cls` = class of the current/next window from the cache).
- Tier cap fraction `capFrac = min(boostedLLTV, stressFraction)` in the stress period else `boostedLLTV`; standard accounts `standardLLTV`.
- `cap = floor(cv * capFrac / WAD)` (rounded **down**: against the borrower).
- Liquidation threshold `thr = floor(cv * tierLLTV / WAD)` with `tierLLTV` = the account's tier LLTV; `liquidationAllowed` ordinary branch: `debt > thr` (floor makes the account liquidatable slightly earlier: against the borrower).
- Deleverage trigger: `debt > cap` where `cap` uses `stressFraction` (no margin). Target: `t = capFrac - margin` (`margin` default 50 bps, so a deleveraged account lands below the trigger and cannot be re-triggered by one wei of rounding).
- Required repay `R` to reach the target with fee `f`: `(D - R) <= t * (cv - R(1+f))` gives `R = ceil((D - floor(t * cv)) * WAD / (WAD - mulDivUp(t, WAD + f, WAD)))`, clamped to `D`. Denominator is positive because `t * (1 + f) < 1` (`boostedLLTV <= 0.94`, `f <= 5.5 %`). `R` rounds **up** (against the borrower), `floor(t*cv)` rounds down (against the borrower). `onLiquidate` accepts `repaid <= R`, or `repaid == debt` when the market's dust rule forced a full repay (`debt - R < minDebt`).
- Seized collateral and the bonus cap are computed by the market; `liquidationBonus` returns `f` in the deleverage zone and the flat bonus otherwise. The market's non-worsening cap `b <= cv/debt - 1` still applies.
- Close factor: the market caps one call at 50 % of debt (100 % below critical health); if `R` exceeds it the deleverage completes over two calls. The market's critical-health test uses the **market** `lltv` (= `boostedLLTV` in boosted markets), so for standard accounts the 100 % close-factor trigger is later than their own threshold. Documented limitation; conservative for borrowers.
- Ordering: if `debt > thr` (genuinely unhealthy) the **ordinary** rules apply (flat bonus, ordinary close factor) even inside the deleverage zone, so the reduced fee can never be used to shortchange a liquidation that the standard rules require.

## 4. Time logic

`w = cache.peek()`. With `H = preWindowHorizon`, `C = cureWindow`, `S = w.start`, `E = w.end`:

- Pre-window period: `!w.blind && now >= S - H && now < S`.
- Cure period: `[S - H, S - H + C)`; deleverage zone: `[S - H + C, S)`, `status == Fresh`, market Active, account Boosted, `debt > cap` (stress), account healthy.
- Entry into the boosted tier (`enterBoosted`): `!w.blind && now < S - H`, `status == Fresh`, market Active, entry not guardian-disabled, and `debt <= floor(cv * min(standardLLTV, stressFraction))` (prevents entering to escape liquidation or to start in breach).
- Exit (`exitBoosted`): any time, if `debt <= floor(cv * standardLLTV)`.
- DST: `S`, `E` and the class come from the calendar library in UTC seconds; the guard never converts wall-clock time, so DST days need no special case (tested through the real `UsMarketCalendar` on the March and November weekends).
- Boundaries: `now == S - H` is in the pre-window period; `now == S - H + C` is in the deleverage zone; `now == S` is blind (not deleveragable).

## 5. Parameters, bounds, governance (D19, D24)

| Parameter | Bounds (hard-coded constants) | Default |
|---|---|---|
| `standardLLTV` | [0.30, 0.95] | per market (research: 0.77 / 0.86 for the control) |
| `boostedLLTV` | 0 or [standardLLTV, 0.94] (`lltv * (1 + 5.5 %) < 1`) | 0.90 / 0.93 (SPY), 0.90 (AAPL), 0 (TSLA, NVDA) |
| `gapVaR[3]` | [0, 0.50] each | calibration, section 11 |
| `oracleBuffer` | [0.1 %, 5 %] | 0.5 % |
| `safetyBuffer` | [0, 10 %] | 1 % |
| `bonus` | [3 %, 5.5 %] | 4 % |
| `deleverageFee` | [0.25 %, bonus] | 1 % |
| `deleverageMargin` | [0, 5 %] | 0.5 % |
| `preWindowHorizon` | [1 h, 48 h] | 6 h |
| `cureWindow` | [0, horizon - 1 h] | 3 h |
| `timelockDelay` | immutable, [1 h, 14 d] | 48 h (deployments), small in tests |

- Governance: `queueParams(Params)` validates bounds, stores a hash and `eta = now + delay`; `executeParams` after `eta`; `cancelParams`. Bounds are re-checked on execution. The market's `lltv` is immutable and equals `max(boostedLLTV, standardLLTV)` at creation; a guard parameter set above it is capped by the market anyway.
- Guardian (tighten-only): `setBoostedEntryDisabled(true)` and `setBorrowsBlocked(true)`. Governance may clear them immediately (this only restores the timelock-approved configuration). The guardian cannot change parameters, cannot clear its own flags, cannot touch funds (the guard holds none).
- One-shot `bindMarket(market)` by the constructor-set `admin`, which then renounces. Stateful hooks (`onBorrow`, `onLiquidate`) accept only the bound market.

## 6. Invariants for the extended stateful suite

G1 No borrow or withdrawal leaves a boosted account's debt above `floor(cv * stressFraction)` inside the stress period (ghost-checked in the handler, independent computation). G2 A deleverage never raises LTV, never repays more than `R` (or the full-debt dust exception) and never touches a Standard account. G3 The guardian cannot loosen: no parameter, tier or cap changes after any guardian call (state hash). G4 Boosted entry only outside the stress period, from a position that fits standard and the stress cap. G5 Repay is never blockable (existing I8, re-run with the guard). G6 No deleveraging while Halted or when status != Fresh. G7 Parameters always within bounds; changes only after `eta`. G8 `Deleveraged` is emitted exactly when the guard's pre-state predicate held.

## 7. Attack list

| # | Attack / edge case | Response | Test |
|---|---|---|---|
| A1 | Griefing deleverage calls (tiny or repeated) | Eligible only above the stress cap; `repaid <= R`; each call is funded by the caller; the market's dust rule may fully close a position under about `minDebt + R` (<= ~15 USDG at 10 USDG minimum); accepted | unit, fuzz on `R` |
| A2 | Flag/unflag edge cases at the horizon boundaries | No stored flag gates anything; eligibility is a pure function of state and time | boundary tests at `S-H-1`, `S-H`, `S-H+C-1`, `S-H+C`, `S-1`, `S` |
| A3 | DST-day windows | Calendar-derived UTC bounds; no wall-clock logic | real-calendar test, Mar/Nov weekends |
| A4 | Opt-in gaming: enter to escape liquidation | Entry requires the position to fit standard and the stress cap; entry blocked in the stress period | unit + stateful (G4) |
| A4b | Hold tier-cap leverage to the end of the cure, then be deleveraged at the cheap fee | Intended: fee <= bonus; lenders were protected by the cap; borrower pays `deleverageFee` on the delta | unit |
| A4c | Exit to Standard to dodge deleveraging | Allowed only if the position fits standard; then it carries standard-tier risk (the status quo control) | unit |
| A5 | Bonus gaming (liquidator claims 4 % where 1 % applies, or the reverse) | `liquidationBonus` returns `deleverageFee` only when healthy and in the deleverage zone; ordinary rules win when `debt > thr`; market caps bonus and enforces non-worsening | unit + differential vs reference |
| A6 | Guardian abuse | Tighten-only: block entry, block borrows; no funds, no parameters. Worst case is a growth freeze until governance clears it | one test per power, stateful G3 |
| A7 | Window-boundary front-running | Borrow at `S-H-1` at tier cap is legal and will be flagged; repay in the same block as a deleverage call makes the call revert (no harm); price is whatever the oracle reports at call time | boundary tests |
| A8 | Stale-oracle spoofing | Status comes from the governance-fixed oracle through the market; Stale makes `maxBorrowable` 0 and disables deleverage (D23); censoring a feed is the oracle trust assumption (T3/T4) | unit |
| A9 | Timelock bypass | Only governance queues; `eta` and bounds enforced at execution; guardian cannot queue | unit |
| A10 | `bindMarket` front-run | Only the constructor `admin` can bind, once; renounced after | unit |
| A11 | Reentrancy through hooks | Market hooks run inside the market's `nonReentrant` after state updates; the guard makes only view calls to the market, cache and oracle | unit with a hostile view-reentering cache |
| A12 | Gas griefing of a stale cache | The market's `oracle.price()` refreshes the shared cache first; `enterBoosted` pays one scan at worst (~150k) | gas test |
| A13 | Early close moves the window (D10) | Single calendar config; the horizon follows the cache; UNVERIFIED | documented |
| A14 | Standard accounts' critical-health uses market `lltv` | Documented limitation (section 3) | unit |
| A15 | Poke spam on `flag` | Only emits if truly above the cap; one write per (account, window) | unit |

## 8. Test plan (M4b)

Unit: every state transition, bound, timelock path, each guardian and governance power, each boundary instant, `R` against a Python reference, both bonus paths, Halted, Stale, Reopening, standard-vs-boosted capacity, the dust exception, hostile hooks. Fuzz: `R` monotone and sufficient (post-deleverage debt <= target + rounding), `capFrac` formula, entry and exit predicates, bound checks. Stateful (extend `MarketInvariantsTest` handler with `SundownGuard`): G1-G8 with ghost variables computed independently. Differential: real `UsMarketCalendar` + `WindowCache` on DST weekends. Replay harness: section 9.

## 9. Replay harness (D25, `sim/`)

Foundry script on anvil: deploy `SimEquityFeed` (simulation), a `FlatGuard` control market at the boosted LLTV and a `SundownGuard` market from the same implementation, seed the same synthetic borrower population (LTV spread, deterministic), replay the worst K AAPL and SPY events from `sim/replay_events.json` as pre-window / blind / reopen sequences, then print lender loss, liquidations, deleverage events and borrower capacity per market. Comparison against the Python credit simulation for matching scenarios, with the tolerance stated as measured (the on-chain run is exact-integer; the Python simulation is daily-gap based, so agreement is on direction and order of magnitude, not to the unit).

## 10. Out of scope (v1)

Onchain EWMA or observation pipeline (D18, roadmap), Dutch ramp, depth-sized partial liquidation, priced premium, boosted tiers for TSLA and NVDA, a periphery sell-and-repay wrapper.

## 11. Calibration options (decision needed before M4b)

1. **Data-end static (literal D18).** Cap never binds for SPY/AAPL. Zero enforcement; boosted = control at the boosted LLTV. The replay will show lender loss equal to the control in the 2020 and 2015 events. Label the product a measurement tool.
2. **Through-the-cycle static.** Set `gapVaR` to a stress-regime constant per asset and class (e.g. the historical peak of the research forecast, or an unconditional q99.5 of gaps). For the cap to bind a 93 % tier, SPY needs >= 5.5 % and AAPL >= 5.5 %; for 90 %, >= 8.5 %. The cap then binds at every window and boosted accounts deleverage to ~91 % every weekend: capacity expansion is Monday to Friday only, with a recurring borrower cost (`mech_b` reports about 5 bps per year borrower cost at 90 % under the dynamic estimator; static would be higher).
3. **Tighten-fast, loosen-slow gapVaR.** Keep the calm default but let the guardian *raise* `gapVaR` immediately (a tighten-only power, extending D24) while lowering it needs the timelock. An offchain keeper or operator reacts to regime shifts. Needs your approval because it adds a guardian power.

Recommendation: **option 2 for the demonstration deployment, with option 3 proposed as the production path**, and the replay reporting control, option 1 and option 2 side by side so the claim in the UI matches the measured behavior.
