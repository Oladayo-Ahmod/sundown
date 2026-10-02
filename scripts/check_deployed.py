#!/usr/bin/env python3
"""Check that every address in deployments/421614.json has code and, where a key is given, is verified on Arbiscan.

Markets are EIP-1167 clones: they are checked to be a minimal proxy of the recorded `SundownMarketImplementation`
(which itself must be verified). Usage: check_deployed.py DEPLOYMENTS_JSON RPC_URL [ETHERSCAN_API_KEY]
Exit 1 on any missing code, wrong clone target or unverified contract.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.request


def cast(*a: str) -> str:
    """Run cast, retrying RPC errors (public endpoints drop connections). Raises if every attempt fails, so a flaky
    RPC can never be mistaken for an empty result."""
    err = ""
    for _ in range(15):
        p = subprocess.run(["cast", *a], capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout.strip()
        err = p.stderr.strip()[:200]
        time.sleep(2)
    raise RuntimeError(f"cast {' '.join(a[:2])} failed after retries: {err}")


def verified(addr: str, key: str) -> bool:
    url = f"https://api.etherscan.io/v2/api?chainid=421614&module=contract&action=getsourcecode&address={addr}&apikey={key}"
    for _ in range(3):
        try:
            res = json.load(urllib.request.urlopen(url, timeout=30)).get("result", [{}])
            res = res[0] if isinstance(res, list) and res else {}
            return bool(res.get("SourceCode"))
        except Exception:  # network flake: retry
            time.sleep(2)
    return False


def main() -> int:
    path, rpc = sys.argv[1], sys.argv[2]
    key = sys.argv[3] if len(sys.argv) > 3 else ""
    contracts = json.load(open(path))["contracts"]
    impl = contracts.get("SundownMarketImplementation", "").lower()
    bad: list[str] = []
    for name, addr in contracts.items():
        try:
            code = cast("code", addr, "--rpc-url", rpc)
        except RuntimeError as e:
            bad.append(f"{name}: RPC error, could not read code ({e})")
            continue
        if len(code) <= 2:
            bad.append(f"{name}: no code at {addr}")
            continue
        if name.startswith("Market_"):
            want = ("0x363d3d373d3d3d363d73" + impl[2:] + "5af43d82803e903d91602b57fd5bf3").lower()
            if code.lower() != want:
                bad.append(f"{name}: not a minimal proxy of the recorded implementation")
            continue
        if key and not verified(addr, key):
            bad.append(f"{name}: NOT verified on Arbiscan ({addr})")
        time.sleep(0.25)
    note = "" if key else " (verification skipped: no ETHERSCAN_API_KEY)"
    print(f"{len(contracts)} addresses checked{note}")
    if bad:
        print("\n".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
