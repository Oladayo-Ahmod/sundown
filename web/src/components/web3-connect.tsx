"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { useState } from "react";
import { ConnectButton, RainbowKitProvider, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useTheme } from "next-themes";
import { WagmiProvider } from "wagmi";

import { wagmiConfig } from "@/lib/wagmi";

/** Loaded lazily (only after the user asks to connect) to keep the wallet stack off page load. */
export default function Web3Connect() {
  const [queryClient] = useState(() => new QueryClient());
  const { resolvedTheme } = useTheme();
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={resolvedTheme === "dark" ? darkTheme() : lightTheme()}>
          <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
