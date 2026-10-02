#!/usr/bin/env python3
"""Merge transaction hashes and block numbers from the forge broadcast artifacts into deployments/421614.json.

`DeploySepolia.s.sol` (run with WRITE_DEPLOYMENT=true) writes the addresses; the broadcast artifact
(`contracts/broadcast/DeploySepolia.s.sol/421614/run-latest.json`, git-ignored) holds the transactions. This script
adds, per address, the creating transaction hash and block, and keeps earlier entries so that an idempotent
re-run only adds what it deployed.

Usage: python scripts/finalize_deployment.py [--broadcast PATH] [--out PATH]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BROADCAST = ROOT / "contracts/broadcast/DeploySepolia.s.sol/421614/run-latest.json"
DEFAULT_OUT = ROOT / "deployments/421614.json"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--broadcast", type=Path, default=DEFAULT_BROADCAST)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    doc = json.loads(args.out.read_text())
    run = json.loads(args.broadcast.read_text())
    names = {addr.lower(): name for name, addr in doc["contracts"].items()}
    receipts = {r["transactionHash"].lower(): r for r in run.get("receipts", [])}

    txs = doc.setdefault("transactions", {})
    for tx in run.get("transactions", []):
        created = []
        if tx.get("contractAddress"):
            created.append(tx["contractAddress"])
        created += [c["address"] for c in tx.get("additionalContracts", []) if c.get("address")]
        for addr in created:
            name = names.get(addr.lower())
            if not name:
                continue
            h = tx["hash"]
            rcpt = receipts.get(h.lower(), {})
            block = rcpt.get("blockNumber")
            txs[name] = {
                "address": addr,
                "txHash": h,
                "blockNumber": int(block, 16) if isinstance(block, str) else block,
                "status": rcpt.get("status"),
            }
    doc["transactions"] = dict(sorted(txs.items()))
    missing = [n for n in doc["contracts"] if n not in txs]
    doc["transactionsMissing"] = missing
    args.out.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"updated {args.out}: {len(txs)} transactions recorded, {len(missing)} contracts without a recorded creation tx")
    if missing:
        print("  (previously deployed contracts keep their earlier entry; check:", ", ".join(missing), ")")


if __name__ == "__main__":
    main()
