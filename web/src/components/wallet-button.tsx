"use client";

import dynamic from "next/dynamic";
import { useState } from "react";

import { Button } from "@/components/ui/button";

const Web3Connect = dynamic(() => import("@/components/web3-connect"), {
  ssr: false,
  loading: () => (
    <Button variant="outline" size="sm" disabled>
      Loading wallet…
    </Button>
  ),
});

export function WalletButton() {
  const [armed, setArmed] = useState(false);
  if (armed) return <Web3Connect />;
  return (
    <Button
      variant="outline"
      size="sm"
      onClick={() => setArmed(true)}
      aria-label="Connect wallet (Arbitrum Sepolia, no contract calls yet)"
    >
      Connect wallet
    </Button>
  );
}
