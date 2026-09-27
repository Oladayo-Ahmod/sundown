"""Exit-liquidity snapshot for the deployed-subset stock tokens on Robinhood Chain (4663).

Pool discovery: DexScreener (secondary index). Depth: Uniswap v3 `liquidity()` and `slot0()`
read directly over the public RPC (verified-onchain at retrieval time), converted to the USD
value of one side's *virtual reserve in the active tick range*:
    quote-side virtual reserve  y_v = L * sqrt(P)      (in quote-token units)
Selling collateral worth X USD into a constant-product-equivalent range costs an average
slippage of about X / (X + y_v). This ignores liquidity outside the active range (which can
only reduce slippage for larger sizes) and RFQ/aggregator routing, so it is an order-of-
magnitude calibration, not a route simulation. Snapshot only: depth changes minute to minute.
"""

from __future__ import annotations

import json
import os
import subprocess
from datetime import UTC, datetime

import requests

from config import DEPLOY_SUBSET, RESULTS_DIR

RPC = "https://rpc.mainnet.chain.robinhood.com"
TOKENS = {
    "AAPL": "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
    "NVDA": "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
    "TSLA": "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
    "SPY": "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C",
}
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168".lower()
SIZES_USD = [10_000, 100_000, 1_000_000]


def cast(addr: str, sig: str) -> str:
    cast_bin = os.path.expanduser("~/.foundry/bin/cast")
    out = subprocess.run([cast_bin, "call", addr, sig, "--rpc-url", RPC], capture_output=True,
                         text=True, timeout=60)
    if out.returncode:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip().split()[0]


def snapshot() -> dict:
    rows = []
    for sym in DEPLOY_SUBSET:
        r = requests.get(f"https://api.dexscreener.com/token-pairs/v1/robinhood/{TOKENS[sym]}",
                         timeout=30)
        r.raise_for_status()
        for p in r.json():
            quote = p["quoteToken"]["address"].lower()
            row = {"asset": sym, "pool": p["pairAddress"], "dex": p["dexId"],
                   "labels": p.get("labels"), "quote": p["quoteToken"]["symbol"],
                   "price_usd": p.get("priceUsd"),
                   "dexscreener_liquidity_usd": (p.get("liquidity") or {}).get("usd"),
                   "volume_h24_usd": (p.get("volume") or {}).get("h24")}
            if quote == USDG and "v3" in (p.get("labels") or []):
                try:
                    liq = int(cast(p["pairAddress"], "liquidity()(uint128)"))
                    slot0 = "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
                    sqrtp = int(cast(p["pairAddress"], slot0))
                    token0 = cast(p["pairAddress"], "token0()(address)").lower()
                    # sqrtPriceX96 = sqrt(token1/token0) * 2^96 in raw units
                    sp = sqrtp / 2**96
                    if token0 == USDG:  # token0 = USDG(6d), token1 = stock(18d): P = stock/USDG
                        usdg_virtual = liq / sp / 1e6  # token0 virtual reserve L / sqrtP
                    else:  # token0 = stock, token1 = USDG: y_v = L * sqrtP
                        usdg_virtual = liq * sp / 1e6
                    row["active_range_quote_virtual_usd"] = usdg_virtual
                    row["slippage_pct_by_size"] = {
                        str(s): round(100 * s / (s + usdg_virtual), 3) for s in SIZES_USD}
                except Exception as e:  # noqa: BLE001 - record and continue
                    row["rpc_error"] = str(e)[:160]
            rows.append(row)
    summary = {}
    for sym in DEPLOY_SUBSET:
        us = [r for r in rows if r["asset"] == sym and r["quote"] == "USDG"
              and r.get("dexscreener_liquidity_usd")]
        tvl = sum(r["dexscreener_liquidity_usd"] for r in us)
        virt = sum(r.get("active_range_quote_virtual_usd", 0) for r in us)
        summary[sym] = {
            "usdg_pools": len(us), "usdg_pool_tvl_usd": round(tvl),
            "slippage_pct_pessimistic_cp_on_tvl": {
                str(x): round(100 * x / (x + tvl / 2), 2) for x in SIZES_USD},
            "slippage_pct_optimistic_v3_active_range": {
                str(x): round(100 * x / (x + virt), 2) for x in SIZES_USD} if virt else None}
    return {"retrieved_utc": datetime.now(UTC).isoformat(timespec="seconds"),
            "chain_id": 4663, "pool_discovery": "DexScreener (secondary)",
            "depth": "Uniswap v3 liquidity()/slot0() via public RPC (verified-onchain)",
            "per_asset_summary": summary,
            "reading": "pessimistic = constant product on half the USDG-pool TVL (ignores "
                       "concentration); optimistic = in-range virtual reserves (ignores range "
                       "exhaustion). True slippage lies between; RFQ routing not modelled.",
            "pools": rows}


if __name__ == "__main__":
    out = snapshot()
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    (RESULTS_DIR / "pool_depth_snapshot.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out["per_asset_summary"], indent=1))
