import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { CHAIN_ID, CHAIN_NAME, KIND_LABEL, type ContractKind } from "@/lib/chain";

/** Production vs "Test fixture (simulation)" label for a contract. */
export function KindBadge({ kind }: { kind: ContractKind }) {
  return <Badge variant={kind === "simulation" ? "simulation" : "default"}>{KIND_LABEL[kind]}</Badge>;
}

/** Shown on every page that displays data read from, or recorded on, the deployed contracts. */
export function SimulatedChainNotice({ live = false }: { live?: boolean }) {
  return (
    <Alert variant="simulation" data-testid="sim-notice">
      <AlertTitle>
        {live ? "Live read" : "Recorded evidence"}: {CHAIN_NAME} (chain {CHAIN_ID}), simulated tokens and price feeds
      </AlertTitle>
      <AlertDescription>
        <p>
          The Sundown contracts are the <strong>production code</strong>. Everything they hold and read here is a{" "}
          <strong>test fixture (simulation)</strong>: the loan token <code className="font-mono">SimUSDG</code> and the
          stocks <code className="font-mono">SimStock_*</code> are faucet tokens, and every price comes from{" "}
          <code className="font-mono">SimEquityFeed_*</code>, a feed whose owner sets the answer, including deliberately
          old and zero answers in the recorded run. These are not real tokens, not Chainlink feeds and not market prices.
          The deployment is at demonstration scale on a testnet.
        </p>
        <p>
          {live
            ? "Values are read from the chain by your browser with read-only eth_call requests; no wallet is used and nothing is signed or sent."
            : "Values were recorded by a scripted run; each row links to its transaction where one exists."}{" "}
          Research results elsewhere on this site (risk, replay) are simulations from historical data and are not
          measured on this deployment.
        </p>
      </AlertDescription>
    </Alert>
  );
}

export const utc = (t: number) => (t > 0 ? new Date(t * 1000).toISOString().replace("T", " ").slice(0, 19) + "Z" : "n/a");
