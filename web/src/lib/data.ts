/**
 * Typed access to research outputs exported by `research/export_web_data.py`.
 * Each JSON block carries a `source` list; pages render it next to the numbers.
 */
import backtest from "@/data/backtest.json";
import frontier from "@/data/frontier.json";
import gaps from "@/data/gaps.json";
import headline from "@/data/headline.json";
import params from "@/data/params.json";
import replay from "@/data/replay.json";

export { backtest, frontier, gaps, headline, params, replay };

export const DEPLOY_ASSETS = ["SPY", "AAPL", "NVDA", "TSLA"] as const;
export type DeployAsset = (typeof DEPLOY_ASSETS)[number];
