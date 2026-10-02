import type { Metadata } from "next";

import { FrontierChart, GapHistogram, VarSeries } from "@/components/charts";
import { N, SimBadge, Sources } from "@/components/provenance";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { backtest, DEPLOY_ASSETS, frontier, gaps, MARKET_RULE, OLD_CONVENTION, params, staticRule } from "@/lib/data";
import { ci, fmt, pct, pValue } from "@/lib/format";

export const metadata: Metadata = {
  title: "Risk evidence",
  description:
    "Weekend and holiday gap distributions, out-of-sample VaR backtests, the equal-risk frontier and calibrated parameters for SPY, AAPL, NVDA and TSLA.",
};

const SRC = {
  gaps: "research/results/class_stats.csv",
  derived: "research/data/derived/<TICKER>.csv",
  bt: "research/results/backtest_test_chosen.csv",
  reg: "research/results/backtest_regimes_test.csv",
  het: "research/results/estimator_heterogeneity.csv",
  fr: "research/results/credit_frontier_datecluster.csv",
  frc: "research/results/credit_frontier_curve_datecluster.csv",
  params: "deployments/risk_params.json",
  rates: "research/results/morpho_rates_snapshot.json",
  gv: "research/results/static_gapvar.csv",
  lend: "research/results/static_rule_lender.csv",
  lendOld: "research/results/older_convention/static_rule_lender.csv",
  eq: "research/results/static_rule_equal_risk.csv",
  bor: "research/results/static_rule_borrower.csv",
  keep: "research/results/static_rule_keeper.csv",
  cross: "research/results/static_replay_crosscheck.csv",
  sens: "research/results/static_rule_sensitivity.csv",
} as const;

const classOrder = ["Short", "Weekend", "Long"] as const;

export default function RiskPage() {
  const cov = backtest.coverage.filter((c) => c.q === 0.99 || c.q === 0.995 || c.q === 0.999);
  return (
    <div className="space-y-14">
      <header className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Badge variant="outline">Research outputs</Badge>
          <SimBadge>Simulation</SimBadge>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">Risk evidence</h1>
        <p className="max-w-3xl text-muted-foreground">
          Everything below uses the daily proxy: the move from the previous regular close to the next regular
          open across a closed window. It overstates the true oracle-blind exposure (on a two-year hourly
          subset the extended-hours bracket carried 58% of the proxy&apos;s second moment) and is never presented
          as exact. Each block lists the files its numbers come from.
        </p>
      </header>

      {/* ------------------------------------------------------------ gap distributions */}
      <section aria-labelledby="gaps" className="space-y-4">
        <h2 id="gaps" className="text-2xl font-semibold tracking-tight">
          Gap distributions
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Share of windows by gap size (log scale), 2010 to 2026. Ordinary overnights are shown for scale only: under the
          trading-day rule weeknights are not blind.
        </p>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {DEPLOY_ASSETS.map((t) => {
            const h = gaps.hist[t];
            return (
              <Card key={t}>
                <CardHeader>
                  <CardTitle>{t}</CardTitle>
                  <CardDescription>
                    {h.Weekend.n.toLocaleString("en-US")} weekend windows, {h.Long.n} long, {h.Overnight.n.toLocaleString("en-US")} ordinary overnights
                  </CardDescription>
                </CardHeader>
                <CardContent>
                  <GapHistogram
                    edges={gaps.bin_edges_bps}
                    series={[
                      { name: "Overnight", color: "var(--chart-1)", density: h.Overnight.density },
                      { name: "Weekend", color: "var(--chart-2)", density: h.Weekend.density },
                      { name: "Long weekend", color: "var(--chart-4)", density: h.Long.density },
                    ]}
                    label={`${t} gap distribution by window class`}
                    description={`Step histogram of ${t} gaps in basis points for overnight, weekend and long-weekend windows on a log scale.`}
                  />
                </CardContent>
              </Card>
            );
          })}
        </div>
        <Table aria-label="Gap statistics by asset and class">
          <TableCaption>Downside quantiles are losses in bps (positive = price fell). n = number of windows.</TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>n</TableHead>
              <TableHead>Std (bps)</TableHead>
              <TableHead>Excess kurtosis</TableHead>
              <TableHead>99% loss</TableHead>
              <TableHead>99.5% loss</TableHead>
              <TableHead>Worst</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {gaps.stats
              .filter((s) => s.cls !== "Overnight")
              .sort((a, b) => DEPLOY_ASSETS.indexOf(a.ticker as never) - DEPLOY_ASSETS.indexOf(b.ticker as never))
              .map((s) => (
                <TableRow key={`${s.ticker}-${s.cls}`}>
                  <TableCell className="font-medium">{s.ticker}</TableCell>
                  <TableCell>{s.cls}</TableCell>
                  <TableCell>{s.n}</TableCell>
                  <TableCell data-src={SRC.gaps}>{fmt(s.std_bps, 0)}</TableCell>
                  <TableCell data-src={SRC.gaps}>{fmt(s.excess_kurtosis, 1)}</TableCell>
                  <TableCell data-src={SRC.gaps}>{fmt(s["loss_q99_bps"], 0)}</TableCell>
                  <TableCell data-src={SRC.gaps}>{fmt(s["loss_q99.5_bps"], 0)}</TableCell>
                  <TableCell data-src={SRC.gaps}>{fmt(s.worst_bps, 0)}</TableCell>
                </TableRow>
              ))}
          </TableBody>
        </Table>
        <Sources files={[SRC.gaps, SRC.derived]} note="histograms recomputed from the committed derived return series" />
      </section>

      {/* ------------------------------------------------------------ shipped static rule */}
      <section aria-labelledby="shipped" className="space-y-5">
        <div className="flex flex-wrap items-center gap-3">
          <h2 id="shipped" className="text-2xl font-semibold tracking-tight">
            The shipped static rule (AAPL and SPY, tiers 90% and 93%)
          </h2>
          <SimBadge>Research simulation</SimBadge>
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          From 6 h before a blind window until the window has ended and a fresh price has arrived, a boosted account&apos;s cap is the tier LLTV or{" "}
          1 - gapVaR[class] - 0.5% - 1%, whichever is lower, with gapVaR the static full-sample q99.5 gap (includes
          March 2020). Accounts above the cap get a 3 h cure window, then anyone can deleverage them to the cap minus a 0.5% margin at a
          2% fee. Standard accounts are never touched. This evaluation is <strong>in-sample for the cap</strong>. Bad
          debt is bps of outstanding debt per year over 914 windows 2010-2026; 95% CIs clustered by window date.
        </p>

        <h3 className="text-lg font-semibold">Which tiers bind</h3>
        <Table aria-label="Static gapVaR and stress cap by asset and class">
          <TableCaption>The cap binds when the stress fraction is below the tier LLTV. SPY never binds.</TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>n</TableHead>
              <TableHead>gapVaR q99.5 (bps)</TableHead>
              <TableHead>Stress fraction</TableHead>
              <TableHead>Binds 90%</TableHead>
              <TableHead>Binds 93%</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.gapvar.map((g) => (
              <TableRow key={`${g.ticker}-${g.cls}`} data-src={SRC.gv}>
                <TableCell className="font-medium">{g.ticker}</TableCell>
                <TableCell>{g.cls}</TableCell>
                <TableCell>{g.n}</TableCell>
                <TableCell>{fmt(g.gap_var_bps, 2)}</TableCell>
                <TableCell>{pct(g.stress_fraction_pct, 2)}</TableCell>
                <TableCell>{g.binds_90 ? `yes (${fmt(g.tightening_pp_90, 2)} pp)` : "no"}</TableCell>
                <TableCell>{g.binds_93 ? `yes (${fmt(g.tightening_pp_93, 2)} pp)` : "no"}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>

        <h3 className="text-lg font-semibold">Lender outcome: bad debt, bps/yr</h3>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Arms: flat market at the tier LLTV; boosted tier with the rule for borrowers who never adjust (naive) and
          for borrowers who repay to the cap before each window (rational); flat market at the weekend-cap level.
          Primary numbers use the deployed market&apos;s liquidation rule (bonus capped so a liquidation never worsens an
          account); the older convention (full bonus) is an upper bound.
        </p>
        {([MARKET_RULE, OLD_CONVENTION] as const).map((conv) => (
          <Table key={conv} aria-label={`Lender bad debt, ${conv}`}>
            <TableCaption>
              Liquidation convention: {conv}. SPY rows are identical across arms because the cap never binds.
            </TableCaption>
            <TableHeader>
              <TableRow>
                <TableHead>Asset</TableHead>
                <TableHead>Tier</TableHead>
                <TableHead>Borrowers</TableHead>
                <TableHead>Flat at tier</TableHead>
                <TableHead>Boosted + rule, naive</TableHead>
                <TableHead>Boosted + rule, rational</TableHead>
                <TableHead>Flat at weekend cap</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(["AAPL", "SPY"] as const).flatMap((t) =>
                ([90, 93] as const).flatMap((tier) =>
                  (["uniform", "clustered near max"] as const).map((b) => {
                    const row = (prefix: string) => {
                      const r = staticRule.lender.find(
                        (x) =>
                          x.convention === conv &&
                          x.ticker === t &&
                          x.tier === tier &&
                          x.borrowers === b &&
                          x.arm.startsWith(prefix),
                      );
                      return r ? `${fmt(r.bps, 2)} ${ci(r.lo, r.hi, 1)}` : "n/a";
                    };
                    return (
                      <TableRow key={`${t}-${tier}-${b}`} data-src={conv === MARKET_RULE ? SRC.lend : SRC.lendOld}>
                        <TableCell className="font-medium">{t}</TableCell>
                        <TableCell>{tier}%</TableCell>
                        <TableCell>{b}</TableCell>
                        <TableCell>{row("A flat")}</TableCell>
                        <TableCell>{row("B boosted + rule, naive")}</TableCell>
                        <TableCell>{row("B boosted + rule, rational")}</TableCell>
                        <TableCell>{row("C flat")}</TableCell>
                      </TableRow>
                    );
                  }),
                ),
              )}
            </TableBody>
          </Table>
        ))}
        <Alert>
          <AlertTitle>Equal-bad-debt comparison, stated plainly</AlertTitle>
          <AlertDescription>
            <p>
              The rule cuts AAPL 93% bad debt against an unprotected flat market at the tier LLTV, but it is{" "}
              <strong>not distinguishable from simply running a flat market at the 89.35% weekend-cap level</strong>.
              At equal lender bad debt it buys at most about 3.5 pp of LTV at 93% and nothing distinguishable from zero
              at 90% (table below). SPY: the rule never binds, so a boosted SPY tier is an unprotected flat market.
            </p>
          </AlertDescription>
        </Alert>
        <Table aria-label="Equal-bad-debt LTV gain, AAPL, market rule">
          <TableCaption>AAPL, borrowers uniform, market rule. The weekend-cap level is 89.35%.</TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Tier</TableHead>
              <TableHead>Borrowers</TableHead>
              <TableHead>Equal-risk flat LLTV</TableHead>
              <TableHead>LTV gain at equal bad debt (pp)</TableHead>
              <TableHead>Extra weekday capacity offered (pp)</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.equal_risk.map((e) => (
              <TableRow key={`${e.tier}-${e.arm}`} data-src={SRC.eq}>
                <TableCell>{e.tier}%</TableCell>
                <TableCell>{e.arm.includes("naive") ? "naive" : "rational"}</TableCell>
                <TableCell>{fmt(e.equivalent_flat_lltv_pct, 2)}%</TableCell>
                <TableCell>
                  {fmt(e.gain_pp, 2)} {ci(e.lo, e.hi, 2)}
                </TableCell>
                <TableCell>{fmt(e.extra_weekday_pp, 2)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>

        <h3 className="text-lg font-semibold">Borrower behaviour and cost (AAPL)</h3>
        <Table aria-label="Borrower economics of the shipped rule, AAPL">
          <TableCaption>
            Naive borrowers never adjust; rational borrowers repay to the cap before each window (their funds are
            assumed at hand, which is the optimistic case). Fee 2%. The measured AAPL borrow APR is 7.83% at 99.99%
            utilisation (on-chain read).
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Tier</TableHead>
              <TableHead>Borrowers</TableHead>
              <TableHead>Behaviour</TableHead>
              <TableHead>Forced events per borrower-year (avg)</TableHead>
              <TableHead>Near-max borrower, per year</TableHead>
              <TableHead>Fee cost, % of debt per year</TableHead>
              <TableHead>Extra weekday capacity used (pp)</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.borrower.map((b) => (
              <TableRow key={`${b.tier}-${b.borrowers}-${b.behaviour}`} data-src={SRC.bor}>
                <TableCell>{b.tier}%</TableCell>
                <TableCell>{b.borrowers}</TableCell>
                <TableCell>{b.behaviour}</TableCell>
                <TableCell>{fmt(b.flagged_per_borrower_yr, 2)}</TableCell>
                <TableCell>{fmt(b.flagged_per_yr_top_bucket, 0)}</TableCell>
                <TableCell>{fmt(b.fee_pct_debt_yr, 2)}</TableCell>
                <TableCell>{fmt(b.used_extra_pp, 2)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <p className="max-w-3xl text-sm text-muted-foreground">
          An account at the cap is in the stress period {fmt(staticRule.borrower[0]?.stress_time_pct ?? null, 1)}% of
          the time (6 h horizon plus the window). Rational borrowers pay no fee but must repay before every window for
          at most 3.65 pp of extra weekday capacity at 93% (0.65 pp at 90%).
        </p>

        <h3 className="text-lg font-semibold">Cross-check against the forge replay</h3>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Same scenario: AAPL 93%, the 10 worst real gaps, 20 seeded borrowers, one gap at reopen, fee 2%, no cures.
          The forge replay runs in forge&apos;s in-process EVM with a fixture window cache, <strong>not on a public
          chain</strong>. The earlier liquidation convention charged the full bonus and overstated the control by 45%;
          with the market&apos;s non-worsening bonus cap the two implementations agree to 0.01% (they share the authors&apos; reading of the market&apos;s rules, so the agreement is not fully independent).
        </p>
        <Table aria-label="Forge replay versus Python simulation, AAPL 93 percent">
          <TableCaption>Lender loss in USDG per event (control / session-aware). Events with no loss in either are omitted.</TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Event</TableHead>
              <TableHead>Gap</TableHead>
              <TableHead>Forge</TableHead>
              <TableHead>Python, market rule</TableHead>
              <TableHead>Python, earlier convention</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.crosscheck.events
              .filter((e) => (e.forge_control ?? 0) > 0 || (e.python_convention_control ?? 0) > 0)
              .map((e) => (
                <TableRow key={e.date} data-src={SRC.cross}>
                  <TableCell>
                    {e.date} ({e.cls})
                  </TableCell>
                  <TableCell>{fmt(e.gap_loss_pct, 2)}%</TableCell>
                  <TableCell>
                    {fmt(e.forge_control, 2)} / {fmt(e.forge_session_aware, 2)}
                  </TableCell>
                  <TableCell>
                    {fmt(e.python_market_control, 2)} / {fmt(e.python_market_session_aware, 2)}
                  </TableCell>
                  <TableCell>
                    {fmt(e.python_convention_control, 2)} / {fmt(e.python_convention_session_aware, 2)}
                  </TableCell>
                </TableRow>
              ))}
            <TableRow data-src={SRC.cross}>
              <TableCell className="font-semibold">Total (10 events)</TableCell>
              <TableCell />
              <TableCell>
                {fmt(staticRule.crosscheck.totals.forge_control, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.forge_session_aware, 2)}
              </TableCell>
              <TableCell>
                {fmt(staticRule.crosscheck.totals.python_nonworsening_control, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.python_nonworsening_session_aware, 2)}
              </TableCell>
              <TableCell>
                {fmt(staticRule.crosscheck.totals.python_control, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.python_session_aware, 2)}
              </TableCell>
            </TableRow>
          </TableBody>
        </Table>

        <h3 className="text-lg font-semibold">The benefit depends on hindsight</h3>
        <Table aria-label="In-sample versus out-of-sample cap, AAPL">
          <TableCaption>
            AAPL, borrowers uniform, market rule, bad debt bps/yr. The shipped gapVaR contains March 2020; the
            out-of-sample row applies a gapVaR estimated on 2010-2017 to 2018+ windows.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Case</TableHead>
              <TableHead>Tier</TableHead>
              <TableHead>Flat at tier</TableHead>
              <TableHead>Rule, naive</TableHead>
              <TableHead>Rule, rational</TableHead>
              <TableHead>Flat at weekend cap</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.hindsight.map((h2) => (
              <TableRow key={`${h2.case}-${h2.tier}`} data-src={SRC.sens}>
                <TableCell>{h2.case}</TableCell>
                <TableCell>{h2.tier}%</TableCell>
                <TableCell>{fmt(h2.flat, 2)}</TableCell>
                <TableCell>{fmt(h2.naive, 2)}</TableCell>
                <TableCell>{fmt(h2.rational, 2)}</TableCell>
                <TableCell>{fmt(h2.flat_at_cap, 2)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>

        <h3 className="text-lg font-semibold">Keeper break-even</h3>
        <Table aria-label="Keeper break-even fee from exact Uniswap v3 depth">
          <TableCaption>
            Average slippage to sell the notional (direct Uniswap v3 reads, `docs/DISCOVERY.md` section g) plus 5
            bps gas. The 2% default fee covers up to about ${fmt(staticRule.keeper_capacity_at_2pct.AAPL ?? null, 0)}{" "}
            (AAPL) and ${fmt(staticRule.keeper_capacity_at_2pct.SPY ?? null, 0)} (SPY) per round; the deleverage batches
            in the replay are $0.6k to $15k.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Notional sold</TableHead>
              <TableHead>Average slippage</TableHead>
              <TableHead>Break-even fee</TableHead>
              <TableHead>2% covers</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.keeper
              .filter((k) => [10000, 50000, 100000, 150000, 200000].includes(k.notional_usd ?? 0))
              .map((k) => (
                <TableRow key={`${k.ticker}-${k.notional_usd}`} data-src={SRC.keep}>
                  <TableCell className="font-medium">{k.ticker}</TableCell>
                  <TableCell>${fmt(k.notional_usd, 0)}</TableCell>
                  <TableCell>{pct(k.slippage_pct, 2)}</TableCell>
                  <TableCell>{pct(k.breakeven_fee_pct, 2)}</TableCell>
                  <TableCell>{k.default_fee_covers ? "yes" : "no"}</TableCell>
                </TableRow>
              ))}
          </TableBody>
        </Table>
        <Sources
          files={[SRC.gv, SRC.lend, SRC.lendOld, SRC.eq, SRC.bor, SRC.cross, SRC.sens, SRC.keep]}
          note="all bps/yr of outstanding debt; replay numbers from docs/REPLAY_RESULTS.md"
        />
      </section>

      {/* ------------------------------------------------------------ backtest */}
      <section aria-labelledby="backtest" className="space-y-4">
        <h2 id="backtest" className="text-2xl font-semibold tracking-tight">
          Time-varying research estimator: out-of-sample gap-VaR backtest (2018 to 2026)
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          <strong>This is the research estimator, not the shipped static rule.</strong> Estimator: {backtest.chosen} (pooled-scaled EWMA, one accumulator pair per asset). Chosen on a 2015 to 2017
          validation slice; multipliers fit on 2010 to 2017; the test slice was never used to choose anything.
        </p>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {(["SPY", "TSLA"] as const).map((t) => {
            const s = backtest.series[t];
            const exc = s.loss_bps.filter((l, i) => l > (s.var99_bps[i] ?? Infinity)).length;
            return (
              <Card key={t}>
                <CardHeader>
                  <CardTitle>{t} weekend windows</CardTitle>
                  <CardDescription>
                    <N src={SRC.bt}>{exc}</N> exceedances of <N src={SRC.bt}>{s.loss_bps.length}</N> (
                    {pct((100 * exc) / s.loss_bps.length, 1)}, target 1%)
                  </CardDescription>
                </CardHeader>
                <CardContent>
                  <VarSeries
                    dates={s.date}
                    loss={s.loss_bps}
                    varBps={s.var99_bps}
                    label={`${t} weekend realised loss against the 99% gap-VaR`}
                    description={`Realised weekend gap losses in bps with the out-of-sample 99% VaR forecast and exceedances for ${t}.`}
                  />
                </CardContent>
              </Card>
            );
          })}
        </div>
        <Table aria-label="Coverage tests by class and quantile">
          <TableCaption>
            Pooled over 12 assets. Kupiec p-values ignore cross-asset dependence and are anti-conservative; read the
            cluster-bootstrap interval. Christoffersen tests independence of exceedances.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Class</TableHead>
              <TableHead>VaR level</TableHead>
              <TableHead>n</TableHead>
              <TableHead>Exceed.</TableHead>
              <TableHead>Rate</TableHead>
              <TableHead>Target</TableHead>
              <TableHead>95% CI (month cluster)</TableHead>
              <TableHead>Kupiec p</TableHead>
              <TableHead>Christoffersen p</TableHead>
              <TableHead>ES / VaR</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {classOrder.flatMap((c) =>
              cov
                .filter((r) => r.cls === c)
                .map((r) => (
                  <TableRow key={`${c}-${r.q}`} data-src={SRC.bt}>
                    <TableCell className="font-medium">{c}</TableCell>
                    <TableCell>{pct(100 * r.q, 1)}</TableCell>
                    <TableCell>{r.n}</TableCell>
                    <TableCell>{r.violations}</TableCell>
                    <TableCell>{pct(100 * r.rate, 2)}</TableCell>
                    <TableCell>{pct(100 * r.target, 1)}</TableCell>
                    <TableCell>{ci(100 * r.rate_ci_lo, 100 * r.rate_ci_hi, 2)}</TableCell>
                    <TableCell>{pValue(r.kupiec_p)}</TableCell>
                    <TableCell>{pValue(r.christoffersen_ind_p)}</TableCell>
                    <TableCell>{fmt(r.es_over_var, 2)}</TableCell>
                  </TableRow>
                )),
            )}
          </TableBody>
        </Table>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Table aria-label="99% exceedance rate by regime">
            <TableCaption>99% VaR exceedance rate by named stress regime (test slice).</TableCaption>
            <TableHeader>
              <TableRow>
                <TableHead>Regime</TableHead>
                <TableHead>n</TableHead>
                <TableHead>Exceed.</TableHead>
                <TableHead>Rate</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {backtest.regimes
                .filter((r) => r.n > 0)
                .map((r) => (
                  <TableRow key={r.regime} data-src={SRC.reg}>
                    <TableCell>{r.regime}</TableCell>
                    <TableCell>{r.n}</TableCell>
                    <TableCell>{r.violations}</TableCell>
                    <TableCell>{pct(100 * (r.rate ?? 0), 1)}</TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Table aria-label="Weekend exceedance rate by asset">
            <TableCaption>Weekend 99% exceedance rate by asset: one pooled scale hides heterogeneity.</TableCaption>
            <TableHeader>
              <TableRow>
                <TableHead>Asset</TableHead>
                <TableHead>n</TableHead>
                <TableHead>Rate</TableHead>
                <TableHead>Kupiec p</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {[...backtest.weekend_rate_by_asset]
                .sort((a, b) => (a.rate_pct ?? 0) - (b.rate_pct ?? 0))
                .map((r) => (
                  <TableRow key={r.ticker} data-src={SRC.het}>
                    <TableCell>{r.ticker}</TableCell>
                    <TableCell>{r.n}</TableCell>
                    <TableCell>{pct(r.rate_pct, 2)}</TableCell>
                    <TableCell>{pValue(r.kupiec_p)}</TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
        </div>
        <Alert>
          <AlertTitle>What this says</AlertTitle>
          <AlertDescription>
            <p>
              The 99% gap-VaR is <strong>not</strong> calibrated out of sample: it realises about 98% on weekends,
              exceedances cluster in March 2020, and the Short class fails. The 99.5% and 99.9% levels are closer
              to nominal, which is why the stress rule is specified at 99.5%.
            </p>
          </AlertDescription>
        </Alert>
        <Sources files={[SRC.bt, SRC.reg, SRC.het]} />
      </section>

      {/* ------------------------------------------------------------ frontier */}
      <section aria-labelledby="frontier" className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 id="frontier" className="text-2xl font-semibold tracking-tight">
            Time-varying research estimator: equal-risk frontier
          </h2>
          <SimBadge>Research simulation</SimBadge>
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          <strong>Time-varying research estimator, not the shipped rule.</strong> Annualised bad debt against base LLTV, 2018 to 2026 (deployed market liquidation rule; the older convention gave higher levels). Flat markets (orange) against the stress rule with hard
          pre-window deleveraging (blue). Points above 86% are counterfactual LLTVs, not observed anywhere; the
          benefit exists only if the cap is enforced on existing debt. Bands and intervals: 95%, clustered by window
          date.
        </p>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {(["UNIVERSE12", "DEPLOY4"] as const).map((g) => {
            const f = frontier.groups[g];
            return (
              <Card key={g}>
                <CardHeader>
                  <CardTitle>{g === "UNIVERSE12" ? "All 12 research assets" : "SPY, AAPL, NVDA, TSLA"}</CardTitle>
                </CardHeader>
                <CardContent>
                  <FrontierChart
                    curve={f.curve}
                    points={f.points}
                    label={`Equal-risk frontier, ${g}`}
                    description="Annualised bad debt in basis points against base LLTV for flat markets with a 95 percent band, and for the stress rule with deleveraging with 95 percent intervals."
                  />
                  <Table aria-label={`Frontier values, ${g}`} className="mt-3">
                    <TableHeader>
                      <TableRow>
                        <TableHead>Base LLTV</TableHead>
                        <TableHead>Flat</TableHead>
                        <TableHead>Sundown</TableHead>
                        <TableHead>LTV gain (pp)</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {f.points.map((p) => (
                        <TableRow key={p.base} data-src={SRC.fr}>
                          <TableCell>
                            {p.lltv_pct}%{p.kind === "counterfactual" ? " (cf.)" : ""}
                          </TableCell>
                          <TableCell>{fmt(p.flat_bps)}</TableCell>
                          <TableCell>
                            {fmt(p.treat_bps)} {ci(p.treat_ci[0], p.treat_ci[1])}
                          </TableCell>
                          <TableCell>
                            {fmt(p.gain_pp)} {ci(p.gain_ci[0], p.gain_ci[1])}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </CardContent>
              </Card>
            );
          })}
        </div>
        <Sources files={[SRC.fr, SRC.frc]} note="bps/yr of outstanding debt; cf. = counterfactual" />
      </section>

      {/* ------------------------------------------------------------ parameters */}
      <section aria-labelledby="params" className="space-y-4">
        <h2 id="params" className="text-2xl font-semibold tracking-tight">
          Time-varying research estimator: parameters (not shipped)
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          {params.estimator.name}. Recurrence: <code className="font-mono">{params.estimator.recurrence}</code>.
          Forecast: <code className="font-mono">{params.estimator.forecast}</code>. Deployment fit on the full history,
          data through {params.data_through}. Oracle buffer{" "}
          <N src={SRC.params}>{params.global.oracle_buffer_bps}</N> bps, safety buffer{" "}
          <N src={SRC.params}>{params.global.safety_buffer_bps}</N> bps.
        </p>
        <Table aria-label="Calibrated gap-risk parameters for the deployed markets">
          <TableCaption>
            Research output, not an audited or governance-approved parameter set. VaR in log bps used as a loss
            fraction (conservative). Stress cap = 1 - VaR - oracle buffer - safety buffer, capped at the LLTV.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>Class scale k</TableHead>
              <TableHead>Multiplier (99.5%)</TableHead>
              <TableHead>Gap-VaR 99.5% (bps)</TableHead>
              <TableHead>Stress cap 99.5% (bps)</TableHead>
              <TableHead>Floor (bps)</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {DEPLOY_ASSETS.flatMap((t) =>
              classOrder.map((c) => {
                const p = params.assets[t].classes[c];
                return (
                  <TableRow key={`${t}-${c}`} data-src={SRC.params}>
                    <TableCell className="font-medium">{t}</TableCell>
                    <TableCell>{c}</TableCell>
                    <TableCell>{fmt(p.class_scale_k, 2)}</TableCell>
                    <TableCell>{fmt(p.q9950.multiplier, 2)}</TableCell>
                    <TableCell>{fmt(p.q9950.gap_var_bps_at_data_end, 0)}</TableCell>
                    <TableCell>{p.q9950.stress_ltv_cap_bps.toLocaleString("en-US")}</TableCell>
                    <TableCell>{fmt(p.floor_bps_train95, 0)}</TableCell>
                  </TableRow>
                );
              }),
            )}
          </TableBody>
        </Table>
        <Sources files={[SRC.params]} />
      </section>

      {/* ------------------------------------------------------------ limitations */}
      <section aria-labelledby="limits" className="space-y-4">
        <h2 id="limits" className="text-2xl font-semibold tracking-tight">
          Limitations
        </h2>
        <Alert variant="simulation">
          <AlertTitle>Read before quoting any number</AlertTitle>
          <AlertDescription>
            <ul className="list-disc space-y-1.5 pl-5">
              <li>Daily proxy, single data vendor (Yahoo Finance), no on-chain feed comparison yet.</li>
              <li>
                The shipped cap is calibrated in-sample (full-sample q99.5 including March 2020) and does nothing when
                calibrated before March 2020; the 2020-03-16 gap still produced a loss in the forge replay, which runs in
                an in-process EVM, not on a public chain.
              </li>
              <li>
                Borrower behaviour is stylised (a 20-point utilisation grid), with no interest accrual, earnings
                calendar or issuer actions (pause, blocklist, admin burn).
              </li>
              <li>
                The 2018 to 2026 tail is mostly March 2020. Higher-LLTV results are counterfactual and depend on
                enforcement of the cap on existing debt.
              </li>
              <li>
                Liquidation slippage uses one secondary-source pool snapshot, not route-level liquidity; bonuses at or
                below 2% are untested with real keepers.
              </li>
              <li>
                Absolute bad-debt levels depend on the liquidation convention (the deployed market rule gives roughly 1-100%
                lower values than the older convention, depending on the cell); they are not forecasts.
              </li>
            </ul>
          </AlertDescription>
        </Alert>
        <Sources files={["research/CLAIMS.md", "research/DATA_PROVENANCE.md"]} />
      </section>
    </div>
  );
}
