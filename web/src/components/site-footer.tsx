export function SiteFooter() {
  return (
    <footer className="mt-16 border-t border-border">
      <div className="mx-auto max-w-6xl space-y-2 px-4 py-6 text-sm text-muted-foreground">
        <p>
          <strong className="text-foreground">Research simulation and a testnet demonstration.</strong> The risk and
          replay numbers are produced offline from historical equity data (a daily proxy for the oracle-blind
          exposure) or read once from Robinhood Chain. The deployment, markets and preflight pages show the production
          contracts on Arbitrum Sepolia running against simulated tokens and simulated price feeds (read-only: the
          site never sends a transaction). Nothing here is investment advice.
        </p>
        <p>
          Full evidence, confidence intervals and the list of claims we do not make:{" "}
          <code className="font-mono">research/CLAIMS.md</code>,{" "}
          <code className="font-mono">research/PITCH_EVIDENCE.md</code>.
        </p>
      </div>
    </footer>
  );
}
