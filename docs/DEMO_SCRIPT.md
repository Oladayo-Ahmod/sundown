# Demo script (3:00)

Written for: whoever records the screen capture. It works with what exists today (the three web pages). Scenes marked **OPTIONAL** need Session A's Arbitrum Sepolia deployment and carry placeholders until then. Every number spoken is on screen or in the cited file; read the numbers exactly as written.

## Before recording

- Open the site: {{PENDING:vercel_url}}. If it is not deployed, run it locally from the repo root: `npx -y pnpm@12.8.1 install --frozen-lockfile`, then `cd web && npx -y pnpm@12.8.1 build && npx next start -p 3100`, and open `http://localhost:3100`.
- 1280x720 window, browser zoom 110%, light theme, notifications off, no wallet connected (do not click "Connect wallet").
- Pre-scroll once so charts are rendered; start each scene from the top of its section.
- Do not improvise numbers. If a number on screen differs from this script, the screen is right: re-export with `python research/export_web_data.py` and fix the script.

## Timeline

| Time | Screen and action | Narration (read as written) | Source on screen |
|---|---|---|---|
| 0:00-0:25 | `/` hero, then slow scroll to "The problem" three cards | "Tokenized stocks trade almost around the clock. But the price feed that lending markets rely on goes quiet from Friday 8 p.m. to Sunday 8 p.m. Eastern, and on NYSE holidays. On Robinhood Chain we checked 4,716 feed updates: none landed inside a predicted blind window. Lending markets still price that risk with one static number." | `docs/DISCOVERY.md`, `docs/CALENDAR_NOTES.md` |
| 0:25-1:00 | `/` "Three claims we can defend": pause on each card for about 10 s; point at the confidence intervals | "Here is what the evidence says, with confidence intervals. One: at the limits used today, up to 86 percent, weekend gaps cost lenders about four and a half basis points a year. So we do not claim to fix that. Two: at higher limits the session-aware rule works when it is enforced; at a counterfactual 93 percent it cuts bad debt 41 percent. Three: liquidation design matters more than the guard." | `credit_frontier_datecluster.csv`, `m22_headline_ci.csv` |
| 1:00-1:30 | `/risk` "Gap distributions" (SPY and AAPL charts), then "Out-of-sample gap-VaR backtest" (SPY chart) | "These are real weekend gaps from 2010 to 2026. Our 99 percent value-at-risk forecast is not calibrated: out of sample it is exceeded 1.87 percent of the time on weekends, and March 2020 breaks it. We show that instead of hiding it." | `class_stats.csv`, `backtest_test_chosen.csv` |
| 1:30-1:50 | `/risk` "Equal-risk frontier" (All 12 assets chart); hover is not needed, point at the blue points above 90 | "Flat markets in orange, the stress rule with deleveraging in blue. The benefit only appears above about 90 percent, and those limits do not exist in any market today." | `credit_frontier_datecluster.csv` |
| 1:50-2:20 | `/replay` banner "Research simulation", then "Bad debt per asset" (86 percent panel, then 93 percent panel), then "Worst windows" first rows | "The replay page runs real historical gaps through a simulated market, clearly labeled. At the real 86 percent limit the difference is small. At a counterfactual 93 percent the rule helps, except where the gap beats the forecast: the March 2020 weekend shows what no estimator can foresee." | `per_asset_credit.csv`, `top_loss_windows.csv` |
| 2:20-2:50 | `/risk` "Boosted tier versus measured borrow rates" table, AAPL row first, then SPY | "The one case we would put forward is a boosted tier for Apple at 90 percent. The added lender loss breaks even at a borrow rate between 1.4 and 3.7 percent. The measured rate on the Apple market, read on-chain, is 7.83 percent at 99.99 percent utilization. SPY is secondary, but its market is idle." | `m22_headline_ci.csv`, `morpho_rates_snapshot.json` |
| 2:50-3:00 | `/` "Claims we will not make" | "Everything here is simulation or a labeled measurement, and the site lists the claims we will not make." | `PITCH_EVIDENCE.md` |

Word budget: about 410 spoken words at a calm pace. If you run long, cut the 1:30-1:50 scene first.

## OPTIONAL on-chain scenes (only if Session A delivers the deployment)

Insert after 2:20 and remove the same time from the 0:25-1:00 and 1:00-1:30 scenes (read only claim 1 and claim 2; show one chart). Keep the total at 3:00.

| Slot | Scene | What to show | Narration | Placeholders |
|---|---|---|---|---|
| OPT-A (+25 s) | Control versus Sundown markets on Arbitrum Sepolia | The two deployed markets on the block explorer: same collateral, same loan token, different guard | "On Arbitrum Sepolia we deployed a flat control market and a Sundown market that differ only by the guard. The price feed here is a labeled simulation." | factory {{PENDING:sepolia_factory_address}}; markets {{PENDING:sepolia_market_addresses}} |
| OPT-B (+20 s) | Replay of one real gap | Open one replay transaction from the `/replay` on-chain slot; show the market state before and after | "This transaction replays a real historical gap against both markets." | {{PENDING:sepolia_replay_tx_links}} |
| OPT-C (+20 s) | Issuer-failure halt | Trigger the permissionless issuer-failure report against a mock-paused collateral token and show the market become Halted with repay still open | "If the issuer pauses the collateral, anyone can report it and the market halts; borrowers can still repay. It cannot stop an issuer burn: that residual risk is disclosed." | {{PENDING:sepolia_halt_demo_tx}} |

## After recording

Run `scripts/check_pending.sh`; put the video link into `README.md` and `docs/SUBMISSION.md`.
