"use client";

import { utc } from "@/components/chain-ui";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useLive } from "@/components/use-live";
import { readPreflight } from "@/lib/live";

export default function LivePreflight() {
  const [s, refresh] = useLive(readPreflight);
  const snap = s.data;
  const failed = snap?.checks.filter((c) => !c.ok).length ?? 0;
  return (
    <div className="space-y-4" data-testid="live-preflight" aria-busy={s.status === "loading"}>
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <Button variant="outline" onClick={refresh} disabled={s.status === "loading"}>
          {s.status === "loading" ? "Reading chain…" : "Re-run checks"}
        </Button>
        {snap ? (
          <>
            <Badge variant={failed ? "deny" : "allow"} data-testid="live-verdict">
              {failed ? `${failed} check(s) FAILED` : `All ${snap.checks.length} checks pass`}
            </Badge>
            <span className="text-muted-foreground">
              Block <span className="font-mono tabular-nums">{snap.blockNumber}</span>, {utc(snap.blockTimestamp)}
            </span>
          </>
        ) : null}
        {s.status === "error" ? (
          <span role="alert" className="text-warn-fg" data-testid="live-error">
            RPC read failed: {s.error}. {snap ? "Showing the last successful run." : "No checks could run."}
          </span>
        ) : null}
      </div>
      {snap ? (
        <Table aria-label="Live on-chain preflight checks">
          <TableCaption>
            Read-only checks run in your browser against Arbitrum Sepolia. They test the deployed wiring, not market
            safety, and they read simulated fixtures.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Check</TableHead>
              <TableHead>Result</TableHead>
              <TableHead>Detail</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {snap.checks.map((c) => (
              <TableRow key={c.id} data-testid="check-row">
                <TableCell className="font-medium">{c.label}</TableCell>
                <TableCell>
                  <Badge variant={c.ok ? "allow" : "deny"}>{c.ok ? "PASS" : "FAIL"}</Badge>
                </TableCell>
                <TableCell className="break-all text-muted-foreground">{c.detail}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : s.status === "loading" ? (
        <p className="text-sm text-muted-foreground">Reading the chain…</p>
      ) : null}
    </div>
  );
}
