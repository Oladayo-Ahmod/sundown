export function SiteFooter() {
  return (
    <footer className="mx-auto mt-10 max-w-6xl px-4 pb-10 sm:px-6">
      <div className="glass space-y-3 p-5 text-sm leading-relaxed text-muted-foreground sm:p-6">
        <p>
          <strong className="text-foreground">Research simulation and a testnet demonstration.</strong> The risk and
          replay numbers are produced offline from historical equity data (a daily proxy for the oracle-blind
          exposure) or read once from Robinhood Chain. The deployment, markets and preflight pages show the production
          contracts on Arbitrum Sepolia running against simulated tokens and simulated price feeds (read-only: the
          site never sends a transaction). Nothing here is investment advice.
        </p>
        <p>
          Full evidence, confidence intervals and the list of claims we do not make:{" "}
          <code>research/CLAIMS.md</code>, <code>research/PITCH_EVIDENCE.md</code>.
        </p>
      </div>
    </footer>
  );
}
