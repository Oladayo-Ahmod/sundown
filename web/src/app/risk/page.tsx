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
import { backtest, DEPLOY_ASSETS, frontier, gaps, headline, params } from "@/lib/data";
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
  ci22: "research/results/m22_headline_ci.csv",
} as const;

const classOrder = ["Short", "Weekend", "Long"] as const;

export default function RiskPage() {
  const cov = backtest.coverage.filter((c) => c.q === 0.99 || c.q === 0.995 || c.q === 0.999);
  const m = headline.measured_borrow_apr_pct;
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

      {/* ------------------------------------------------------------ backtest */}
      <section aria-labelledby="backtest" className="space-y-4">
        <h2 id="backtest" className="text-2xl font-semibold tracking-tight">
          Out-of-sample gap-VaR backtest (2018 to 2026)
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Estimator: {backtest.chosen} (pooled-scaled EWMA, one accumulator pair per asset). Chosen on a 2015 to 2017
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
            Equal-risk frontier
          </h2>
          <SimBadge>Research simulation</SimBadge>
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Annualised bad debt against base LLTV, 2018 to 2026. Flat markets (orange) against the stress rule with hard
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
          Calibrated parameters
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

      {/* ------------------------------------------------------------ rates */}
      <section aria-labelledby="rates" className="space-y-4">
        <h2 id="rates" className="text-2xl font-semibold tracking-tight">
          Boosted tier versus measured borrow rates
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Break-even borrow APR is the rate boosted-tier borrowers must pay for the extra interest to cover the added
          lender bad debt (30% of debt boosted, pre-window deleveraging on). Rates are one on-chain reading at block{" "}
          <N src={SRC.rates}>{m.block}</N> (Morpho Blue, Robinhood Chain), not a time series.
        </p>
        <Table aria-label="Break-even borrow APR versus measured rates">
          <TableCaption>
            Break-even APR % (95% CI, date cluster) for uniform and clustered-near-max borrowers. AAPL at 90% is the headline
            case; SPY is secondary. TSLA and NVDA are not recommended for a boosted tier (highest break-even APRs, most forced events).
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Boosted LLTV</TableHead>
              <TableHead>Uniform borrowers</TableHead>
              <TableHead>Clustered near max</TableHead>
              <TableHead>Measured borrow APR</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(
              [
                ["AAPL", "90", m.AAPL],
                ["SPY", "90", m.SPY],
                ["SPY", "93", m.SPY],
              ] as const
            ).map(([a, l, measured]) => {
              const b = headline.boosted_breakeven_apr_pct[a][l];
              return (
                <TableRow key={`${a}-${l}`}>
                  <TableCell className="font-medium">{a}</TableCell>
                  <TableCell>{l}%</TableCell>
                  <TableCell data-src={SRC.ci22}>
                    {fmt(b.uniform.est, 2)} {ci(b.uniform.lo, b.uniform.hi, 1)}
                  </TableCell>
                  <TableCell data-src={SRC.ci22}>
                    {fmt(b.clustered.est, 2)} {ci(b.clustered.lo, b.clustered.hi, 1)}
                  </TableCell>
                  <TableCell data-src={SRC.rates}>
                    {fmt(measured, 2)}% ({a} market)
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
        <p className="text-sm text-muted-foreground">
          Reference: large USDG markets borrow at <N src={SRC.rates}>{fmt(m.large_usdg_markets, 2)}</N>%. The SPY market
          is idle (<N src={SRC.rates}>{pct(100 * m.spy_util, 0)}</N> utilised) and charges{" "}
          <N src={SRC.rates}>{fmt(m.SPY, 2)}</N>%, which would not cover the break-even.
        </p>
        <Sources files={[SRC.ci22, SRC.rates]} />
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
                Break-even APRs compare expected values at one rate reading; they ignore tail clustering and reserve
                funding.
              </li>
            </ul>
          </AlertDescription>
        </Alert>
        <Sources files={["research/CLAIMS.md", "research/DATA_PROVENANCE.md"]} />
      </section>
    </div>
  );
}
