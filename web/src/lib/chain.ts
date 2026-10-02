/**
 * Arbitrum Sepolia deployment: addresses, labels and a READ-ONLY viem client.
 *
 * No wallet, no signer, no private key and no write call exists in this module or its callers: the client is a
 * public client over HTTP. The deployment record is copied from `deployments/421614.json` by
 * `scripts/export-chain-data.mjs`; the ABIs are generated from forge output by `scripts/export-abis.mjs`.
 */
import { createPublicClient, defineChain, http, type Address, type PublicClient } from "viem";

import deployment from "@/data/deployment.json";

export { deployment };

export const CHAIN_ID = 421614;
export const CHAIN_NAME = "Arbitrum Sepolia";
export const EXPLORER = "https://sepolia.arbiscan.io";
export const RPC_URL = process.env.NEXT_PUBLIC_ARBITRUM_SEPOLIA_RPC_URL ?? "https://sepolia-rollup.arbitrum.io/rpc";

/** Defined locally instead of importing the `viem/chains` barrel (it pulls every chain into the bundle). */
const arbitrumSepolia = defineChain({
  id: CHAIN_ID,
  name: CHAIN_NAME,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "Arbiscan", url: EXPLORER } },
  contracts: { multicall3: { address: "0xca11bde05977b3631167028862be2a173976ca11", blockCreated: 81930 } },
  testnet: true,
});

export type ContractName =keyof typeof deployment.contracts;
export type ContractKind = "production" | "simulation";

export function addr(name: ContractName): Address {
  return deployment.contracts[name] as Address;
}

/** Sim* contracts are test fixtures; everything else in the record is the production Sundown code. */
export function kindOf(name: string): ContractKind {
  return name.startsWith("Sim") ? "simulation" : "production";
}

export const KIND_LABEL: Record<ContractKind, string> = {
  production: "Production",
  simulation: "Test fixture (simulation)",
};

export const SYMBOLS = ["SPY", "AAPL", "NVDA", "TSLA"] as const;
export type Symbol = (typeof SYMBOLS)[number];

export interface MarketRef {
  name: ContractName;
  symbol: Symbol;
  tier: "standard" | "boosted_93" | "control_93";
  address: Address;
}

/** Markets in the deployment record, in a stable order (symbol, then tier). */
export const MARKETS: MarketRef[] = (Object.keys(deployment.contracts) as ContractName[])
  .filter((n) => n.startsWith("Market_"))
  .map((name) => {
    const [, symbol, ...rest] = name.split("_");
    return { name, symbol: symbol as Symbol, tier: rest.join("_") as MarketRef["tier"], address: addr(name) };
  })
  .sort((a, b) => SYMBOLS.indexOf(a.symbol) - SYMBOLS.indexOf(b.symbol) || a.tier.localeCompare(b.tier));

export const TIER_LABEL: Record<MarketRef["tier"], string> = {
  standard: "Standard 86%",
  boosted_93: "Session-aware, boosted 93%",
  control_93: "Frozen-price control 93%",
};

export const PRICE_STATUS = [
  "Fresh",
  "ScheduledBlind",
  "Reopening",
  "Stale",
  "Invalid",
  "CorporateAction",
  "SequencerDown",
] as const;
export const HALT_REASON = [
  "None",
  "Guardian",
  "CollateralPaused",
  "CollateralBlocked",
  "LoanPaused",
  "LoanFrozen",
  "CollateralShortfall",
  "ProbeFailure",
] as const;
export const MARKET_STATE = ["Active", "Halted"] as const;
export const WINDOW_CLASS = ["Short", "Weekend", "Long"] as const;

export const explorerAddress = (a: string) => `${EXPLORER}/address/${a}#code`;
export const explorerTx = (h: string) => `${EXPLORER}/tx/${h}`;
export const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

let client: PublicClient | undefined;
/** Read-only client; multicall batching is on, so concurrent reads share one RPC round trip. */
export function readClient(): PublicClient {
  client ??= createPublicClient({
    chain: arbitrumSepolia,
    transport: http(RPC_URL, { batch: true, retryCount: 2, timeout: 15_000 }),
    batch: { multicall: true },
  }) as PublicClient;
  return client;
}
