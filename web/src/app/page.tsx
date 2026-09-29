import Link from "next/link";

import { N, Sources, SimBadge } from "@/components/provenance";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { gaps, headline } from "@/lib/data";
import { ci, fmt, pct } from "@/lib/format";
import { cn } from "@/lib/utils";

function q99Weekend(ticker: string): number | null {
  const row = gaps.stats.find((s) => s.ticker === ticker && s.cls === "Weekend");
  return row ? (row["loss_q99_bps"] ?? null) : null;
}

export default function Home() {
  const h = headline;
  const s93 = h.stress.cf_93;
  const s95 = h.stress.cf_95;
  const src = {
    flat: "research/results/credit_frontier_datecluster.csv",
    credit: "research/results/credit_summary.csv",
    conc: "research/results/bad_debt_regime_concentration.csv",
    ci22: "research/results/m22_headline_ci.csv",
    rates: "research/results/morpho_rates_snapshot.json",
    bt: "research/results/backtest_test_chosen.csv",
    stats: "research/results/class_stats.csv",
  };
  const spy = h.boosted_breakeven_apr_pct.SPY;
  const aapl = h.boosted_breakeven_apr_pct.AAPL;
  const m = h.measured_borrow_apr_pct;

  return (
    <div className="space-y-14">
      <section aria-labelledby="hero" className="space-y-4">
        <div className="flex flex-wrap gap-2">
          <Badge variant="outline">Research phase</Badge>
          <SimBadge>Simulation results</SimBadge>
        </div>
        <h1 id="hero" className="max-w-3xl text-3xl leading-tight font-bold tracking-tight sm:text-4xl">
          Tokenized stocks trade almost around the clock. Lending markets still price their weekend risk once.
        </h1>
        <p className="max-w-3xl text-lg leading-relaxed text-muted-foreground">
          Sundown is a research project on a session-aware credit-risk layer for tokenized-stock collateral on
          Arbitrum and Robinhood Chain. This site shows what the evidence supports, with confidence intervals,
          and what it does not.
        </p>
        <div className="flex flex-wrap gap-3 pt-1">
          <Link href="/risk" prefetch={false} className={cn(buttonVariants())}>
            See the risk evidence
          </Link>
          <Link href="/replay" prefetch={false} className={cn(buttonVariants({ variant: "outline" }))}>
            Replay real gaps
          </Link>
        </div>
      </section>

      <section aria-labelledby="problem" className="space-y-4">
        <h2 id="problem" className="text-2xl font-semibold tracking-tight">
          The problem
        </h2>
        <ul className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <li>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>The oracle goes quiet</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Chainlink&apos;s 24/5 equity feeds publish from Sunday 20:00 ET to Friday 20:00 ET and hold the
                last value across weekends and NYSE holidays. On Robinhood Chain both holidays we checked
                reopened at exactly 20:00 ET on the evening before the next trading day.
                <Sources files={["docs/DISCOVERY.md"]} note="documented and verified-onchain labels" />
              </CardContent>
            </Card>
          </li>
          <li>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>Static limits price it once</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Stock-collateral markets on Robinhood Chain&apos;s Morpho use fixed LLTVs of 38.5%, 62.5%, 77% and
                86%. A fixed number cannot tighten before a closure or react to a volatile name.
                <Sources files={["docs/DISCOVERY.md"]} note="Morpho API read, section f" />
              </CardContent>
            </Card>
          </li>
          <li>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>The gaps are real</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Over 2010 to 2026 the 99th-percentile weekend gap down (previous close to next open) was{" "}
                <N src={src.stats}>{fmt(q99Weekend("SPY"), 0)}</N> bps for SPY,{" "}
                <N src={src.stats}>{fmt(q99Weekend("AAPL"), 0)}</N> for AAPL and{" "}
                <N src={src.stats}>{fmt(q99Weekend("TSLA"), 0)}</N> for TSLA. A daily proxy overstates the
                blind exposure; it is never presented as exact.
                <Sources files={[src.stats]} />
              </CardContent>
            </Card>
          </li>
        </ul>
      </section>

      <section aria-labelledby="claims" className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 id="claims" className="text-2xl font-semibold tracking-tight">
            Three claims we can defend
          </h2>
          <SimBadge>Research simulation</SimBadge>
        </div>
        <p className="max-w-3xl text-muted-foreground">
          Bad debt is annualised, in basis points of outstanding debt, from replaying real 2018 to 2026 gaps
          against simulated markets. Intervals are 95% bootstrap CIs clustered by window date.
        </p>
        <ol className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <li>
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 1
                </Badge>
                <CardTitle>Conventional LLTVs lose almost nothing to weekend gaps</CardTitle>
                <CardDescription>So we do not claim to fix them.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  At 86% LLTV (the highest in the wild) bad debt is{" "}
                  <N src={src.flat}>{fmt(h.flat.bps_yr_86.est, 1)}</N> bps/yr, CI{" "}
                  <N src={src.flat}>{ci(h.flat.bps_yr_86.lo, h.flat.bps_yr_86.hi)}</N>. At 77% it is{" "}
                  <N src={src.credit}>{fmt(h.flat.bps_yr_77, 2)}</N> bps/yr.
                </p>
                <p>
                  Worst single window: <N src={src.credit}>{pct(h.flat.worst_window_pct_86)}</N> of debt.{" "}
                  <N src={src.conc}>{pct(h.flat.mar2020_share_pct_86, 0)}</N> of the 86% loss is one episode, March
                  2020. Our stress rule changes none of this below about 90%.
                </p>
                <Sources files={[src.flat, src.credit, src.conc]} />
              </CardContent>
            </Card>
          </li>
          <li>
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 2
                </Badge>
                <CardTitle>At higher LLTV the rule works, with enforcement</CardTitle>
                <CardDescription>Counterfactual LLTVs: no market uses them today.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  At 93% base LLTV, pre-window deleveraging cuts bad debt{" "}
                  <N src={src.flat}>{pct(s93.reduction_pct, 0)}</N> (<N src={src.flat}>{fmt(s93.flat_bps_yr)}</N>{" "}
                  to <N src={src.flat}>{fmt(s93.stress_bps_yr)}</N> bps/yr; reduction{" "}
                  <N src={src.flat}>{fmt(s93.reduction_bps_yr)}</N>, CI{" "}
                  <N src={src.flat}>{ci(s93.reduction_ci[0], s93.reduction_ci[1])}</N>). At 95%:{" "}
                  <N src={src.flat}>{pct(s95.reduction_pct, 0)}</N>.
                </p>
                <p>
                  At equal bad debt it buys <N src={src.flat}>+{fmt(s93.ltv_gain_pp)}</N> pp of LTV at 93%, CI{" "}
                  <N src={src.flat}>{ci(s93.ltv_gain_ci[0], s93.ltv_gain_ci[1])}</N>. A cap on new borrows only has
                  exactly zero effect.
                </p>
                <Sources files={[src.flat]} />
              </CardContent>
            </Card>
          </li>
          <li>
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 3
                </Badge>
                <CardTitle>Liquidation design matters more than the guard</CardTitle>
                <CardDescription>It also shows where a boosted tier is credible.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  Cutting the flat bonus from 5.5% to 2% lowers bad debt by{" "}
                  <N src={src.ci22}>{fmt(h.bonus.lltv86.reduction.est)}</N> bps/yr at 86%, CI{" "}
                  <N src={src.ci22}>{ci(h.bonus.lltv86.reduction.lo, h.bonus.lltv86.reduction.hi)}</N>, and{" "}
                  <N src={src.ci22}>{fmt(h.bonus.lltv93.reduction.est, 0)}</N> bps/yr at 93%, CI{" "}
                  <N src={src.ci22}>{ci(h.bonus.lltv93.reduction.lo, h.bonus.lltv93.reduction.hi, 0)}</N>, if
                  liquidators still act at 2%.
                </p>
                <p>
                  A boosted tier (90 to 93%) covers its added lender loss at a break-even borrow APR of{" "}
                  <N src={src.ci22}>{fmt(spy["90"].uniform.est, 1)}</N> to{" "}
                  <N src={src.ci22}>{fmt(spy["93"].clustered.est, 1)}</N>% for SPY and{" "}
                  <N src={src.ci22}>{fmt(aapl["90"].uniform.est, 1)}</N> to{" "}
                  <N src={src.ci22}>{fmt(aapl["93"].clustered.est, 1)}</N>% for AAPL. Measured USDG borrow APR on
                  Robinhood Chain (block <N src={src.rates}>{m.block}</N>): AAPL market{" "}
                  <N src={src.rates}>{fmt(m.AAPL, 2)}</N>%, large USDG markets{" "}
                  <N src={src.rates}>{fmt(m.large_usdg_markets, 2)}</N>%, but the SPY market{" "}
                  <N src={src.rates}>{fmt(m.SPY, 2)}</N>% (idle, <N src={src.rates}>{pct(100 * m.spy_util, 0)}</N>{" "}
                  utilised).
                </p>
                <Sources files={[src.ci22, src.rates]} />
              </CardContent>
            </Card>
          </li>
        </ol>
      </section>

      <section aria-labelledby="not" className="space-y-4">
        <h2 id="not" className="text-2xl font-semibold tracking-tight">
          Claims we will not make
        </h2>
        <Card>
          <CardContent className="pt-5">
            <ul className="list-disc space-y-2 pl-5 text-sm leading-relaxed marker:text-muted-foreground">
              <li>That Sundown is safer than Aave or Morpho, or that it protects conventional LLTV markets.</li>
              <li>
                That our 99% gap-VaR is calibrated: out of sample it realises{" "}
                <N src={src.bt}>{fmt(h.var99_weekend.rate_pct, 2)}</N>% on weekends (target 1%, CI{" "}
                <N src={src.bt}>{ci(h.var99_weekend.ci[0], h.var99_weekend.ci[1], 2)}</N>); March 2020 breaks it.
              </li>
              <li>
                That weekends are riskier than weeknights, or any exact size of the oracle-blind exposure: the
                daily proxy is a conservative superset.
              </li>
              <li>
                That the LTV gain generalises beyond 2018 to 2026, a sample whose tail is mostly one episode.
              </li>
              <li>
                That forced deleveraging is acceptable to borrowers, that a premium-funded gap reserve works,
                or that exit liquidity is guaranteed (one pool snapshot, no routing).
              </li>
              <li>
                That any on-chain integration is validated by this work, or anything about issuer risks (pause,
                blocklist, admin burn), which no parameter here mitigates.
              </li>
            </ul>
            <Sources files={[src.bt, "research/PITCH_EVIDENCE.md", "research/CLAIMS.md"]} />
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
