"""Exit-liquidity depth for the deploy-set stock tokens on Robinhood Chain (4663).

Offline analysis, not production. Reads Uniswap v3 pools directly over the public RPC
(verified-onchain at retrieval time):

  * pool discovery: factory.getPool(stock, USDG, fee) for the four standard fee tiers
    (no third-party index)
  * state: slot0, liquidity, tickSpacing, fee, token ordering
  * depth: tickBitmap + ticks(liquidityNet) around the current tick (+/- SCAN_WORDS words)

and simulates the exact swap (tick crossing, fee on input) of SELLING the stock for USDG, which
is what a liquidator does with seized collateral. Slippage = 1 - USDG_out / notional, where
notional is the stock value at the Chainlink oracle price (what a lender marks the collateral
at), so the fee, the price impact AND any basis between the pool and the oracle are all
included. A pool priced 12 % below the oracle therefore has no capacity at 5 %.

Not covered (stated plainly): Uniswap v4 pools (singleton PoolManager, not enumerated here:
they only add depth, so v3-only figures are a lower bound for those venues), RFQ/aggregator
routing, other DEXes, depth outside the scanned tick words, and the fact that liquidity changes
minute to minute. Pools are summed: each pool executed at its own slippage s gives an aggregate
average slippage <= s, so the sum is a valid (conservative) capacity.

Run: python exit_liquidity.py [--out PATH]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

RPC = os.environ.get("ROBINHOOD_MAINNET_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
OUT = Path(__file__).resolve().parent / "results" / "exit_liquidity.json"
ZERO = "0x" + "00" * 20
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
TOKENS = {
    "TSLA": "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
    "NVDA": "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
    "AAPL": "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
    "SPY": "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C",
}
FEEDS = {
    "TSLA": "0x4A1166a659A55625345e9515b32adECea5547C38",
    "NVDA": "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
    "AAPL": "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
    "SPY": "0x319724394D3A0e3669269846abE664Cd621f9f6A",
}
# A known Robinhood-chain Uniswap v3 TSLA/USDG pool, used only to read the factory address.
SEED_POOL = "0xf4ACdAEEB7022862A763C9B1B885e11191c889E3"
FEE_TIERS = [100, 500, 3000, 10000]
SCAN_WORDS = 3
TARGETS = [0.01, 0.03, 0.05]
LADDER_USD = [10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
LN1P0001 = math.log(1.0001)


def sig(s: str) -> str:
    out = subprocess.run(
        [os.path.expanduser("~/.foundry/bin/cast"), "sig", s],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


SEL = {
    s: sig(s)
    for s in [
        "factory()",
        "getPool(address,address,uint24)",
        "slot0()",
        "liquidity()",
        "tickSpacing()",
        "fee()",
        "token0()",
        "token1()",
        "tickBitmap(int16)",
        "ticks(int24)",
        "latestRoundData()",
        "uiMultiplier()",
    ]
}


def rpc(payload: object) -> object:
    body = json.dumps(payload)
    last = ""
    for attempt in range(25):
        r = subprocess.run(
            [
                "curl",
                "-4",
                "-sS",
                "-m",
                "90",
                "-H",
                "Content-Type: application/json",
                "-d",
                body,
                RPC,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            d = json.loads(r.stdout)
        except json.JSONDecodeError:
            last = (r.stdout or r.stderr)[:200]
            time.sleep(min(30, 2 * (attempt + 1)))
            continue
        if isinstance(d, dict) and d.get("error", {}).get("code") == 429:
            time.sleep(min(30, 3 * (attempt + 1)))
            continue
        return d
    raise RuntimeError(f"rpc failed: {last}")


def call_many(calls: list[tuple[str, str]]) -> list[str]:
    """Batch eth_call; returns result hex strings (raises on any error)."""
    out: list[str] = []
    for i in range(0, len(calls), 25):
        chunk = calls[i : i + 25]
        payload = [
            {
                "jsonrpc": "2.0",
                "id": j,
                "method": "eth_call",
                "params": [{"to": to, "data": data}, "latest"],
            }
            for j, (to, data) in enumerate(chunk)
        ]
        res = rpc(payload)
        assert isinstance(res, list), res
        by = {x["id"]: x for x in res}
        for j in range(len(chunk)):
            if "result" not in by[j]:
                raise RuntimeError(f"call failed: {chunk[j]} -> {by[j]}")
            out.append(by[j]["result"])
    return out


def call(to: str, data: str) -> str:
    return call_many([(to, data)])[0]


def w(hexstr: str, i: int) -> int:
    return int(hexstr[2 + 64 * i : 2 + 64 * (i + 1)], 16)


def sw(hexstr: str, i: int, bits: int = 256) -> int:
    v = w(hexstr, i) & ((1 << bits) - 1)
    return v - (1 << bits) if v >> (bits - 1) else v


def addr(hexstr: str, i: int = 0) -> str:
    return "0x" + hexstr[2 + 64 * i + 24 : 2 + 64 * (i + 1)]


def pad_addr(a: str) -> str:
    return a.lower().removeprefix("0x").rjust(64, "0")


def pad_int(v: int) -> str:
    return f"{v & ((1 << 256) - 1):064x}"


def sqrt_at(tick: int) -> float:
    return math.exp(tick * LN1P0001 / 2)


def read_pool(pool: str) -> dict:
    s0, liq, spacing, fee, t0, t1 = call_many(
        [
            (pool, SEL[k])
            for k in ("slot0()", "liquidity()", "tickSpacing()", "fee()", "token0()", "token1()")
        ]
    )
    sqrt_p = w(s0, 0) / 2**96
    tick = sw(s0, 1, 24)
    spacing_i = sw(spacing, 0, 24)
    d = {
        "pool": pool,
        "sqrtP": sqrt_p,
        "tick": tick,
        "liquidity": w(liq, 0),
        "spacing": spacing_i,
        "fee": w(fee, 0) / 1e6,
        "token0": addr(t0),
        "token1": addr(t1),
    }
    cur_word = (tick // spacing_i) >> 8
    words = list(range(cur_word - SCAN_WORDS, cur_word + SCAN_WORDS + 1))
    bitmaps = call_many([(pool, SEL["tickBitmap(int16)"] + pad_int(x)) for x in words])
    init_ticks = []
    for word, bm in zip(words, bitmaps, strict=True):
        v = int(bm, 16)
        for b in range(256):
            if (v >> b) & 1:
                init_ticks.append((word * 256 + b) * spacing_i)
    nets = (
        call_many([(pool, SEL["ticks(int24)"] + pad_int(t)) for t in init_ticks])
        if init_ticks
        else []
    )
    d["ticks"] = sorted((t, sw(n, 1, 128)) for t, n in zip(init_ticks, nets, strict=True))
    d["words_scanned"] = [words[0], words[-1]]
    # outer edges of the scanned window (ticks): liquidity beyond them is unknown, so never assumed
    d["scan_ticks"] = (words[0] * 256 * spacing_i, (words[-1] + 1) * 256 * spacing_i)
    return d


def simulate_sell(pool: dict, sell_token0: bool, amount_in: float) -> float | None:
    """Exact-input swap selling token0 (price down) or token1 (price up).

    Returns the raw output, or None when
    the scanned liquidity is exhausted before the input is absorbed."""
    sqrt_p = pool["sqrtP"]
    liq = float(pool["liquidity"])
    remaining = amount_in * (1 - pool["fee"])
    out = 0.0
    ticks = pool["ticks"]
    cur = pool["tick"]
    lo_edge, hi_edge = pool["scan_ticks"]
    if sell_token0:
        bounds = [(t, n) for t, n in reversed(ticks) if t <= cur] + [(lo_edge, 0)]
    else:
        bounds = [(t, n) for t, n in ticks if t > cur] + [(hi_edge, 0)]
    for t, net in bounds:
        target = sqrt_at(t)
        if sell_token0:
            max_in = liq * (1 / target - 1 / sqrt_p)
        else:
            max_in = liq * (target - sqrt_p)
        if liq > 0 and remaining <= max_in:
            return out + _step(liq, sqrt_p, remaining, sell_token0)[0]
        if liq > 0:
            out += _step(liq, sqrt_p, max_in, sell_token0)[0]
            remaining -= max_in
        sqrt_p = target
        liq += -net if sell_token0 else net
        if liq < 0:
            liq = 0.0
    return None  # input not absorbed within the scanned window: treated as exhausted (conservative)


def _step(liq: float, sqrt_p: float, amt_in: float, sell_token0: bool) -> tuple[float, float]:
    """One in-range exact-input step, in cancellation-free closed form.

    Selling token0: out = a*P / (1 + a*sqrtP/L), new sqrtP = sqrtP / (1 + a*sqrtP/L).
    Selling token1: out = a / (P + a*sqrtP/L),   new sqrtP = sqrtP + a/L.
    """
    price = sqrt_p * sqrt_p
    k = amt_in * sqrt_p / liq
    if sell_token0:
        return amt_in * price / (1 + k), sqrt_p / (1 + k)
    return amt_in / (price + k), sqrt_p + amt_in / liq


def usd_per_stock(pool: dict, stock: str) -> float:
    p_raw = pool["sqrtP"] ** 2  # token1_raw / token0_raw
    if pool["token0"].lower() == stock.lower():
        return p_raw * 1e18 / 1e6
    return (1 / p_raw) * 1e12


def slippage(pool: dict, stock: str, notional: float, ref_usd: float) -> float | None:
    """Slippage of selling `notional` USD (at oracle price `ref_usd`) of `stock` into the pool."""
    sell0 = pool["token0"].lower() == stock.lower()
    amount_in = notional / ref_usd * 1e18
    out = simulate_sell(pool, sell0, amount_in)
    if out is None:
        return None
    return 1 - (out / 1e6) / notional


def max_notional(pool: dict, stock: str, target: float, ref_usd: float) -> float:
    lo, hi = 0.0, 5e7
    s_hi = slippage(pool, stock, hi, ref_usd)
    if s_hi is not None and s_hi <= target:
        return hi
    for _ in range(60):
        mid = (lo + hi) / 2
        s = slippage(pool, stock, mid, ref_usd)
        if s is not None and s <= target:
            lo = mid
        else:
            hi = mid
    return lo


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()

    head = rpc(
        {"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": ["latest", False]}
    )
    block = int(head["result"]["number"], 16)
    ts = int(head["result"]["timestamp"], 16)
    factory = addr(call(SEED_POOL, SEL["factory()"]))
    result = {
        "retrieved_utc": datetime.now(UTC).isoformat(timespec="seconds"),
        "chain_id": 4663,
        "block": block,
        "block_timestamp": ts,
        "factory": factory,
        "method": "uniswap v3 factory.getPool + slot0/liquidity/tickBitmap/ticks over public RPC; "
        "exact swap simulation selling stock for USDG (fee included)",
        "scan_words": SCAN_WORDS,
        "assets": {},
    }
    for sym, tok in TOKENS.items():
        rd = call(FEEDS[sym], SEL["latestRoundData()"])
        feed_ans = w(rd, 1) / 1e8
        feed_updated = w(rd, 3)
        mult = w(call(tok, SEL["uiMultiplier()"]), 0) / 1e18
        pools = []
        for fee in FEE_TIERS:
            res = call(
                factory,
                SEL["getPool(address,address,uint24)"]
                + pad_addr(tok)
                + pad_addr(USDG)
                + pad_int(fee),
            )
            pool = addr(res)
            if pool == ZERO:
                continue
            p = read_pool(pool)
            if p["liquidity"] == 0 and not p["ticks"]:
                pools.append({"pool": pool, "fee_tier": fee, "empty": True})
                continue
            mid = usd_per_stock(p, tok)
            row = {
                "pool": pool,
                "fee_tier": fee,
                "tick": p["tick"],
                "tick_spacing": p["spacing"],
                "active_liquidity": p["liquidity"],
                "mid_usd": mid,
                "basis_vs_oracle_pct": round(100 * (mid / feed_ans - 1), 3),
                "initialized_ticks_scanned": len(p["ticks"]),
                "ladder_slippage_pct": {
                    str(n): (
                        None if (s := slippage(p, tok, n, feed_ans)) is None else round(100 * s, 3)
                    )
                    for n in LADDER_USD
                },
                "max_notional_usd": {
                    f"{int(t * 100)}pct": round(max_notional(p, tok, t, feed_ans)) for t in TARGETS
                },
            }
            pools.append(row)
        live = [r for r in pools if not r.get("empty")]
        agg = {
            f"{int(t * 100)}pct": sum(r["max_notional_usd"][f"{int(t * 100)}pct"] for r in live)
            for t in TARGETS
        }
        mids = [r["mid_usd"] for r in live]
        result["assets"][sym] = {
            "token": tok,
            "chainlink_price_usd": feed_ans,
            "chainlink_updated_at": feed_updated,
            "chainlink_age_s": ts - feed_updated,
            "ui_multiplier": mult,
            "pools": pools,
            "aggregate_max_notional_usd": {k: round(v) for k, v in agg.items()},
            "pool_mid_range_usd": [min(mids), max(mids)] if mids else None,
        }
        print(
            sym,
            "pools",
            len(live),
            "aggregate",
            result["assets"][sym]["aggregate_max_notional_usd"],
            "chainlink",
            feed_ans,
            "pool mids",
            result["assets"][sym]["pool_mid_range_usd"],
        )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
