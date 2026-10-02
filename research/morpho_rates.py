"""Measured USDG borrow rates and utilisation on Morpho Blue markets on Robinhood Chain (4663).

Market ids come from the Morpho GraphQL API (enumeration only). **Every number below is read
on-chain** at the block recorded in the output: `market(id)` for totals, `idToMarketParams(id)`
for loan/collateral/oracle/IRM/LLTV, and the market's IRM `borrowRateView(params, market)` for
the instantaneous per-second borrow rate (WAD). Borrow APR is the Morpho convention
exp(rate * 365d) - 1; supply APR = borrow APR * utilisation * (1 - fee). Snapshot only: rates
move with utilisation (adaptive-curve IRMs), so this is a point reading, not a time series.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
from datetime import UTC, datetime

from config import RESULTS_DIR

RPC = "https://rpc.mainnet.chain.robinhood.com"
MORPHO = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010"
CAST = os.path.expanduser("~/.foundry/bin/cast")
YEAR = 365 * 24 * 3600
MARKETS = {  # id -> label (from the Morpho API enumeration; verified on-chain below)
    "AAPL": "0xdeb4782d012d5fd3b24962538c2f6559049d70bda4dabd2e4212dacb96c28d45",
    "SPY": "0x50bc39b5722fb5634c436d74c6787f3c125b879e7b73cf9e9ecc01bbb57b8e55",
    "NVDA": "0x8b16891f032a93b771347c9cb470a780e6699dd701553d3402aa3cdba6189c3e",
    "GOOGL": "0x7fa81b10e5d21b2e4c571f862442bc11aff2ed14f02335868d0ff933fd40d0ba",
    "ref:USDe(91.5%)": "0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6",
    "ref:syrupUSDG(91.5%)": "0x919a9b6b94dae7c86620eaf7a08e597aae8a4c3a9e9c7671771fbaf62b6b61c7",
}


def call(*args: str) -> list[str]:
    out = subprocess.run([CAST, *args, "--rpc-url", RPC], capture_output=True, text=True,
                         timeout=60)
    if out.returncode:
        raise RuntimeError(out.stderr.strip()[:300])
    return [x.strip().split()[0] for x in out.stdout.strip().split("\n") if x.strip()]


def read_market(mid: str) -> dict:
    p = call("call", MORPHO, "idToMarketParams(bytes32)(address,address,address,address,uint256)",
             mid)
    loan, coll, oracle, irm, lltv = p
    m = [int(v) for v in call("call", MORPHO,
                              "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)",
                              mid)]
    supply, _, borrow, _, last_update, fee = m
    row = {"loan": loan, "collateral": coll, "oracle": oracle, "irm": irm,
           "lltv": int(lltv) / 1e18, "total_supply_usdg": supply / 1e6,
           "total_borrow_usdg": borrow / 1e6, "fee": fee / 1e18, "last_update": last_update}
    row["utilisation"] = borrow / supply if supply else None
    params = f"({loan},{coll},{oracle},{irm},{lltv})"
    market = "(" + ",".join(str(v) for v in m) + ")"
    rate = int(call("call", irm,
                    "borrowRateView((address,address,address,address,uint256),"
                    "(uint128,uint128,uint128,uint128,uint128,uint128))(uint256)",
                    params, market)[0])
    row["borrow_rate_per_sec_wad"] = rate
    apr = math.expm1(rate / 1e18 * YEAR)
    row["borrow_apr_pct"] = 100 * apr
    row["supply_apr_pct"] = 100 * apr * (borrow / supply if supply else 0) * (1 - fee / 1e18)
    return row


def main() -> None:
    block = int(call("block-number")[0])
    ts = int(call("block", "latest", "--field", "timestamp")[0])
    rows = {}
    for label, mid in MARKETS.items():
        try:
            rows[label] = {"market_id": mid, **read_market(mid)}
        except Exception as e:  # noqa: BLE001
            rows[label] = {"market_id": mid, "error": str(e)}
    out = {"retrieved_utc": datetime.now(UTC).isoformat(timespec="seconds"),
           "chain_id": 4663, "block": block, "block_timestamp": ts, "morpho": MORPHO,
           "provenance": "on-chain reads over the public RPC; market ids enumerated from the "
                         "Morpho GraphQL API", "markets": rows}
    (RESULTS_DIR / "morpho_rates_snapshot.json").write_text(json.dumps(out, indent=2) + "\n")
    for k, r in rows.items():
        print(k, r.get("error") or (round(r["utilisation"], 4), round(r["borrow_apr_pct"], 2),
                                    round(r["supply_apr_pct"], 2), r["total_borrow_usdg"]))


if __name__ == "__main__":
    main()
