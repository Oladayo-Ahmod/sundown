import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { arbitrumSepolia } from "wagmi/chains";

/**
 * Wallet wiring for Arbitrum Sepolia (the demo chain). Injected wallets only: no WalletConnect
 * project id is configured, so no relay connection is made. No contract is read or written yet.
 */
const connectors = connectorsForWallets(
  [{ groupName: "Browser wallets", wallets: [injectedWallet] }],
  { appName: "Sundown (research UI)", projectId: "not-used-injected-wallets-only" },
);

export const wagmiConfig = createConfig({
  chains: [arbitrumSepolia],
  connectors,
  transports: { [arbitrumSepolia.id]: http() },
  ssr: true,
});
