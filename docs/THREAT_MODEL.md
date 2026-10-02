# Sundown threat model

Scope: `SundownMarket` (vault + isolated lending market), `SundownMarketFactory`, `ChainlinkEquityOracle`, `WindowCache`, `FlatGuard`. Companion to `MARKET_DESIGN.md` section 14 (component table) and `DISCOVERY.md` (token facts). Tags: **[V]** verified on-chain/source, **[D]** documented by a third party, **[U]** unverified assumption.

## 1. Trust assumptions (what we cannot fix)

| # | Assumption | If it breaks |
|---|---|---|
| T1 | The stock-token issuer behaves: roles on the registry and token are EOAs [V]; the registry is also the beacon, so the issuer can upgrade token code | Collateral can be paused, blocked or burned at will. We detect and halt; we cannot prevent it |
| T2 | USDG is worth exactly 1 USD (D3) | A depeg makes debt and collateral values wrong in the lender's disfavour; no on-chain check exists |
| T3 | The oracle and guard chosen by governance at creation are honest and correct | A bad guard can freeze borrowing and trigger bounded liquidations; a bad oracle can misprice. Neither can move funds beyond what market bounds allow |
| T4 | Chainlink push feeds keep their documented cadence, 8 decimals, and carry the `uiMultiplier` [D] | Stale/wrong status; see section 3 |
| T5 | Early closes do not move the 20:00 ET boundaries [U] | Window classification off by the early-close gap; config constant, fail-safe statuses |
| T6 | No Robinhood Chain sequencer-uptime feed exists [V] | `SequencerDown` cannot fire on that chain; documented gap |

## 2. Issuer control risks

**Phantom collateral (`adminBurn`).** The issuer can burn tokens held by the market, ignoring pauses and blocklists [V]. The credited ledger then exceeds the real balance. v1 policy (D13): seizures and withdrawals pay out what exists; the market halts with `CollateralShortfall`, accrual freezes, and lenders absorb the loss through `realizeBadDebt`. The stateful suite asserts `balance + burned == totalCollateral` across random burns. **Unresolved:** a burn is a direct loss to lenders; the cap (0.5 x depth at 3% slippage) bounds it. Disclosed.

**Blocklisting / pausing.** If the market is blocked or the token paused, collateral cannot move: withdrawals and seizures revert, liquidations stop. Probes (permissionless `reportIssuerFailure`) flip the market to `Halted`. Repay stays open (invariant I8, mutation-checked). Residual: unhealthy positions cannot be liquidated while blocked; interest keeps accruing only after the 30-day freeze.

**Beacon upgrade / role compromise.** All privileged roles are EOAs [V]. A malicious upgrade could change `transfer` semantics (fees, callbacks, hidden pauses). Balance-delta checks reject fee-on-transfer at deposit time; later changes are caught only by probes. No on-chain fix.

**USDG pause/freeze.** Probes 3 and 4. Lender redemptions and repayments revert while the loan token is paused; nothing in the market can bypass it.

## 3. Oracle and calendar risks

- **Stale price accepted.** Calendar-aware statuses (`Fresh`, `ScheduledBlind`, `Reopening`, `Stale`, `Invalid`, `CorporateAction`, `SequencerDown`); the market refuses the last three for borrow, withdraw-with-debt and liquidate; the guard decides on the rest with a haircut.
- **Oracle read before state write.** Every action reads the oracle (and guard) before writing state (slither `reentrancy-no-eth` on `liquidate`, accepted). All state-changing functions are `nonReentrant`; a hostile oracle could only observe mid-state through views. Hence T3.
- **Calendar cache.** TTL 24 h < `ANNOUNCE_LEAD` 72 h, so an ad-hoc closure announced 72 h ahead is seen before it matters; a closure announced later than that is not covered.
- **Unobserved regimes.** EST winter, early closes and Short windows have not appeared in the observed feed history; classification is differentially tested against an independent calendar but behaviour of real feeds there is unverified.
- **Corporate actions.** A pending multiplier change maps to `CorporateAction`, which blocks borrow and liquidation until it clears. Detection depends on the feed exposing the change.

## 4. Market and vault risks

- **Inflation/donation.** Virtual shares 1e6/1 and internal ledgers; donations are not credited and are locked. Unit attack scripts cover it; no donation action in the stateful handler.
- **Rounding drain.** Rounding always against the user (table in `MARKET_DESIGN.md` section 6); `minDebt` dust floor. Aggregate debt vs `totalBorrowAssets` checked in both directions to rounding dust; 1-wei leaks in rare paths are below that resolution.
- **Interest math.** Three-term Taylor compounding understates for very large elapsed time (a lender-side loss, bounded by the 30-day freeze and frequent accrual). Python reference matches exactly.
- **Liquidation.** Flat bonus in [3%, 5.5%], close factor 50% rising to 100% below critical health 0.95, non-worsening cap `b <= Cv/debt - 1`. Insolvent positions yield bad debt; `realizeBadDebt` is explicit and permissionless for zero-collateral accounts.
- **Self-liquidation / sandwiching** around oracle updates is accepted (bonus capped; update ordering outside our control).
- **Gas-starvation false halts.** Probes need 1.2M gas up front and use a fixed 250k allowance each; a probe that did not run cannot halt the market.
- **Capacity.** Collateral cap is in token units and sized from measured v3 depth: about $0.9M total collateral at 3% slippage across the four demonstration markets. A larger cap would make liquidation exits unprofitable.

## 5. Governance and deployment risks

- Factory creation is owner-only (Ownable2Step); markets are immutable clones with parameters fixed at creation. There is no upgrade path and no `windDown()` (D14).
- Guardian can only halt; resume requires the probes to pass, and governance can resume unconditionally. Governance key compromise therefore means an unconditional resume of a failing market. Use a multisig for any non-demo deployment.
- The Sepolia demonstration uses `SimEquityFeed` (labelled simulation, keeper-published). It proves integration shape, not oracle security. No production-scale claim except NVDA; Robinhood Chain is used only for read-only adapter validation.

## 5b. Guard risks (SundownGuard, D26-D29; details in `GUARD_DESIGN.md` section 7)

- **No guardian power to raise `gapVaR` in v1 (D27).** Raising a parameter can trigger forced sales (deleveraging) of boosted users, so a compromised or malicious guardian key would become a griefing tool against borrowers. The guardian can only disable boosted entry and block new borrows (no forced sale, no loss). Roadmap: a guardian tightening that takes effect only at the next window boundary, with a snapshot taken at the horizon start.
- **Calibration is static and through-the-cycle (D26).** Values are the full-sample empirical q99.5 per asset and class; Short and Long are not statistically resolvable at q99.5 (sample maximum). A regime shift beyond the sample is not tracked on chain; changes go through the timelock.
- **Enforcement depends on a keeper (D29).** If no fee within the bonus cap is profitable at a position size, deleveraging may silently not execute. The demo keeper is the replay script; a production keeper service is out of scope.
- **Critical-health limitation (D28).** For standard accounts in a boosted market the 100 % close-factor trigger uses the market `lltv`, so it fires later than their own threshold.
- **Framing.** Session-aware LLTV (boosted weekday capacity, tighter weekend capacity), not loss prevention.

## 6. Required user-facing disclosures

1. The issuer can pause, block or burn collateral; Sundown halts but cannot prevent loss.
2. Debt is denominated in USDG assumed to equal 1 USD.
3. The research result is a capacity-expansion claim at counterfactual 90-95% LLTV, not a loss-avoidance claim at real LLTVs (`research/CLAIMS.md`); no "safer than Aave" language.
4. Prices in blind windows are scheduled-stale by design; the haircut and borrow limits tighten before the window.
5. Demonstration deployments carry simulated prices.

## 7. Known gaps (not mitigated in v1)

Phantom collateral loss; token-code upgrades after deployment; closures announced under 72 h; EST/early-close/Short-window behaviour unobserved; no sequencer feed on Robinhood Chain; boosted-tier guard (M4a) not implemented; stateful suite does not cover I6-insolvent, I9, I10 monotonicity, I12, I13, I14.

## 8. Static-analysis baseline (Slither, reviewed 2026-10-03)

`scripts/check_slither.py` (run by `scripts/preflight.sh`) reads the Slither JSON report and fails on any High finding and on any Medium finding beyond the baseline in `scripts/slither_baseline.json`. The 11 accepted Medium findings:

- **incorrect-equality (2):** `SundownMarket.healthFactor` and `_planLiquidation` compare a debt to the sentinel `0` (no debt). The strict comparison is the intent.
- **reentrancy-no-eth (3):** `liquidate` reads the oracle and guard before writing state (governance-fixed, trust-bounded, T3); `reportIssuerFailure` and `resume` call the collateral and loan tokens (gas-capped probes) before writing the halt state. Every state-changing market function is `nonReentrant`, so a token or oracle callback cannot re-enter one; callbacks can only call views.
- **unused-return (6):** deliberate tuple destructuring of `latestRoundData`, `blindWindowAt` and `nextBlindWindow`, where only some components are needed and every used component is validated.

Low and informational findings (timestamp comparisons, naming of immutables, low-level calls with a gas cap in the probes) are expected: the system is time-based by design.

## 9. Test evidence (final, from runs on 2026-10-03)

| Run | Result |
|---|---|
| `forge test` (default profile, no fork variable), 19 suites | **231 passed, 0 failed, 4 skipped** (235 total). The 4 skipped are the fork tests: 1 pre-existing (`OracleForkTest`) and 3 live-feed (`OracleForkLiveTest`), which need `ROBINHOOD_MAINNET_RPC_URL` |
| `FOUNDRY_PROFILE=ci forge test` (1,000 fuzz runs, 256 invariant runs), run before the 3 live-feed tests were added | exit 0, 231 passed, 0 failed (the final totals are in the first row) |
| Fork tests against the real Robinhood Chain feeds (`docs/ORACLE_LIVE_VALIDATION.md`) | Recorded run: 4 of 4 passed. A later full-suite run with the variable set: 1 failed on a dropped TLS connection (transport error), 234 passed; the fork tests are optional and intermittently flaky on the public RPC |
| Python (`research`, `uv run pytest`) | 47 passed, 1 skipped |
| Replay cross-check (`sim/compare_replay.py`) | 120 of 120 rows within tolerance, 111 exact; unchanged after the lint-only edits to the references |
| Slither | 80 findings, 0 High, 11 Medium all reviewed (section 8); enforced by `scripts/check_slither.py` against `scripts/slither_baseline.json` |

Toolchain: every figure above, the gas snapshot and the gas targets were produced with Foundry v1.4.4, which CI now pins. Under Foundry v1.8.4 (the `stable` channel on 2026-10-03) two things differ: each invariant suite is reported as one campaign (219 total tests instead of 235; the invariants all still run and pass), and gas is measured in isolated-transaction accounting, which puts the warm-cache oracle read at 63,897 gas. The 60,000 target (`test_gasOfPriceWithWarmCache`) holds for the in-test measurement (17,333 gas under v1.4.4) and not for the isolated-transaction figure (63,897 gas, which includes the 21,000 intrinsic cost and cold access costs). The assertion is unchanged.

Suite sizes (default profile): `SundownMarketTest` 45, `SundownGuardTest` 43, `UsMarketCalendarNamedTest` 30, `IssuerFailureTest` 19, `ChainlinkEquityOracleTest` 14, `MarketCalendarTest` 13, `MarketInvariantsTest` 10, `SimFixturesTest` 9, `GuardInvariantsTest` 8, `MarketReferenceTest` 8, `UsMarketCalendarDifferentialTest` 8, `UsMarketCalendarPropertyTest` 7, `WindowCacheTest` 7, `OracleMarketTest` 6, `OracleForkLiveTest` 3 (skipped without the variable), `ObservedFeedTest` 2, plus the optional fork test.

Mutation checks of the test suites (scratch edits, source restored): the guard was mutated 15 ways and all 15 were caught by the unit tests, the stateful invariants or both; the market mutation run caught 12 mutants, with the remaining non-baseline mutant an equivalent change (`maxWithdraw` is defined through `maxRedeem` in OpenZeppelin v5). Several guard mutants (bonus always ordinary, deleverage zone opening after the window start, margin ignored, required-repay rounding, the entry-escape check) were caught only by the unit tests and none only by the invariants, so the stateful suite complements the unit tests rather than replacing them.

Not tested live or on real feeds: the `Fresh`, `Stale` and `Reopening` branches of the adapter against real data (unit tests with mock feeds cover them), the boosted stress cap and deleveraging on a public chain (the forge tests and the replay cover them), and any Sundown market on Robinhood Chain.
