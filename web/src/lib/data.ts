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
import staticRule from "@/data/static.json";

export { backtest, frontier, gaps, headline, params, replay, staticRule };

export const DEPLOY_ASSETS = ["SPY", "AAPL", "NVDA", "TSLA"] as const;
export type DeployAsset = (typeof DEPLOY_ASSETS)[number];

export const MARKET_RULE = "market rule (deployed)";
export const OLD_CONVENTION = "M2.2 convention (upper bound)";

/** Build-time lookup: a missing row means the research export changed shape, so fail loudly. */
export function must<T>(value: T | undefined, what: string): T {
  if (value === undefined) throw new Error(`static.json is missing: ${what}`);
  return value;
}

export function lender(
  convention: string,
  ticker: string,
  tier: number,
  borrowers: "uniform" | "clustered near max",
  armPrefix: string,
) {
  return must(
    staticRule.lender.find(
      (r) =>
        r.convention === convention &&
        r.ticker === ticker &&
        r.tier === tier &&
        r.borrowers === borrowers &&
        r.arm.startsWith(armPrefix),
    ),
    `${convention} ${ticker} ${tier} ${borrowers} ${armPrefix}`,
  );
}

export function borrowerRow(
  tier: number,
  borrowers: "uniform" | "clustered near max",
  behaviour: "naive" | "rational",
) {
  return must(
    staticRule.borrower.find((r) => r.tier === tier && r.borrowers === borrowers && r.behaviour === behaviour),
    `borrower ${tier} ${borrowers} ${behaviour}`,
  );
}
