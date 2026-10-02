#!/usr/bin/env python3
"""Live evidence for the Arbitrum Sepolia demonstration (docs/SEPOLIA_DEMO.md). Rerunnable.

Every step is timestamped (UTC and New York) together with the calendar's blind-window state at that moment,
the tokens and feeds are SIMULATION fixtures (SimUSDG, SimStock, SimEquityFeed), the contracts under test are the
production Sundown contracts. Uses `cast` only (keystores, no raw key in the environment or in the logs).

Each run creates fresh throwaway lender/borrower/liquidator keystores (so the per-address faucet limits never block
a rerun), funds them from the deployer, and writes the report. The guardian is the deployment guardian keystore.

Required environment: ARBITRUM_SEPOLIA_RPC_URL (defaults to the public endpoint in .env.example).
Usage:
  python scripts/sepolia_demo.py --deployer-account NAME --deployer-password-file FILE \
      --guardian-keystore FILE --guardian-password-file FILE [--out docs/SEPOLIA_DEMO.md] [--rpc URL] [--fund-eth 0.002]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deployments/421614.json"
ARBISCAN = "https://sepolia.arbiscan.io"
NY = ZoneInfo("America/New_York")
CLASS = {0: "Short", 1: "Weekend", 2: "Long"}
STATUS = {0: "Fresh", 1: "ScheduledBlind", 2: "Reopening", 3: "Stale", 4: "Invalid", 5: "CorporateAction", 6: "SequencerDown"}
HALT = {0: "None", 1: "Guardian", 2: "CollateralPaused", 3: "CollateralBlocked", 4: "LoanPaused", 5: "LoanFrozen",
        6: "CollateralShortfall", 7: "ProbeFailure"}  # fmt: skip

ERRORS = [
    "ExceedsCapacity(uint256,uint256)", "PriceUnusable(uint8)", "EntryNotAllowed(bytes32)", "NotLiquidatable()",
    "ProbesFailing()", "BelowMinDebt(uint256,uint256)", "InsufficientIdle(uint256,uint256)", "NotActive()",
    "DoesNotFitStandard(uint256,uint256)", "FaucetLimit(uint256,uint256,uint256)", "Unauthorized()",
    "BorrowsBlocked()", "IsPaused()", "NothingToRepay()", "ZeroAmount()", "CollateralCapExceeded(uint256,uint256)",
]  # fmt: skip


class Cast:
    def __init__(self, rpc: str) -> None:
        self.rpc = rpc
        self._sel: dict[str, str] = {}
        for sig in ERRORS:
            self._sel[self.run(["cast", "sig", sig]).strip()] = sig

    @staticmethod
    def run(cmd: list[str]) -> str:
        p = Cast.exec(cmd)
        if p.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd[:3])} failed: {p.stderr.strip()[:400]}")
        return p.stdout

    TRANSPORT = ("error sending request", "connection", "badrecordmac", "timed out", "tcp connect", "dns error")

    @staticmethod
    def exec(cmd: list[str]) -> subprocess.CompletedProcess:
        """Run a command with a timeout, retrying only transport errors and hung READ calls of the flaky public RPC.
        Reverts are never retried. A hung `cast send` is not retried either (it may already be on chain): it raises."""
        import time

        def once() -> subprocess.CompletedProcess:
            try:
                return subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                if len(cmd) > 1 and cmd[1] == "send":
                    raise RuntimeError(f"cast send timed out (the transaction may be on chain, check Arbiscan): {' '.join(cmd[:4])}")
                return subprocess.CompletedProcess(cmd, 124, "", "timed out")

        p = once()
        for _ in range(10):
            if p.returncode == 0 or not any(t in p.stderr.lower() for t in Cast.TRANSPORT):
                break
            time.sleep(2)
            p = once()
        return p

    def call(self, to: str, sig: str, *args: str, frm: str | None = None) -> str:
        cmd = ["cast", "call", to, sig, *args, "--rpc-url", self.rpc]
        if frm:
            cmd += ["--from", frm]
        return self.run(cmd).strip()

    def try_call(self, to: str, sig: str, *args: str, frm: str | None = None) -> tuple[bool, str]:
        """eth_call; on revert returns (False, decoded custom error)."""
        cmd = ["cast", "call", to, sig, *args, "--rpc-url", self.rpc]
        if frm:
            cmd += ["--from", frm]
        p = Cast.exec(cmd)
        if p.returncode == 0:
            return True, p.stdout.strip()
        m = re.search(r'data: "(0x[0-9a-fA-F]*)"', p.stderr) or re.search(r"(0x[0-9a-fA-F]{8,})", p.stderr)
        return False, self.decode(m.group(1)) if m else p.stderr.strip()[:200]

    def decode(self, data: str) -> str:
        sel = data[:10]
        sig = self._sel.get(sel)
        if not sig:
            return f"unknown error {data[:74]}"
        name, types = sig.split("(")
        types = types.rstrip(")")
        if not types:
            return f"{name}()  [revert data {data}]"
        out = self.run(["cast", "abi-decode", f"f()({types})", "0x" + data[10:]])
        vals = [re.sub(r"\s*\[.*?\]", "", ln.strip()) for ln in out.strip().splitlines()]
        pretty = []
        for t, v in zip(types.split(","), vals):
            if t == "bytes32":
                try:
                    v = bytes.fromhex(v[2:]).rstrip(b"\x00").decode() or v
                except ValueError:
                    pass
            pretty.append(f"{t}={v}")
        return f"{name}({', '.join(pretty)})  [revert data {data[:10]}…{data[-8:]}]"


class Signer:
    def __init__(self, label: str, address: str, args: list[str]) -> None:
        self.label, self.address, self.args = label, address, args


class Report:
    def __init__(self, cast: Cast) -> None:
        self.cast = cast
        self.rows: list[dict] = []
        self.addresses: dict[str, str] = {}
        self.window_cache = ""

    def window(self) -> dict:
        out = self.cast.call(self.window_cache, "peek()((bool,uint64,uint64,uint64,uint64,uint8))")
        nums = re.findall(r"\d+|true|false", clean(out))
        blind = nums[0] == "true"
        wid, start, end, last, cls = (int(x) for x in nums[1:6])
        return {"blind": blind, "windowId": wid, "start": start, "end": end, "cls": CLASS.get(cls, str(cls))}

    def stamp(self) -> dict:
        now = dt.datetime.now(dt.UTC)
        w = self.window()
        et = lambda ts: dt.datetime.fromtimestamp(ts, dt.UTC).astimezone(NY).strftime("%a %Y-%m-%d %H:%M ET")  # noqa: E731
        state = (
            f"BLIND until {et(w['end'])} ({w['cls']} window)"
            if w["blind"]
            else f"not blind; next {w['cls']} window starts {et(w['start'])}"
        )
        return {
            "utc": now.strftime("%Y-%m-%d %H:%M:%SZ"),
            "et": now.astimezone(NY).strftime("%a %H:%M:%S ET"),
            "window": state,
        }

    def add(self, section: str, action: str, result: str, tx: str | None = None, block: int | None = None) -> None:
        row = {"section": section, "action": action, "result": result, "tx": tx, "block": block, **self.stamp()}
        self.rows.append(row)
        link = f"  tx {ARBISCAN}/tx/{tx}" if tx else ""
        print(f"[{row['utc']}] {section}: {action} -> {result}{link}")

    def send(self, who: Signer, section: str, action: str, to: str, sig: str, *args: str, value: str | None = None) -> dict:
        cmd = ["cast", "send", to, sig, *args, "--rpc-url", self.cast.rpc, *who.args, "--json"]
        if value:
            cmd += ["--value", value]
        out = self.cast.run(cmd)
        rcpt = json.loads(out)
        status = rcpt.get("status")
        ok = status in ("0x1", 1, "1", "success")
        block = rcpt["blockNumber"]
        block = int(block, 16) if isinstance(block, str) and block.startswith("0x") else int(block)
        self.add(section, f"{who.label}: {action}", "success" if ok else f"FAILED (status {status})", rcpt["transactionHash"], block)
        if not ok:
            raise RuntimeError(f"transaction failed: {action}")
        return rcpt

    def expect_revert(self, who: Signer, section: str, action: str, to: str, sig: str, *args: str) -> str:
        ok, res = self.cast.try_call(to, sig, *args, frm=who.address)
        self.add(section, f"{who.label}: eth_call {action}", f"REVERTS: {res}" if not ok else f"unexpectedly succeeded: {res}")
        if ok:
            raise RuntimeError(f"expected a revert: {action}")
        return res


def clean(s: str) -> str:
    """Drop cast's `[1.23e18]` annotations and underscores so only the raw values remain."""
    return re.sub(r"\[[^\]]*\]", "", s).replace("_", "")


def first_int(s: str) -> int:
    return int(re.findall(r"\d+", clean(s))[0])


def make_actor(cast: Cast, base: Path, name: str) -> Signer:
    base.mkdir(parents=True, exist_ok=True)
    pw = secrets.token_hex(16)
    pwfile = base / f"{name}.pass"
    pwfile.write_text(pw)
    pwfile.chmod(0o600)
    out = Cast.run(["cast", "wallet", "new", str(base), name, "--unsafe-password", pw])
    addr = re.search(r"0x[0-9a-fA-F]{40}", out).group(0)  # type: ignore[union-attr]
    return Signer(name, addr, ["--keystore", str(base / name), "--password-file", str(pwfile)])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deployer-account", help="cast keystore account name (default keystore dir)")
    ap.add_argument("--deployer-keystore", help="keystore file path (alternative to --deployer-account)")
    ap.add_argument("--deployer-password-file", required=True)
    ap.add_argument("--guardian-keystore", required=True)
    ap.add_argument("--guardian-password-file", required=True)
    ap.add_argument("--rpc", default=os.environ.get("ARBITRUM_SEPOLIA_RPC_URL", "https://sepolia-rollup.arbitrum.io/rpc"))
    ap.add_argument("--out", type=Path, default=ROOT / "docs/SEPOLIA_DEMO.md")
    ap.add_argument("--fund-eth", default="0.002", help="ETH sent to each throwaway actor")
    ap.add_argument("--secrets-dir", type=Path, default=Path.home() / ".secrets/sundown-demo")
    args = ap.parse_args()

    cast = Cast(args.rpc)
    dep = json.loads(DEPLOY.read_text())
    A = dep["contracts"]
    rep = Report(cast)
    rep.window_cache = A["WindowCache"]

    chain = cast.call(A["SimUSDG"], "decimals()(uint8)")  # liveness
    cid = Cast.run(["cast", "chain-id", "--rpc-url", args.rpc]).strip()
    assert cid == "421614", f"wrong chain {cid}"
    assert args.deployer_account or args.deployer_keystore, "give --deployer-account or --deployer-keystore"
    dsign = ["--account", args.deployer_account] if args.deployer_account else ["--keystore", args.deployer_keystore]
    deployer = Signer("deployer", dep["deployer"], [*dsign, "--password-file", args.deployer_password_file])
    guardian = Signer("guardian", dep["guardian"], ["--keystore", args.guardian_keystore, "--password-file", args.guardian_password_file])
    run_id = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    base = args.secrets_dir / run_id
    lender, borrower, liquidator = (make_actor(cast, base, n) for n in ("lender", "borrower", "liquidator"))
    S = "0. Setup"
    rep.add(S, "chain and fixtures", f"chain id {cid}, sUSDG decimals {chain}; fixtures are SIMULATION; actors this run: "
            f"lender {lender.address}, borrower {borrower.address}, liquidator {liquidator.address}")  # fmt: skip
    for who in (lender, borrower, liquidator):
        cast.run(["cast", "send", who.address, "--value", args.fund_eth + "ether", "--rpc-url", args.rpc, *deployer.args])
    rep.add(S, "fund throwaway actors", f"{args.fund_eth} ETH each from the deployer")

    usdg = A["SimUSDG"]
    mk = {k.replace("Market_", ""): v for k, v in A.items() if k.startswith("Market_")}
    stock = {s: A[f"SimStock_{s}"] for s in ("SPY", "AAPL", "NVDA", "TSLA")}
    feed = {s: A[f"SimEquityFeed_{s}"] for s in stock}
    oracle = {s: A[f"ChainlinkEquityOracle_{s}"] for s in stock}
    guard = A["SundownGuard_AAPL93"]
    MAX = "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    def price(sym: str) -> tuple[float, str]:
        out = cast.call(oracle[sym], "peek()((uint256,uint64,uint64,uint256,uint8))")
        n = re.findall(r"\d+", clean(out))
        return int(n[0]) / 1e18, STATUS[int(n[4])]

    # ------------------------------------------------------------------ 1. faucet
    S = "1. Faucet"
    rep.send(lender, S, "sUSDG.faucet(100,000)", usdg, "faucet(uint256)", "100000000000")
    rep.send(borrower, S, "sUSDG.faucet(2,000)", usdg, "faucet(uint256)", "2000000000")
    rep.send(liquidator, S, "sUSDG.faucet(20,000)", usdg, "faucet(uint256)", "20000000000")
    for sym, amt in (("AAPL", 10), ("NVDA", 10), ("TSLA", 4)):
        rep.send(borrower, S, f"s{sym}.faucet({amt})", stock[sym], "faucet(uint256)", f"{amt}000000000000000000")
    rep.expect_revert(borrower, S, "sAAPL.faucet(1) again (per-address limit is 10)", stock["AAPL"], "faucet(uint256)", "1000000000000000000")

    # ------------------------------------------------------------------ 2. supply
    S = "2. Supply"
    for m in ("AAPL_standard", "AAPL_boosted_93", "AAPL_control_93", "NVDA_standard", "TSLA_standard"):
        rep.send(lender, S, f"approve sUSDG to {m}", usdg, "approve(address,uint256)", mk[m], MAX)
        rep.send(lender, S, f"deposit 15,000 sUSDG into {m}", mk[m], "deposit(uint256,address)", "15000000000", lender.address)

    # ------------------------------------------------------------------ 3. collateral and a standard borrow
    S = "3. Collateral and a standard borrow (AAPL standard, 86 %)"
    p, st = price("AAPL")
    rep.add(S, "oracle", f"AAPL feed (SimEquityFeed) {p:.2f} USD, adapter status {st}")
    rep.send(borrower, S, "approve sAAPL", stock["AAPL"], "approve(address,uint256)", mk["AAPL_standard"], MAX)
    rep.send(borrower, S, "deposit 4 sAAPL as collateral", mk["AAPL_standard"], "depositCollateral(uint256,address)", "4000000000000000000", borrower.address)
    rep.send(borrower, S, "borrow 1,000 sUSDG", mk["AAPL_standard"], "borrow(uint256,address)", "1000000000", borrower.address)
    rep.add(S, "position", f"debtOf = {first_int(cast.call(mk['AAPL_standard'], 'debtOf(address)(uint256)', borrower.address)) / 1e6:.6f} sUSDG, "
            f"collateral value {4 * p:.2f} USD")  # fmt: skip

    # ------------------------------------------------------------------ 4. session-aware behaviour inside the window
    S = "4. Session-aware capacity inside the window (AAPL boosted market)"
    w = rep.window()
    sf = cast.call(guard, "stressFraction(uint8)(uint256)", str({"Short": 0, "Weekend": 1, "Long": 2}[w["cls"]]))
    rep.add(S, "guard parameters", f"stress fraction for the {w['cls']} class = {first_int(sf) / 1e16:.2f} % (1 - gapVaR - 0.5 % - 1 %); "
            f"standard LLTV 86 %, boosted 93 %")  # fmt: skip
    rep.send(borrower, S, "approve sAAPL", stock["AAPL"], "approve(address,uint256)", mk["AAPL_boosted_93"], MAX)
    rep.send(borrower, S, "deposit 3 sAAPL as collateral", mk["AAPL_boosted_93"], "depositCollateral(uint256,address)", "3000000000000000000", borrower.address)
    rep.expect_revert(borrower, S, "enterBoosted() (the boosted tier is closed while the window is on)", guard, "enterBoosted()")
    cv = 3 * p
    cap = int(cv * 0.86 * 1e6)
    over = int(cv * 0.90 * 1e6)
    rep.expect_revert(borrower, S, f"borrow {over / 1e6:.2f} sUSDG (90 % of ${cv:.2f}; standard cap is 86 % = {cap / 1e6:.2f})", mk["AAPL_boosted_93"], "borrow(uint256,address)", str(over), borrower.address)
    ok = int(cv * 0.80 * 1e6)
    rep.send(borrower, S, f"borrow {ok / 1e6:.2f} sUSDG (80 %, below the cap)", mk["AAPL_boosted_93"], "borrow(uint256,address)", str(ok), borrower.address)
    ql = cast.call(guard, "quoteDeleverage(address)(bool,uint256,uint256,uint256,uint256)", borrower.address)
    rep.add(S, "quoteDeleverage(borrower)", f"eligible = {clean(ql).split()[0].strip("(),")} (no deleveraging in a blind window; standard-tier accounts are never deleveraged)")

    # ------------------------------------------------------------------ 5. control market, price move, liquidation
    S = "5. Frozen-price control (FlatGuard 93 %): a price move and a liquidation"
    rep.send(borrower, S, "approve sAAPL", stock["AAPL"], "approve(address,uint256)", mk["AAPL_control_93"], MAX)
    rep.send(borrower, S, "deposit 3 sAAPL as collateral", mk["AAPL_control_93"], "depositCollateral(uint256,address)", "3000000000000000000", borrower.address)
    hi = int(cv * 0.92 * 1e6)
    rep.send(borrower, S, f"borrow {hi / 1e6:.2f} sUSDG (92 % LTV: the control allows what the session-aware market refuses)", mk["AAPL_control_93"], "borrow(uint256,address)", str(hi), borrower.address)
    new_price8 = int(p * 0.95 * 1e8)
    rep.send(deployer, S, f"SimEquityFeed(AAPL).publish({new_price8 / 1e8:.2f})  (price -5 %)", feed["AAPL"], "publish(int256)", str(new_price8))
    p2, st2 = price("AAPL")
    rep.add(S, "oracle after the move", f"{p2:.2f} USD, status {st2}")
    rep.send(liquidator, S, "approve sUSDG", usdg, "approve(address,uint256)", mk["AAPL_control_93"], MAX)
    debt = first_int(cast.call(mk["AAPL_control_93"], "debtOf(address)(uint256)", borrower.address))
    rcpt = rep.send(liquidator, S, f"liquidate {debt // 2 / 1e6:.2f} sUSDG of the control position", mk["AAPL_control_93"], "liquidate(address,uint256,address)", borrower.address, str(debt // 2), liquidator.address)
    got = first_int(cast.call(stock["AAPL"], "balanceOf(address)(uint256)", liquidator.address)) / 1e18
    repaid_usd = (debt // 2) / 1e6
    eff = got * p2 / repaid_usd - 1
    rep.add(S, "liquidator received", f"{got:.6f} sAAPL = {got * p2:.2f} USD for {repaid_usd:.2f} repaid: effective bonus {eff * 100:.2f} % "
            f"(the flat 4 % bonus, capped by the market's non-worsening rule at collateral value / debt - 1 when the position is close to insolvent)")
    rep.expect_revert(liquidator, S, "liquidate the session-aware market's position (80 % LTV, still healthy at the new price)", mk["AAPL_boosted_93"], "liquidate(address,uint256,address)", borrower.address, "1000000", liquidator.address)
    rep.send(deployer, S, f"SimEquityFeed(AAPL).publish({int(p * 1e8) / 1e8:.2f})  (price restored)", feed["AAPL"], "publish(int256)", str(int(p * 1e8)))

    # ------------------------------------------------------------------ 6. issuer-failure demo on NVDA
    S = "6. Issuer failure: pause, report, Halted, repay still works, unpause, resume (NVDA standard)"
    nv = mk["NVDA_standard"]
    rep.send(borrower, S, "approve sNVDA", stock["NVDA"], "approve(address,uint256)", nv, MAX)
    rep.send(borrower, S, "deposit 10 sNVDA", nv, "depositCollateral(uint256,address)", "10000000000000000000", borrower.address)
    rep.send(borrower, S, "borrow 1,200 sUSDG", nv, "borrow(uint256,address)", "1200000000", borrower.address)
    rep.send(borrower, S, "approve sUSDG (for repay)", usdg, "approve(address,uint256)", nv, MAX)
    rep.send(deployer, S, "sNVDA.setTokenPaused(true)  (the issuer pauses the stock token)", stock["NVDA"], "setTokenPaused(bool)", "true")
    rep.send(liquidator, S, "market.reportIssuerFailure()  (permissionless)", nv, "reportIssuerFailure()(uint8)")
    st = first_int(cast.call(nv, "state()(uint8)"))
    reason = first_int(cast.call(nv, "haltReason()(uint8)"))
    rep.add(S, "market state", f"state = {'Halted' if st else 'Active'}, reason = {HALT[reason]}")
    rep.expect_revert(borrower, S, "borrow while Halted", nv, "borrow(uint256,address)", "10000000", borrower.address)
    rep.expect_revert(guardian, S, "guardian resume() while the token is still paused", nv, "resume()")
    rep.send(borrower, S, "repay 400 sUSDG while Halted (repay is never blockable)", nv, "repay(uint256,address)", "400000000", borrower.address)
    rep.send(deployer, S, "sNVDA.setTokenPaused(false)  (unpause)", stock["NVDA"], "setTokenPaused(bool)", "false")
    rep.send(guardian, S, "guardian resume() (probes pass again)", nv, "resume()")
    st = first_int(cast.call(nv, "state()(uint8)"))
    rep.add(S, "market state", f"state = {'Halted' if st else 'Active'}")

    # ------------------------------------------------------------------ 7. oracle adapter: stale and invalid answers
    S = "7. Oracle adapter rejects a stale and an invalid answer (TSLA)"
    pt, stt = price("TSLA")
    rep.add(S, "before", f"{pt:.2f} USD, status {stt}")
    tsla = mk["TSLA_standard"]
    rep.send(borrower, S, "approve sTSLA", stock["TSLA"], "approve(address,uint256)", tsla, MAX)
    rep.send(borrower, S, "deposit 4 sTSLA", tsla, "depositCollateral(uint256,address)", "4000000000000000000", borrower.address)
    now = int(dt.datetime.now(dt.UTC).timestamp())
    p8 = str(int(pt * 1e8))
    rep.send(deployer, S, "SimEquityFeed(TSLA).publishAt(price, now - 26 h)  (an old answer)", feed["TSLA"], "publishAt(int256,uint256)", p8, str(now - 26 * 3600))
    rep.add(S, "adapter reading", "{:.2f} USD, status {}  (inside a blind window the adapter reports ScheduledBlind and masks staleness; Stale is reported outside windows: rerun this script after the window to show it)".format(*price("TSLA")))
    rep.send(deployer, S, "SimEquityFeed(TSLA).publishAt(0, now)  (a broken feed)", feed["TSLA"], "publishAt(int256,uint256)", "0", str(int(dt.datetime.now(dt.UTC).timestamp()) - 5))
    rep.add(S, "adapter reading", "{:.2f} USD, status {}".format(*price("TSLA")))
    rep.expect_revert(borrower, S, "borrow 100 sUSDG against the invalid answer", tsla, "borrow(uint256,address)", "100000000", borrower.address)
    rep.send(deployer, S, "SimEquityFeed(TSLA).publish(price)  (restored)", feed["TSLA"], "publish(int256)", p8)
    rep.add(S, "adapter reading", "{:.2f} USD, status {}".format(*price("TSLA")))

    write_report(args.out, rep, dep, args)


STATIC_SECTIONS = ["""
## What is live, what is simulated, what cannot be shown live

**Live on Arbitrum Sepolia (this run):** the production Sundown contracts (`SundownMarket` clones from the factory, `FlatGuard`,
`SundownGuard`, `ChainlinkEquityOracle`, `WindowCache`, the calendar and its wrapper) executing real transactions, the real
calendar's window state at each step, decoded custom errors from `eth_call` reverts, a real liquidation, a real halt and resume.

**Simulated (named and labeled as such):** every token (`SimUSDG`, `SimStock` for SPY, AAPL, NVDA and TSLA, `SimIssuerRegistry`) and every
price feed (`SimEquityFeed`, owner-set prices, including the deliberately old and zero answers). The oracle adapter is the
production contract pointed at a simulated feed; validation against the real Chainlink feeds remains the optional fork test
against Robinhood mainnet and is not part of this run. The replay evidence (`docs/REPLAY_RESULTS.md`) runs in forge's in-process
EVM with a fixture window cache, not on a public chain.

**Not demonstrable before the submission deadline (Sun 2026-10-04 08:59 WAT).** The blind window itself only ends Sun 2026-10-04 20:00 ET (Mon 01:00 WAT) and the next window starts Fri 2026-10-09 20:00 ET, both after the deadline, so this evidence is final and was not rerun:

- *Boosted-tier stress cap.* A boosted account can only be created outside the stress period (`enterBoosted()` is refused while the price
  is not Fresh or a stress period is on, which section 4 shows live). The stress period starts 6 h before the next window, Fri 2026-10-09
  14:00 ET, so a borrow denied *by the stress cap* for a boosted account cannot be shown now. What section 4 shows instead is the
  in-window capacity: the standard 86 % cap in the boosted market (and the refusal to enter the boosted tier), against the 93 % control
  that lets the same borrow through.
- *Pre-window horizon, cure window and deleveraging.* They need a window start: the next one is Fri 2026-10-09 20:00 ET (horizon opens 14:00
  ET, the cure window ends 17:00 ET, deleveraging runs 17:00-20:00 ET).
- *The `Stale` price status.* Inside a blind window the adapter reports `ScheduledBlind`; `Stale` appears only outside windows.

**Where those behaviors are demonstrated instead:** `docs/REPLAY_RESULTS.md` (AAPL 93 %, the 10 worst events, simulation), and the forge
tests `contracts/test/SundownGuard.t.sol` (every instant of the horizon and cure window, the deleverage amounts and fee, standard
accounts never deleveraged), `contracts/test/invariants/GuardInvariants.t.sol` (G1-G8) and `contracts/test/Oracle.t.sol` (statuses
by window state).
"""]


def write_report(out: Path, rep: Report, dep: dict, args: argparse.Namespace) -> None:
    lines = [
        "# Arbitrum Sepolia demonstration: live evidence",
        "",
        "Generated by `scripts/sepolia_demo.py` (rerunnable; it creates fresh throwaway actors each run). "
        "**Simulation fixtures**: the tokens (SimUSDG, SimStock) and the price feeds (SimEquityFeed) are test fixtures, not real "
        "tokens or Chainlink feeds. **Production code under test**: the Sundown market, guards, oracle adapter, window cache and calendar. "
        "Chain: Arbitrum Sepolia (421614). Addresses: `deployments/421614.json`.",
        "",
        f"Run started {rep.rows[0]['utc']}; every row carries the calendar's blind-window state at that moment.",
        "",
    ]
    section = None
    for r in rep.rows:
        if r["section"] != section:
            section = r["section"]
            lines += ["", f"## {section}", "", "| Time (UTC / ET) | Window state | Action | Result | Tx |", "|---|---|---|---|---|"]
        tx = f"[{r['tx'][:10]}…]({ARBISCAN}/tx/{r['tx']})" if r["tx"] else ""
        res = r["result"].replace("|", "\\|")
        lines.append(f"| {r['utc']}<br>{r['et']} | {r['window']} | {r['action']} | {res} | {tx} |")
    lines += STATIC_SECTIONS
    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
