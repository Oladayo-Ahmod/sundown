# Demo script (3:00)

Written for: whoever records the screen capture. It works with what exists today (the three web pages). Scenes marked **OPTIONAL** need Session A's Arbitrum Sepolia deployment and carry placeholders until then. Every number spoken is on screen or in the cited file; read the numbers exactly as written. Every boosted-tier statement describes the shipped static rule (AAPL at 93 %).

## Before recording

- Open the site: {{PENDING:vercel_url}}. If it is not deployed, run it locally from the repo root: `npx -y pnpm@12.8.1 install --frozen-lockfile`, then `cd web && npx -y pnpm@12.8.1 build && npx next start -p 3100`, and open `http://localhost:3100`.
- 1280x720 window, browser zoom 110%, light theme, notifications off, no wallet connected (do not click "Connect wallet").
- Pre-scroll once so charts and tables are rendered; start each scene from the top of its section.
- Do not improvise numbers. If a number on screen differs from this script, the screen is right: re-export with `python research/export_web_data.py` and fix the script.

## Timeline

| Time | Screen and action | Narration (read as written) | Source on screen |
|---|---|---|---|
| 0:00-0:25 | `/` hero, then slow scroll to "The problem" three cards | "Tokenized stocks trade almost around the clock. But the price feed that lending markets rely on goes quiet from Friday 8 p.m. to Sunday 8 p.m. Eastern, and on NYSE holidays. On Robinhood Chain we checked 4,716 feed updates: none landed inside a predicted blind window. Lending markets still price that risk with one static number." | `docs/DISCOVERY.md`, `docs/CALENDAR_NOTES.md` |
| 0:25-1:00 | `/` "Three claims we can defend": about 10 s on each card; point at the intervals | "Three claims, with intervals. One: at today's limits, up to 86 percent, weekend gaps cost lenders about two and a half basis points a year, so we do not claim to fix that. Two: the rule we ship, a static session-aware cap on one boosted tier, Apple at 93 percent, works as designed. In a replay of the ten worst real Apple gaps the unprotected market lost thirty-eight hundred dollars over four events; ours lost twelve hundred over one. The 2020 crash gap still produced a loss. Three: its economics are modest, and we say so." | `static_rule_lender.csv`, `static_replay_crosscheck_totals.csv`, `docs/REPLAY_RESULTS.md` |
| 1:00-1:30 | `/risk` "The shipped static rule": the "Which tiers bind" table, then the lender table (market rule), AAPL 93 % row | "This is the rule. The cap is a fixed through-the-cycle number per asset and window type. For SPY it never binds, so a boosted SPY tier is just a flat market. For Apple it binds on weekends, by three point six five points at 93 percent. Against an unprotected flat market at 93 percent it cuts bad debt from about nineteen and a half to under seven basis points a year." | `static_gapvar.csv`, `static_rule_lender.csv` |
| 1:30-1:55 | `/risk` the "Equal-bad-debt comparison, stated plainly" box, then the hindsight table | "Stated plainly: it is not distinguishable from simply running a flat market at the weekend cap. And the cap is calibrated on a sample that includes March 2020: calibrate it before that and the rule does nothing." | `static_rule_equal_risk.csv`, `static_rule_sensitivity.csv` |
| 1:55-2:25 | `/replay` section "The shipped rule: AAPL at 93%, 10 worst real gaps": the badge "Forge in-process EVM, not a public chain", then the totals row | "This replay runs in forge's in-process EVM, not on a public chain. The forge numbers and my independent Python simulation agree to a hundredth of a percent, once Python uses the market's real liquidation rule. My first version overstated the loss by forty-five percent; we kept both and explain why." | `static_replay_crosscheck.csv`, `docs/REPLAY_RESULTS.md` |
| 2:25-2:50 | `/risk` "Borrower behaviour and cost (AAPL)" table | "For borrowers it is a trade. Someone who never adjusts is deleveraged about fifty times a year, at a cost of four to twelve percent of debt a year, against a measured seven point eight three percent borrow rate on the Apple market, read on-chain. Attentive borrowers pay no fee but must repay before every weekend, for a few points of extra weekday capacity." | `static_rule_borrower.csv`, `morpho_rates_snapshot.json` |
| 2:50-3:00 | `/` "Claims we will not make" | "Everything here is simulation or a labeled measurement, and the site lists the claims we will not make." | `PITCH_EVIDENCE.md` |

Word budget: about 420 spoken words at a calm pace. If you run long, cut the 1:30-1:55 scene to the first sentence.

## OPTIONAL on-chain scenes (only if Session A delivers the deployment)

Insert after 2:25 and remove the same time from the 0:25-1:00 and 1:00-1:30 scenes (read only claim 2 and show one table). Keep the total at 3:00.

| Slot | Scene | What to show | Narration | Placeholders |
|---|---|---|---|---|
| OPT-A (+25 s) | Control versus session-aware markets on Arbitrum Sepolia | The deployed AAPL boosted 93% market and the AAPL control 93% market on the block explorer: same collateral, same loan token, different guard | "On Arbitrum Sepolia we deployed a flat control market and a session-aware market that differ only by the guard. The price feed here is a labeled simulation." | factory {{PENDING:sepolia_factory_address}}; markets {{PENDING:sepolia_market_addresses}} |
| OPT-B (+20 s) | A denied borrow above the stress cap | Open the transaction or call from the live evidence showing the boosted market denying a borrow above the cap and accepting one below it | "In the window the boosted market refuses a borrow above the stress cap and accepts one below it." | {{PENDING:sepolia_replay_tx_links}} |
| OPT-C (+20 s) | Issuer-failure halt | Trigger the permissionless issuer-failure report against a mock-paused collateral token and show the market become Halted with repay still open | "If the issuer pauses the collateral, anyone can report it and the market halts; borrowers can still repay. It cannot stop an issuer burn: that residual risk is disclosed." | {{PENDING:sepolia_halt_demo_tx}} |

What cannot be shown live before the deadline: the pre-window horizon, the cure window and deleveraging need a window start (Friday 2026-10-09 20:00 ET); say so, and point to the forge replay instead.

## After recording

Run `scripts/check_pending.sh`; put the video link into `README.md` and `docs/SUBMISSION.md`.
