import type { Metadata } from "next";

import { SimulatedChainNotice } from "@/components/chain-ui";
import LivePreflight from "@/components/live-preflight";
import { SimBadge } from "@/components/provenance";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import forge from "@/data/forge_tests.json";
import { CHAIN_NAME } from "@/lib/chain";

export const metadata: Metadata = {
  title: "Preflight",
  description:
    "Pre-submission checks: live on-chain wiring checks against the Arbitrum Sepolia deployment and the recorded results of the offline test suites.",
};

const RECORDED = [
  {
    check: "Solidity tests (forge test)",
    result: `${forge.passed} passed, ${forge.failed} failed, ${forge.skipped} skipped (${forge.total} total, ${forge.suites} suites)`,
    note: `Recorded ${forge.recorded_on}. ${forge.note}`,
    source: "contracts/ (run: cd contracts && forge test)",
  },
  {
    check: "Chainlink fork test against Robinhood mainnet",
    result:
      "Passed once (2026-10-03 19:16 UTC, 4 of 4 fork tests, real feeds); a later full-suite run failed on a dropped connection. Optional; skipped without the RPC variable.",
    note: "Only the blind-window branch was exercised on real data; the adapter has no on-chain asset-identity check. On Sepolia it reads simulated feeds.",
    source: "contracts/test/OracleForkLive.t.sol, contracts/test/OracleFork.t.sol, docs/ORACLE_LIVE_VALIDATION.md",
  },
  {
    check: "Deployed code present at all 27 recorded addresses (21 contracts and 6 market clones)",
    result: "Pass: 27 addresses checked, 21 verified",
    note: "Every non-clone contract (21) is verified on Arbiscan; the 6 markets are EIP-1167 clones of the verified implementation (scripts/check_deployed.py, 2026-10-03).",
    source: "scripts/check_deployed.py deployments/421614.json",
  },
  {
    check: "Research tests (pytest)",
    result: "63 passed, 1 skipped",
    note: "Includes the regression test that reproduces the forge replay under the deployed liquidation rule. The skipped test is a placeholder for a Python-side comparison against the committed calendar fixture; that comparison runs in the on-chain differential tests (8 tests, all passing).",
    source: "research/tests/",
  },
  {
    check: "Research lint (ruff)",
    result: "All checks passed",
    note: "Run on research/ after the line-length fixes in the two reference files.",
    source: "research/",
  },
] as const;

export default function PreflightPage() {
  return (
    <div className="space-y-10">
      <header className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Badge>Live read, {CHAIN_NAME}</Badge>
          <SimBadge>Simulated tokens and feeds</SimBadge>
          <Badge variant="outline">Read-only</Badge>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">Preflight</h1>
        <p className="max-w-3xl text-muted-foreground">
          What was checked before this submission. The first table runs in your browser against the live deployment; the
          second lists what the offline suites reported when they were run, with the command that reproduces each.
        </p>
      </header>
      <SimulatedChainNotice live />

      <section aria-labelledby="live-h" className="space-y-3">
        <h2 id="live-h" className="text-2xl font-semibold tracking-tight">
          Live on-chain checks
        </h2>
        <LivePreflight />
      </section>

      <section aria-labelledby="rec-h" className="space-y-3">
        <h2 id="rec-h" className="text-2xl font-semibold tracking-tight">
          Recorded offline results
        </h2>
        <Table aria-label="Recorded results of offline checks">
          <TableCaption>
            Static: these were run once, not on page load. Re-run them with the listed command; scripts/preflight.sh runs
            the contract checks together.
          </TableCaption>
          <TableHeader>
            <TableRow>
              <TableHead>Check</TableHead>
              <TableHead>Result</TableHead>
              <TableHead>Note</TableHead>
              <TableHead>Source</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {RECORDED.map((r) => (
              <TableRow key={r.check} data-testid="recorded-row">
                <TableCell className="font-medium">{r.check}</TableCell>
                <TableCell>{r.result}</TableCell>
                <TableCell className="text-muted-foreground">{r.note}</TableCell>
                <TableCell>
                  <code className="font-mono text-xs break-all">{r.source}</code>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <p className="text-xs text-muted-foreground" data-testid="sources">
          <span className="font-semibold">Source:</span> <code className="font-mono">web/src/data/forge_tests.json</code>,{" "}
          <code className="font-mono">scripts/preflight.sh</code>, <code className="font-mono">scripts/check_deployed.py</code>.
        </p>
      </section>
    </div>
  );
}
