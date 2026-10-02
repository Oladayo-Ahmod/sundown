import type { Metadata } from "next";
import Link from "next/link";

import { SimulatedChainNotice } from "@/components/chain-ui";
import LiveMarkets from "@/components/live-markets";
import { SimBadge } from "@/components/provenance";
import { Badge } from "@/components/ui/badge";
import { CHAIN_NAME, MARKETS, RPC_URL } from "@/lib/chain";

export const metadata: Metadata = {
  title: "Markets",
  description:
    "Live read-only state of the six Sundown markets on Arbitrum Sepolia: limits, balances, halt state, the calendar window and the simulated price feeds.",
};

export default function MarketsPage() {
  return (
    <div className="space-y-8">
      <header className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Badge>Live read, {CHAIN_NAME}</Badge>
          <SimBadge>Simulated tokens and feeds</SimBadge>
          <Badge variant="outline">Read-only: no wallet, no transactions</Badge>
        </div>
        <h1 className="text-3xl font-bold tracking-tight">Markets on Arbitrum Sepolia</h1>
        <p className="max-w-3xl text-muted-foreground">
          The {MARKETS.length} deployed Sundown markets, read directly from the contracts: four standard 86% markets
          (SPY, AAPL, NVDA, TSLA), the AAPL session-aware market with its 93% boosted tier, and an AAPL frozen-price
          control at 93%. Balances are tiny demonstration amounts of faucet tokens.
        </p>
      </header>
      <SimulatedChainNotice live />
      <LiveMarkets />
      <p className="text-xs text-muted-foreground" data-testid="sources">
        <span className="font-semibold">Source:</span> eth_call over <code className="font-mono break-all">{RPC_URL}</code>
        ; addresses from <code className="font-mono">deployments/421614.json</code>; ABIs generated from forge output
        (<code className="font-mono">web/src/abi/</code>). The boosted market&apos;s stress cap is the shipped static rule,
        evaluated by research on <Link className="underline" href="/risk" prefetch={false}>/risk</Link>; those research numbers are simulations
        and are not measured on this deployment.
      </p>
    </div>
  );
}
