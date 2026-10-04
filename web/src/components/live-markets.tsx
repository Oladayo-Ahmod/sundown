"use client";

import { KindBadge, utc } from "@/components/chain-ui";
import { SimBadge } from "@/components/provenance";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useLive } from "@/components/use-live";
import { TIER_LABEL, explorerAddress, shortAddr } from "@/lib/chain";
import { readMarketsSnapshot, type MarketView } from "@/lib/live";

function Row({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-3 border-b border-border py-1 last:border-0">
      <dt className="text-muted-foreground">{k}</dt>
      <dd className="text-right font-medium tabular-nums">{v}</dd>
    </div>
  );
}

function MarketCard({ m }: { m: MarketView }) {
  const halted = m.state !== "Active";
  return (
    <Card data-testid="market-card">
      <CardHeader>
        <CardTitle>
          s{m.ref.symbol}: {TIER_LABEL[m.ref.tier]}
        </CardTitle>
        <CardDescription>
          <a className="font-mono underline underline-offset-2" href={explorerAddress(m.ref.address)}>
            {shortAddr(m.ref.address)}
          </a>{" "}
          <span className="text-xs">({m.ref.name})</span>
        </CardDescription>
        <div className="flex flex-wrap gap-2 pt-1">
          <KindBadge kind="production" />
          <Badge variant={halted ? "deny" : "allow"}>
            {halted ? `Halted: ${m.haltReason}` : "Active"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent>
        <dl className="text-sm">
          <Row k="Guard" v={m.guardName} />
          <Row k="Liquidation LLTV" v={`${m.lltvPct}%`} />
          <Row k="Close factor / max bonus" v={`${m.closeFactorPct}% / ${m.maxBonusPct}%`} />
          <Row k="Collateral cap (demo scale)" v={m.collateralCap} />
          <Row k="Min debt" v={m.minDebt} />
          <Row k="Supplied" v={m.totalSupplyAssets} />
          <Row k="Borrowed" v={m.totalBorrowAssets} />
          <Row k="Utilisation" v={`${m.utilizationPct}%`} />
          <Row k="Collateral held" v={m.totalCollateral} />
          <Row k="Bad debt realised" v={m.badDebtRealized} />
          {m.guard ? (
            <>
              <Row k="Stress cap, Weekend window" v={`${m.guard.stressFractionWeekendPct}%`} />
              <Row k="Stress cap, Long window" v={`${m.guard.stressFractionLongPct}%`} />
              <Row k="Standard / boosted LLTV" v={`${m.guard.standardLltvPct}% / ${m.guard.boostedLltvPct}%`} />
              <Row k="Pre-window horizon / cure" v={`${m.guard.preWindowHorizonH} h / ${m.guard.cureWindowH} h`} />
              <Row k="Boosted entry disabled" v={m.guard.boostedEntryDisabled ? "yes" : "no"} />
              <Row k="Borrows blocked" v={m.guard.borrowsBlocked ? "yes" : "no"} />
            </>
          ) : null}
        </dl>
      </CardContent>
    </Card>
  );
}

export default function LiveMarkets() {
  const [s, refresh] = useLive(readMarketsSnapshot);
  const snap = s.data;
  return (
    <div className="space-y-6" data-testid="live-markets" aria-busy={s.status === "loading"}>
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <Button variant="outline" onClick={refresh} disabled={s.status === "loading"}>
          {s.status === "loading" ? "Reading chain…" : "Refresh"}
        </Button>
        {snap ? (
          <span data-testid="live-block" className="text-muted-foreground">
            Block <span className="font-mono tabular-nums">{snap.blockNumber}</span>, {utc(snap.blockTimestamp)}
          </span>
        ) : null}
        {s.status === "error" ? (
          <span role="alert" className="text-warn-fg" data-testid="live-error">
            RPC read failed: {s.error}. {snap ? "Showing the last successful read." : "Addresses are on /deployment."}
          </span>
        ) : null}
      </div>

      {snap ? (
        <>
          <p className="text-sm" data-testid="window-state">
            <strong>Calendar window:</strong>{" "}
            {snap.window.blind ? "inside" : "outside"} a <strong>{snap.window.cls}</strong> blind window;{" "}
            {snap.window.blind ? "ends" : "next starts"}{" "}
            <span className="tabular-nums">{utc(snap.window.blind ? snap.window.endUtc : snap.window.startUtc)}</span>
            {snap.window.blind ? "" : `, ends ${utc(snap.window.endUtc)}`}. This is the production calendar contract.
          </p>

          <section aria-labelledby="oracle-h" className="space-y-2">
            <h2 id="oracle-h" className="text-xl font-semibold tracking-tight">
              Price feeds <SimBadge>Simulated prices</SimBadge>
            </h2>
            <Table aria-label="Simulated price feeds and the production oracle adapter reading them">
              <TableCaption>
                The feed column is the simulated feed&apos;s owner-set answer. The adapter column is the production
                ChainlinkEquityOracle reading that simulated feed; its status is the calendar-aware verdict. None of these
                prices is a market price.
              </TableCaption>
              <TableHeader>
                <TableRow>
                  <TableHead>Asset</TableHead>
                  <TableHead>Simulated feed answer (USD)</TableHead>
                  <TableHead>Feed updated (UTC)</TableHead>
                  <TableHead>Adapter price (USD)</TableHead>
                  <TableHead>Adapter status</TableHead>
                  <TableHead>Haircut</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {snap.oracles.map((o) => (
                  <TableRow key={o.symbol} data-testid="oracle-row">
                    <TableCell className="font-medium">s{o.symbol}</TableCell>
                    <TableCell className="tabular-nums">{o.feedAnswerUsd}</TableCell>
                    <TableCell className="whitespace-nowrap tabular-nums">{utc(o.feedUpdatedAt)}</TableCell>
                    <TableCell className="tabular-nums">{o.adapterPriceUsd}</TableCell>
                    <TableCell>{o.adapterStatus}</TableCell>
                    <TableCell className="tabular-nums">{o.haircutPct}%</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </section>

          <section aria-labelledby="markets-h" className="space-y-3">
            <h2 id="markets-h" className="text-xl font-semibold tracking-tight">
              Markets
            </h2>
            <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
              {snap.markets.map((m) => (
                <MarketCard key={m.ref.name} m={m} />
              ))}
            </div>
          </section>
        </>
      ) : s.status === "loading" ? (
        <p className="text-sm text-muted-foreground">Reading the chain…</p>
      ) : null}
    </div>
  );
}
