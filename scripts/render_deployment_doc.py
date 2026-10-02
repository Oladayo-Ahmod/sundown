#!/usr/bin/env python3
"""Render docs/SEPOLIA_DEPLOYMENT.md (addresses, labels, creation transactions) from deployments/421614.json."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "deployments/421614.json"
OUT = ROOT / "docs/SEPOLIA_DEPLOYMENT.md"
SCAN = "https://sepolia.arbiscan.io"

SIMULATION = ("SimUSDG", "SimIssuerRegistry", "SimStock_", "SimEquityFeed_")


def kind(name: str) -> str:
    if name.startswith(SIMULATION):
        return "SIMULATION fixture"
    if name.startswith("Market_"):
        return "production (EIP-1167 clone of the implementation)"
    return "production"


def main() -> None:
    d = json.loads(SRC.read_text())
    lines = [
        "# Arbitrum Sepolia (421614) deployment",
        "",
        "Generated from `deployments/421614.json` by `scripts/render_deployment_doc.py`. **Production** contracts are the unchanged "
        "Sundown code; **SIMULATION** fixtures are test tokens and price feeds (no real tokens, no Chainlink feeds). "
        "Demonstration scale: collateral caps are 10 % of the recommended production caps (`docs/RECOMMENDED_CAPS.md`).",
        "",
        f"- Deployer / owner / governance (single key, demonstration only): `{d['deployer']}`",
        f"- Guardian (separate key; can halt and resume only while the probes pass): `{d['guardian']}`",
        f"- Config hash: `{d['configHash']}`",
        "- Verification: every non-clone contract is verified on Arbiscan; markets are minimal proxies of the verified "
        "`SundownMarketImplementation` (`scripts/check_deployed.py` checks both).",
        "",
        "| Contract | Kind | Address | Creation tx | Block |",
        "|---|---|---|---|---|",
    ]
    for name, addr in d["contracts"].items():
        tx = d["transactions"].get(name, {})
        h = tx.get("txHash", "")
        lines.append(
            f"| {name} | {kind(name)} | [{addr}]({SCAN}/address/{addr}#code) | "
            f"[{h[:10]}…]({SCAN}/tx/{h}) | {tx.get('blockNumber', '')} |"
        )
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
