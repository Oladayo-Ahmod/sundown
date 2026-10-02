import type { Metadata } from "next";

import { KindBadge, SimulatedChainNotice } from "@/components/chain-ui";
import { SimBadge } from "@/components/provenance";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import evidence from "@/data/demo_evidence.json";
import {
  CHAIN_ID,
  CHAIN_NAME,
  deployment,
  explorerAddress,
  explorerTx,
  kindOf,
  type ContractName,
} from "@/lib/chain";

export const metadata: Metadata = {
  title: "Deployment",
  description:
    "Addresses, roles and a recorded live run of the Sundown contracts on Arbitrum Sepolia, with production contracts and simulated fixtures labelled apart.",
};

const names = Object.keys(deployment.contracts) as ContractName[];
const tx = deployment.transactions as Record<string, { txHash: string; blockNumber: number }>;
const ordered = [...names].sort(
  (a, b) => Number(kindOf(a) === "simulation") - Number(kindOf(b) === "simulation") || a.localeCompare(b),
);
const SRC = {
  deploy: "deployments/421614.json",
  demo: "docs/SEPOLIA_DEMO.md",
  doc: "docs/SEPOLIA_DEPLOYMENT.md",
} as const;

export default function DeploymentPage() {
  const withTx = evidence.sections.reduce((a, s) => a + s.rows.filter((r) => r.tx).length, 0);
  return (
    <div className="space-y-12">
      <header className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Badge>
            {CHAIN_NAME} ({CHAIN_ID})
          </Badge>
          <SimBadge>Simulated tokens and feeds</SimBadge>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">Deployment on Arbitrum Sepolia</h1>
        <p className="max-w-3xl text-muted-foreground">
          {names.length} deployed addresses (21 contracts and 6 market clones): the Sundown production code, and the test fixtures (tokens, price feeds, issuer
          registry) it runs against on a testnet. The addresses below are the recorded deployment; the evidence table is a
          scripted live run against it.
        </p>
      </header>
      <SimulatedChainNotice />

      <section aria-labelledby="facts-h" className="space-y-3">
        <h2 id="facts-h" className="text-2xl font-semibold tracking-tight">
          Roles and record
        </h2>
        <Card>
          <CardContent className="pt-5 text-sm leading-relaxed">
            <dl className="grid gap-x-6 gap-y-2 sm:grid-cols-[14rem_1fr]">
              <dt className="font-medium">Deployer / owner / governance</dt>
              <dd className="font-mono break-all" data-testid="deployer">
                <a className="underline underline-offset-2" href={explorerAddress(deployment.deployer)}>
                  {deployment.deployer}
                </a>{" "}
                (single key, demonstration only)
              </dd>
              <dt className="font-medium">Guardian</dt>
              <dd className="font-mono break-all">
                <a className="underline underline-offset-2" href={explorerAddress(deployment.guardian)}>
                  {deployment.guardian}
                </a>{" "}
                (separate key; can halt, and can resume only while the probes pass)
              </dd>
              <dt className="font-medium">Config hash</dt>
              <dd className="font-mono break-all">{deployment.configHash}</dd>
              <dt className="font-medium">Record status</dt>
              <dd>{deployment.status}</dd>
              <dt className="font-medium">Scale</dt>
              <dd>Demonstration: collateral caps are 10% of the recommended production caps (docs/RECOMMENDED_CAPS.md).</dd>
            </dl>
          </CardContent>
        </Card>
        <p className="text-xs text-muted-foreground" data-testid="sources">
          <span className="font-semibold">Source:</span> <code className="font-mono">{SRC.deploy}</code>,{" "}
          <code className="font-mono">{SRC.doc}</code>
        </p>
      </section>

      <section aria-labelledby="contracts-h" className="space-y-3">
        <h2 id="contracts-h" className="text-2xl font-semibold tracking-tight">
          Contracts
        </h2>
        <Table aria-label="Deployed contracts on Arbitrum Sepolia">
          <TableCaption>
            Production contracts first, then simulation fixtures. Markets are minimal proxies of the verified
            SundownMarketImplementation.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Contract</TableHead>
              <TableHead>Kind</TableHead>
              <TableHead>Address</TableHead>
              <TableHead>Creation tx</TableHead>
              <TableHead>Block</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {ordered.map((n) => {
              const t = tx[n];
              return (
                <TableRow key={n} data-testid="contract-row">
                  <TableCell className="font-medium">{n}</TableCell>
                  <TableCell>
                    <KindBadge kind={kindOf(n)} />
                  </TableCell>
                  <TableCell className="font-mono text-xs break-all">
                    <a className="underline underline-offset-2" href={explorerAddress(deployment.contracts[n])}>
                      {deployment.contracts[n]}
                    </a>
                  </TableCell>
                  <TableCell className="font-mono text-xs">
                    {t ? (
                      <a className="underline underline-offset-2" href={explorerTx(t.txHash)}>
                        {t.txHash.slice(0, 10)}…
                      </a>
                    ) : (
                      "n/a"
                    )}
                  </TableCell>
                  <TableCell className="tabular-nums">{t?.blockNumber ?? "n/a"}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </section>

      <section aria-labelledby="run-h" className="space-y-4">
        <h2 id="run-h" className="text-2xl font-semibold tracking-tight">
          Recorded live run
        </h2>
        <p className="max-w-3xl text-sm text-muted-foreground" data-testid="run-meta">
          Run started {evidence.run_started_utc}. {withTx} rows link to their transaction. Rows with no link are reads or{" "}
          <code className="font-mono">eth_call</code> simulations; a revert shown there is the contract refusing the
          action (custom error), not a transaction. Prices come from the simulated feed. Every row carries the
          calendar&apos;s blind-window state at that moment.
        </p>
        {evidence.sections.map((s) => (
          <div key={s.n} className="space-y-2">
            <h3 className="text-lg font-semibold">
              {s.n}. {s.title}
            </h3>
            <Table aria-label={`Recorded run, section ${s.n}: ${s.title}`}>
              <TableHeader>
                <TableRow>
                  <TableHead>Time</TableHead>
                  <TableHead>Window state</TableHead>
                  <TableHead>Action</TableHead>
                  <TableHead>Result</TableHead>
                  <TableHead>Tx</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {s.rows.map((r, i) => (
                  <TableRow key={i} data-testid="evidence-row">
                    <TableCell className="text-xs whitespace-nowrap tabular-nums">
                      {r.utc}
                      <br />
                      {r.et}
                    </TableCell>
                    <TableCell className="text-xs">{r.window}</TableCell>
                    <TableCell className="text-sm">{r.action}</TableCell>
                    <TableCell className="text-sm break-words">{r.result}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {r.tx ? (
                        <a className="underline underline-offset-2" href={r.tx.url}>
                          {r.tx.hash.slice(0, 10)}…
                        </a>
                      ) : null}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        ))}
        <p className="text-xs text-muted-foreground">
          <span className="font-semibold">Source:</span> <code className="font-mono">{SRC.demo}</code> (written by{" "}
          <code className="font-mono">scripts/sepolia_demo.py</code>), parsed by{" "}
          <code className="font-mono">web/scripts/export-chain-data.mjs</code>.
        </p>
      </section>

      <section aria-labelledby="limits-h" className="space-y-3">
        <h2 id="limits-h" className="text-2xl font-semibold tracking-tight">
          What is live, what is simulated, what cannot be shown live
        </h2>
        <Card>
          <CardContent className="space-y-3 pt-5 text-sm leading-relaxed">
            <p>
              <strong>Live:</strong> the production Sundown contracts (market clones, guards, oracle adapter, window
              cache, calendar) executing real testnet transactions, with the real calendar&apos;s window state at each
              step, decoded custom-error reverts, a real liquidation, a real halt and resume.
            </p>
            <p>
              <strong>Simulated:</strong> every token (SimUSDG, SimStock for SPY, AAPL, NVDA and TSLA, SimIssuerRegistry)
              and every price feed (SimEquityFeed). The oracle adapter is the production contract pointed at a simulated
              feed. The same adapter was validated once against the real Robinhood Chain feeds (docs/ORACLE_LIVE_VALIDATION.md). The replay evidence on{" "}
              <code className="font-mono">/replay</code> runs in forge&apos;s in-process EVM, not on a public chain.
            </p>
            <p>
              <strong>Not demonstrable before the submission deadline (Sun 2026-10-04 08:59 WAT):</strong> a borrow denied by the
              stress cap of a boosted account (boosted entry is closed during a window, and the stress period starts 6 h
              before the next one, Friday 2026-10-09 14:00 ET); the pre-window horizon, cure window and deleveraging (next
              window Friday 2026-10-09 20:00 ET); and the <code className="font-mono">Stale</code> price status (the
              adapter reports ScheduledBlind inside a window). The current window ends Sun 20:00 ET. Section 4 shows the in-window capacity instead: the AAPL boosted-tier market, which
              applies its 86% standard-tier cap inside a window because boosted entry is closed, refuses a 90% borrow where
              the 93% frozen-price control allowed 92%.
            </p>
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
