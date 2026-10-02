import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  webpack: (config) => {
    // Optional peer deps pulled in by wallet connectors; not used in the browser bundle.
    config.externals = [...(config.externals ?? []), "pino-pretty", "lokijs", "encoding"];
    // wagmi's connectors barrel imports every connector. We only use injected wallets, so the
    // Base Account and MetaMask SDKs (with optional deps that are not installed) are stubbed out.
    config.resolve.alias = {
      ...config.resolve.alias,
      "@base-org/account": false,
      "@coinbase/cdp-sdk": false,
      "@metamask/sdk": false,
      "@react-native-async-storage/async-storage": false,
    };
    return config;
  },
};

export default nextConfig;
