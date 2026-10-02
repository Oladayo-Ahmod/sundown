# Recommended production collateral caps (documentation only)

**These are recommendations, not deployed values.** The Arbitrum Sepolia demonstration (`docs/SEPOLIA_DEMO.md`, `deployments/421614.json`) uses simulation tokens and **10 % of these caps** as a demonstration scale. Nothing here was deployed at production size, and no production-scale liquidity claim is made except for NVDA (D15).

**Rule (D5, D9):** cap in token units = `0.5 x maxNotional(3 % slippage) / oracle price`: half of the notional that a Uniswap v3 sale can absorb at 3 % slippage, so a full liquidation of the entire cap exits within the liquidation bonus range. **Source:** `research/results/exit_liquidity.json` (`DISCOVERY.md` section g): v3 pools only, exact swap simulation selling the stock for USDG, slippage referenced to the oracle price, Robinhood Chain block 78,536,996 (a single snapshot; depth changes).

| Asset | Max notional at 1 / 3 / 5 % slippage (USD) | Oracle price at snapshot | Recommended cap (tokens) | Recommended cap (USD) | Demo cap on Sepolia (10 %) |
|---|---|---|---|---|---|
| SPY | 143,642 / 249,927 / 250,516 | 770.71 | 162.14 | 124,964 | 16 |
| AAPL | 85,822 / 196,590 / 220,049 | 333.82 | 294.45 | 98,295 | 29 |
| NVDA | 262,356 / 1,119,236 / 1,860,531 | 235.00 | 2,381.38 | 559,618 | 238 |
| TSLA | 50,602 / 189,869 / 303,970 | 370.45 | 256.27 | 94,934 | 25 |

## Reading these numbers honestly

- **NVDA is the only asset with meaningful depth.** SPY, AAPL and TSLA caps under $125k are demonstration-grade: a market of that size is a pilot, not a lending business.
- **Depth is one snapshot** of Uniswap v3 pools on Robinhood Chain, with no history. The caps must be re-derived from live depth before any real deployment and revisited as depth changes.
- **Keeper viability (D29)** depends on the same depth: for AAPL at the default 2 % deleverage fee, the replay (`docs/REPLAY_RESULTS.md`) finds a keeper can sell a deleverage batch of up to about $141k, which supports roughly $2.4 million borrowed with the replay population. At the recommended AAPL cap (about $91k of debt) deleveraging is viable; far above that, enforcement at a 2 % fee may silently not execute. SPY has no enforced tier (its stress cap does not bind).
- **The cap is a lender-risk control, not a capacity target.** The recommended caps also bound issuer-failure exposure (`THREAT_MODEL.md`: an `adminBurn` of the market's collateral is a direct loss to lenders).
- The simulated prices on Sepolia are a snapshot of the same oracle prices and are **not** live quotes.
