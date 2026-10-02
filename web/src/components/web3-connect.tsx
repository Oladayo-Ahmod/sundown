"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { useState } from "react";
import { ConnectButton, RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";

import { wagmiConfig } from "@/lib/wagmi";

/** Loaded lazily (only after the user asks to connect) to keep the wallet stack off page load. */
export default function Web3Connect() {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme({ accentColor: "#ff9a4d", accentColorForeground: "#1a0b03", borderRadius: "large" })}>
          <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
