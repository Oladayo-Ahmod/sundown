"""Fetch the complete Chainlink round history of stock feeds on Robinhood mainnet (chain 4663).

Offline analysis, not production. Uses only `eth_call` of `getRoundData` against the feed proxy,
walking every proxy phase from aggregator round 1 until the call reverts. No archive state is needed
(rounds are readable at the latest block). Writes
contracts/test/fixtures/observed_feed_updates.json.

Run: python observed_rounds.py [--rpc URL] [--out PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com"
DEFAULT_OUT = (
    Path(__file__).resolve().parents[1] / "contracts/test/fixtures/observed_feed_updates.json"
)

# Proxy addresses from Chainlink's Robinhood Chain feed list (docs/DISCOVERY.md): the four
# deploy-set names (TSLA, NVDA, AAPL, SPY) plus QQQ and MSFT for extra evidence.
FEEDS = {
    "SPY": "0x319724394D3A0e3669269846abE664Cd621f9f6A",
    "TSLA": "0x4A1166a659A55625345e9515b32adECea5547C38",
    "NVDA": "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
    "AAPL": "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
    "QQQ": "0x80901d846d5D7B030F26B480776EE3b29374C2ae",
    "MSFT": "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E",
}

SEL_PHASE_ID = "0x58303b10"  # phaseId()
SEL_GET_ROUND = "0x9a6fc8f5"  # getRoundData(uint80)
SEL_LATEST = "0xfeaf968c"  # latestRoundData()
SEL_DECIMALS = "0x313ce567"  # decimals()
BATCH = 50
WORKERS = 2


def rpc(url: str, payload: object) -> object:
    body = json.dumps(payload)
    last = ""
    for attempt in range(8):
        r = subprocess.run(
            [
                "curl",
                "-4",
                "-sS",
                "-m",
                "60",
                "-H",
                "Content-Type: application/json",
                "-d",
                body,
                url,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            last = (r.stdout or r.stderr)[:200]
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"rpc failed: {last}")


def eth_call(url: str, to: str, data: str) -> str:
    out = rpc(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [{"to": to, "data": data}, "latest"],
        },
    )
    if "result" not in out:
        raise RuntimeError(f"eth_call failed: {out}")
    return out["result"]


def decode_round(hexdata: str) -> dict:
    raw = bytes.fromhex(hexdata[2:])
    words = [int.from_bytes(raw[i : i + 32], "big", signed=False) for i in range(0, 160, 32)]
    answer = int.from_bytes(raw[32:64], "big", signed=True)
    return {
        "roundId": words[0],
        "answer": answer,
        "startedAt": words[2],
        "updatedAt": words[3],
        "answeredInRound": words[4],
    }


def fetch_batch(url: str, proxy: str, phase: int, lo: int, hi: int) -> tuple[list[dict], bool]:
    """Fetch aggregator rounds lo..hi (inclusive) of one phase: (rounds, hit_end_of_phase)."""
    calls = []
    for i, r in enumerate(range(lo, hi + 1)):
        data = SEL_GET_ROUND + f"{((phase << 64) | r):064x}"
        calls.append(
            {
                "jsonrpc": "2.0",
                "id": i,
                "method": "eth_call",
                "params": [{"to": proxy, "data": data}, "latest"],
            }
        )
    res = rpc(url, calls)
    for attempt in range(25):  # rate limiting returns an error object instead of a result list
        if isinstance(res, list):
            break
        time.sleep(min(30, 3 * (attempt + 1)))
        res = rpc(url, calls)
    if not isinstance(res, list):
        raise RuntimeError(f"batch failed: {str(res)[:200]}")
    by_id = {x["id"]: x for x in res}
    rounds = []
    for i in range(len(calls)):
        item = by_id[i]
        if "result" not in item or item["result"] in ("0x", None):
            return rounds, True
        rounds.append(decode_round(item["result"]))
    return rounds, False


def fetch_phase(url: str, proxy: str, phase: int, last_round: int | None) -> list[dict]:
    """Walk one phase from aggregator round 1. `last_round` is known for the latest phase (from
    latestRoundData); earlier phases are walked until the call reverts."""
    if last_round is not None:
        starts = list(range(1, last_round + 1, BATCH))
        with ThreadPoolExecutor(max_workers=WORKERS) as ex:
            parts = list(
                ex.map(
                    lambda lo: fetch_batch(url, proxy, phase, lo, min(lo + BATCH - 1, last_round)),
                    starts,
                )
            )
        rounds = []
        for part, ended in parts:
            assert not ended, f"round missing inside phase {phase} of {proxy}"
            rounds.extend(part)
        assert len(rounds) == last_round, (len(rounds), last_round)
        return rounds
    rounds, r = [], 1
    while True:
        part, ended = fetch_batch(url, proxy, phase, r, r + BATCH - 1)
        rounds.extend(part)
        if ended:
            return rounds
        r += BATCH


def fetch_feed(url: str, proxy: str) -> dict:
    phase_id = int(eth_call(url, proxy, SEL_PHASE_ID), 16)
    decimals = int(eth_call(url, proxy, SEL_DECIMALS), 16)
    latest = decode_round(eth_call(url, proxy, SEL_LATEST))
    assert latest["roundId"] >> 64 == phase_id
    rounds: list[dict] = []
    phases: dict[str, int] = {}
    for p in range(1, phase_id + 1):
        last = (latest["roundId"] & ((1 << 64) - 1)) if p == phase_id else None
        got = fetch_phase(url, proxy, p, last)
        phases[str(p)] = len(got)
        rounds.extend(got)
    rounds.sort(key=lambda x: (x["updatedAt"], x["roundId"]))
    assert rounds, f"no rounds for {proxy}"
    assert rounds[-1]["updatedAt"] >= latest["updatedAt"], "history does not reach latestRoundData"
    return {
        "proxy": proxy,
        "decimals": decimals,
        "phaseId": phase_id,
        "roundsPerPhase": phases,
        "roundId": [str(x["roundId"]) for x in rounds],
        "updatedAt": [x["updatedAt"] for x in rounds],
        "startedAt": [x["startedAt"] for x in rounds],
        "answer": [x["answer"] for x in rounds],
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=os.environ.get("ROBINHOOD_MAINNET_RPC_URL", DEFAULT_RPC))
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    chain_id = int(
        rpc(args.rpc, {"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []})["result"],
        16,
    )
    assert chain_id == 4663, f"unexpected chain id {chain_id}"
    head = rpc(
        args.rpc,
        {"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": ["latest", False]},
    )
    head_block = int(head["result"]["number"], 16)
    head_ts = int(head["result"]["timestamp"], 16)

    feeds = {}
    for name, proxy in FEEDS.items():
        feeds[name] = fetch_feed(args.rpc, proxy)
        f = feeds[name]
        print(
            f"{name}: rounds={len(f['updatedAt'])} phases={f['roundsPerPhase']} "
            f"first={f['updatedAt'][0]} last={f['updatedAt'][-1]}"
        )

    out = {
        "meta": {
            "generator": "research/observed_rounds.py",
            "chainId": 4663,
            "source": "eth_call getRoundData on Chainlink feed proxies (public RPC, latest block)",
            "headBlock": head_block,
            "headTimestamp": head_ts,
        },
        "feeds": feeds,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, separators=(",", ":")))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
