import type { Metadata } from "next";

import { EventsTable } from "@/components/events-table";
import { PairedBars } from "@/components/charts";
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
import { DEPLOY_ASSETS, replay, staticRule } from "@/lib/data";
import { fmt, pct } from "@/lib/format";

export const metadata: Metadata = {
  title: "Replay",
  description:
    "Real historical weekend and holiday gaps replayed against a flat control and the session-aware guard: a forge in-process replay and research simulations of lending-market bad debt.",
};

const SRC = {
  events: "sim/replay_events.json",
  per: "research/results/per_asset_credit.csv",
  top: "research/results/top_loss_windows.csv",
  cross: "research/results/static_replay_crosscheck.csv",
  replayDoc: "docs/REPLAY_RESULTS.md",
} as const;

const CONTROLS = [
  { id: "morpho_86", label: "86% LLTV (highest in the wild)", note: "in the wild" },
  { id: "cf_93", label: "93% LLTV (counterfactual)", note: "counterfactual" },
] as const;

export default function ReplayPage() {
  return (
    <div className="space-y-14">
      <header className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <SimBadge>Research simulation</SimBadge>
          <Badge variant="outline">Not on-chain</Badge>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">Replay: control versus Sundown</h1>
        <p className="max-w-3xl text-muted-foreground">
          Real historical weekend and holiday gaps, replayed through a <strong>simulated</strong> lending market. The
          control is a flat LLTV; the first section replays the shipped static rule on AAPL at 93%, the later sections use the time-varying research estimator (not shipped). Prices
          are real; the market, borrowers and liquidations are a model. Nothing on this page is an on-chain
          transaction.
        </p>
      </header>

      <Alert variant="simulation">
        <AlertTitle>How to read this page</AlertTitle>
        <AlertDescription>
          <p>
            Each window is one closed-market gap. Borrowers sit on a 20-point grid of utilisation of the maximum LTV;
            positions that breach the LLTV after the gap are liquidated at the post-gap price with the market&apos;s
            bonus. &ldquo;Bad debt&rdquo; is what lenders lose. Details and limits:{" "}
            <code className="font-mono">research/CLAIMS.md</code>.
          </p>
        </AlertDescription>
      </Alert>

      {/* ------------------------------------------------------------ forge replay */}
      <section aria-labelledby="forge" className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 id="forge" className="text-2xl font-semibold tracking-tight">
            The shipped rule: AAPL at 93%, 10 worst real gaps
          </h2>
          <SimBadge>Forge in-process EVM, not a public chain</SimBadge>
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Session A&apos;s replay applies each real gap once at reopen to 20 seeded borrowers (50 tokens at $100,
          debt 80-99% of the tier cap, no cures), in forge&apos;s in-process EVM with a fixture window cache and a
          simulated price feed. Three markets per event: a flat control at 93%, the session-aware market, and a
          standard 86% market. My independent Python simulation of the same scenario is shown beside it.
        </p>
        <Table aria-label="Forge replay versus Python simulation per event, AAPL 93 percent">
          <TableCaption>
            Lender loss in USDG per event: control / session-aware / standard 86%. Python uses the market&apos;s
            liquidation rule (bonus capped so a liquidation never worsens an account).
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Event</TableHead>
              <TableHead>Gap</TableHead>
              <TableHead>Forge replay</TableHead>
              <TableHead>Python (market rule)</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {staticRule.crosscheck.events.map((e) => (
              <TableRow key={e.date} data-src={SRC.cross}>
                <TableCell>
                  {e.date} ({e.cls})
                </TableCell>
                <TableCell>{fmt(e.gap_loss_pct, 2)}%</TableCell>
                <TableCell>
                  {fmt(e.forge_control, 2)} / {fmt(e.forge_session_aware, 2)} / {fmt(e.forge_standard, 2)}
                </TableCell>
                <TableCell>
                  {fmt(e.python_market_control, 2)} / {fmt(e.python_market_session_aware, 2)} / 0.00
                </TableCell>
              </TableRow>
            ))}
            <TableRow data-src={SRC.cross}>
              <TableCell className="font-semibold">Total</TableCell>
              <TableCell />
              <TableCell className="font-semibold">
                {fmt(staticRule.crosscheck.totals.forge_control, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.forge_session_aware, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.forge_standard_86, 2)}
              </TableCell>
              <TableCell className="font-semibold">
                {fmt(staticRule.crosscheck.totals.python_nonworsening_control, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.python_nonworsening_session_aware, 2)} /{" "}
                {fmt(staticRule.crosscheck.totals.python_nonworsening_standard_86, 2)}
              </TableCell>
            </TableRow>
          </TableBody>
        </Table>
        <Alert>
          <AlertTitle>What this shows, and what it does not</AlertTitle>
          <AlertDescription>
            <p>
              Against the frozen-price control at the same 93% LLTV the session-aware market lost{" "}
              <N src={SRC.replayDoc}>$1,224 over 1 event</N> instead of <N src={SRC.replayDoc}>$3,824 over 4</N>,
              at 3.9% lower in-window capacity; a standard 86% market lost nothing at 7.5% lower capacity. The
              2020-03-16 gap (13.9%) still produced a loss. SPY at 93% and AAPL at 90% do not bind and are not deployed
              as boosted. The earlier Python convention charged the full liquidation bonus and overstated the control
              (<N src={SRC.cross}>${fmt(staticRule.crosscheck.totals.python_control, 0)}</N>); with the market&apos;s rule
              the two implementations agree to 0.01%. They share the authors&apos; reading of the market&apos;s rules, so
              agreement is not fully independent.
            </p>
          </AlertDescription>
        </Alert>
        <Sources files={[SRC.cross, SRC.replayDoc]} note="forge replay numbers from docs/REPLAY_RESULTS.md" />
      </section>

      {/* ------------------------------------------------------------ per asset */}
      <section aria-labelledby="per-asset" className="space-y-4">
        <h2 id="per-asset" className="text-2xl font-semibold tracking-tight">
          Bad debt per asset, 2018 to 2026
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Annualised bad debt in basis points of outstanding debt for the four deployment assets. Control = flat LLTV;
          Research estimator = time-varying stress cap with full enforcement on existing debt (not the shipped static rule).
        </p>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {CONTROLS.map((c) => {
            const rows = DEPLOY_ASSETS.map((t) => replay.per_asset.find((r) => r.control === c.id && r.ticker === t))
              .filter((r): r is NonNullable<typeof r> => r !== undefined);
            return (
              <Card key={c.id}>
                <CardHeader>
                  <CardTitle>{c.label}</CardTitle>
                  <CardDescription>
                    <SimBadge>Simulation</SimBadge>
                  </CardDescription>
                </CardHeader>
                <CardContent>
                  <PairedBars
                    items={rows.map((r) => ({ label: r.ticker, a: r.flat_bps_yr ?? 0, b: r.stress_bps_yr ?? 0 }))}
                    aLabel="Control (flat LLTV)"
                    bLabel="Research estimator (not shipped)"
                    yLabel="bps/yr of outstanding debt"
                    label={`Annualised bad debt per asset at ${c.label}`}
                    description="Paired bars of annualised bad debt in basis points for the control and for the time-varying research estimator, per asset."
                  />
                  <Table aria-label={`Bad debt table, ${c.label}`} className="mt-3">
                    <TableHeader>
                      <TableRow>
                        <TableHead>Asset</TableHead>
                        <TableHead>Control</TableHead>
                        <TableHead>Research est.</TableHead>
                        <TableHead>Change</TableHead>
                        <TableHead>Windows cap binds</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {rows.map((r) => (
                        <TableRow key={r.ticker} data-src={SRC.per}>
                          <TableCell className="font-medium">{r.ticker}</TableCell>
                          <TableCell>{fmt(r.flat_bps_yr, 2)}</TableCell>
                          <TableCell>{fmt(r.stress_bps_yr, 2)}</TableCell>
                          <TableCell>{r.reduction_pct === null ? "no loss" : `-${pct(r.reduction_pct, 0)}`}</TableCell>
                          <TableCell>{r.windows_cap_binds}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </CardContent>
              </Card>
            );
          })}
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          At the in-the-wild 86% limit the benefit comes from TSLA and NVDA only; SPY and AAPL show none. The 93% panel
          is a counterfactual market that does not exist today.
        </p>
        <Sources files={[SRC.per]} />
      </section>

      {/* ------------------------------------------------------------ worst windows */}
      <section aria-labelledby="worst" className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <h2 id="worst" className="text-2xl font-semibold tracking-tight">
            Worst windows: lender loss, control versus the time-varying research estimator
          </h2>
          <SimBadge>Simulation</SimBadge>
        </div>
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          {CONTROLS.map((c) => {
            const rows = replay.top_windows.filter((w) => w.control === c.id).slice(0, 8);
            return (
              <Table key={c.id} aria-label={`Worst windows at ${c.label}`}>
                <TableCaption>
                  {c.label}: lender loss as % of outstanding debt in the window. The stress cap uses the VaR forecast
                  known before that window.
                </TableCaption>
                <TableHeader>
                  <TableRow>
                    <TableHead>Window</TableHead>
                    <TableHead>Asset</TableHead>
                    <TableHead>Gap</TableHead>
                    <TableHead>VaR</TableHead>
                    <TableHead>Control</TableHead>
                    <TableHead>Research est.</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((w) => (
                    <TableRow key={`${w.ticker}-${w.date}`} data-src={SRC.top}>
                      <TableCell className="whitespace-nowrap">
                        {w.date} ({w.cls})
                      </TableCell>
                      <TableCell className="font-medium">{w.ticker}</TableCell>
                      <TableCell>{fmt(w.gap_bps, 0)} bps</TableCell>
                      <TableCell>{fmt(w.var_bps, 0)} bps</TableCell>
                      <TableCell>{fmt(w.flat_loss_pct, 2)}%</TableCell>
                      <TableCell>{fmt(w.stress_loss_pct, 2)}%</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            );
          })}
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Where the realised gap exceeds the forecast VaR by a wide margin (for example JPM on 2020-03-16), the stress
          rule cannot help: no estimator forecasts a regime break.
        </p>
        <Sources files={[SRC.top]} />
      </section>

      {/* ------------------------------------------------------------ events */}
      <section aria-labelledby="events" className="space-y-4">
        <h2 id="events" className="text-2xl font-semibold tracking-tight">
          The most severe real gaps
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground">
          {replay.events_meta.selection}. These are the inputs for the future on-chain replay.
        </p>
        <EventsTable events={replay.events} />
        <Sources
          files={[SRC.events]}
          note="Yahoo Finance via yfinance; excerpt of prices, see research/DATA_PROVENANCE.md"
        />
        <p className="text-xs text-muted-foreground">
          Total shown: <N src={SRC.events}>{replay.events.length}</N> events.
        </p>
      </section>

      {/* ------------------------------------------------------------ on-chain slot */}
      <section aria-labelledby="onchain" id="onchain-replay" className="space-y-3">
        <h2 id="onchain" className="text-2xl font-semibold tracking-tight">
          On-chain replay
        </h2>
        <Card>
          <CardContent className="pt-5 text-sm leading-relaxed">
            <p>
              Reserved for the Arbitrum Sepolia demonstration: each event above will link to the transactions that
              replay it against a flat-LLTV market and a session-aware market, driven by a clearly labelled simulated price
              feed. No contracts are connected in this version.
            </p>
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
