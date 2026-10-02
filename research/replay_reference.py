"""Exact-integer reference of the on-chain replay harness (sim/ReplayHarness.sol).

SIMULATION. Replays the worst real AAPL/SPY gaps (`sim/replay_inputs.json`) through three markets
built from the integer market model in `market_reference.py`:

  control   FlatGuard at the boosted LLTV (a conventional market that keeps using the frozen price)
  sundown   session-aware LLTV: boosted weekday capacity, tighter weekend capacity (SundownGuard)
  standard  FlatGuard at the standard LLTV (the status quo)

Timeline per event (seconds): t=0 borrow; t=S-H stress period starts; t=S-H+C deleverage zone opens
and the keeper deleverages every eligible account; t=S window starts (price frozen); t=S+W
reopening at the gapped price; the keeper liquidates everything unhealthy (up to 5 rounds) and bad
debt is realized.

Output rows are CSV and are compared to the Solidity harness by `sim/compare_replay.py`. The guard
rules are re-implemented here from docs/GUARD_DESIGN.md, not imported from the contract.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from market_reference import WAD, Invalid, Market, Params, ceil_div

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ROOT / "sim" / "replay_inputs.json"

H = 6 * 3600
C = 3 * 3600
S = 12 * 3600  # window start, relative to the borrow time
STANDARD = 860_000_000_000_000_000
OB = 5_000_000_000_000_000
SB = 10_000_000_000_000_000
BONUS = 40_000_000_000_000_000
FEE = 20_000_000_000_000_000
MARGIN = 5_000_000_000_000_000
N_BORROWERS = 20
COLLATERAL = 50 * 10**18
LENDER_DEPOSIT = 5_000_000 * 10**6
GAS_USD_PER_TX = 0.5  # ASSUMPTION: cost of one deleverage transaction, USD (Orbit-class fees)
FEE_BOUND = 55_000_000_000_000_000

# D26: full-sample empirical q99.5 downside gap (bps), research/results/class_stats.csv,
# sample 2010-01-04..2026-10-01
GAP_BPS = {
    "AAPL": {0: 282.99, 1: 915.29, 2: 597.0},
    "SPY": {0: 161.52, 1: 407.13, 2: 297.99},
}


def gap_wad(asset: str, cls: int) -> int:
    return int(round(GAP_BPS[asset][cls] * 10**14))


def stress_fraction(asset: str, cls: int) -> int:
    h = gap_wad(asset, cls) + OB + SB
    return 0 if h >= WAD else WAD - h


def required_repay(cv: int, debt: int, cap_frac: int) -> int:
    t = cap_frac - MARGIN if cap_frac > MARGIN else 0
    target = cv * t // WAD
    if debt <= target:
        return 0
    growth = ceil_div(t * (WAD + FEE), WAD)
    if growth >= WAD:
        return debt
    r = ceil_div((debt - target) * WAD, WAD - growth)
    return min(r, debt)


def make_market(lltv: int, ltv: int) -> Market:
    p = Params(lltv=lltv, ltv=ltv, bonus=BONUS, collateral_cap=10_000 * 10**18)
    m = Market(p=p)
    m.deposit("lender", LENDER_DEPOSIT)
    return m


def borrower_debt(ltv_cap: int, i: int) -> int:
    # leverage-seeking population: debt is 80 %..99 % of the tier cap, spread over (i mod 10);
    # a borrower exactly at the cap would drift over the threshold from interest alone, so none sits
    # at 100 %
    f = 800_000_000_000_000_000 + 190_000_000_000_000_000 * (i % 10) // 9
    cv = COLLATERAL * (100 * WAD) // 10**30
    return cv * ltv_cap // WAD * f // WAD


def populate(m: Market, ltv_cap: int) -> int:
    total = 0
    for i in range(N_BORROWERS):
        u = f"b{i}"
        m.deposit_collateral(u, COLLATERAL)
        d = borrower_debt(ltv_cap, i)
        m.borrow(u, d)
        total += d
    return total


def reopen_and_liquidate(m: Market, threshold: int) -> tuple[int, int]:
    """Keeper liquidates everything unhealthy (5 rounds), then bad debt is realized.

    Returns (liquidation calls, loss).
    """
    liqs = 0
    for _ in range(5):
        progressed = False
        for i in range(N_BORROWERS):
            u = f"b{i}"
            debt = m.debt(u)
            if debt == 0 or m._pos(u)[1] == 0:
                continue
            cv = m.cv(m._pos(u)[1])
            if debt > cv * threshold // WAD:
                try:
                    m.liquidate(u, debt)
                    liqs += 1
                    progressed = True
                except Invalid:
                    pass
        if not progressed:
            break
    for i in range(N_BORROWERS):
        u = f"b{i}"
        pos = m._pos(u)
        if pos[1] == 0 and pos[0] > 0:
            m.realize_bad_debt(u)
    return liqs, m.bad


@dataclass
class Row:
    asset: str
    tier_bps: int
    date: str
    variant: str
    loss: int
    ordinary_liq: int
    deleverage_calls: int
    deleverage_debt: int
    deleverage_notional: int
    cap_weekday: int
    cap_window: int
    borrowed: int

    def csv(self) -> str:
        return ",".join(str(x) for x in (
            self.asset, self.tier_bps, self.date, self.variant, self.loss, self.ordinary_liq,
            self.deleverage_calls, self.deleverage_debt, self.deleverage_notional, self.cap_weekday,
            self.cap_window, self.borrowed))  # fmt: skip


def run_event(asset: str, tier: int, ev: dict) -> list[Row]:
    p1 = 100 * WAD * ev["ratioWad"] // WAD
    rows: list[Row] = []

    # ---- standard tier control and boosted-LLTV control: frozen price, flat rules
    for variant, lltv in (("standard", STANDARD), ("control", tier)):
        m = make_market(lltv, lltv)
        borrowed = populate(m, lltv)
        m.now = S + ev["windowSeconds"]
        m.price = p1
        liqs, loss = reopen_and_liquidate(m, lltv)
        cv0 = COLLATERAL * (100 * WAD) // 10**30
        cap = cv0 * lltv // WAD * N_BORROWERS
        tier_bps = tier * 10**4 // WAD
        rows.append(
            Row(asset, tier_bps, ev["date"], variant, loss, liqs, 0, 0, 0, cap, cap, borrowed)
        )

    # ---- session-aware market
    m = make_market(tier, tier)
    borrowed = populate(m, tier)
    cls = ev["cls"]
    sf = stress_fraction(asset, cls)
    cap_frac = min(tier, sf)
    cv0 = COLLATERAL * (100 * WAD) // 10**30
    cap_weekday = cv0 * tier // WAD * N_BORROWERS
    cap_window = cv0 * cap_frac // WAD * N_BORROWERS

    m.now = S - H + C  # zone opens; price unchanged (Fresh)
    calls = delev_debt = notional = 0
    for _ in range(4):
        progressed = False
        for i in range(N_BORROWERS):
            u = f"b{i}"
            m.accrue()
            debt = m.debt(u)
            if debt == 0:
                continue
            cv = m.cv(m._pos(u)[1])
            if debt <= cv * tier // WAD:  # healthy (never unhealthy at an unchanged price)
                if debt > cv * cap_frac // WAD:  # above the stress cap: deleverage-eligible
                    r = required_repay(cv, debt, cap_frac)
                    if r > 0:
                        try:
                            repaid, seized = m.liquidate(u, r, bonus=FEE, force=True)
                        except Invalid:
                            continue
                        calls += 1
                        delev_debt += repaid
                        notional += repaid * (WAD + FEE) // WAD
                        progressed = True
        if not progressed:
            break
    m.now = S + ev["windowSeconds"]
    m.price = p1
    liqs, loss = reopen_and_liquidate(m, tier)
    tier_bps = tier * 10**4 // WAD
    rows.append(
        Row(
            asset, tier_bps, ev["date"], "sundown", loss, liqs, calls, delev_debt, notional,
            cap_weekday, cap_window, borrowed,
        )
    )  # fmt: skip
    return rows


def slippage_wad(notional_usd: float, d1: int, d3: int, d5: int) -> float | None:
    """Average slippage (fraction) for selling `notional_usd`, piecewise linear through the depth
    table; None beyond the 5 % point (the table does not resolve it)."""
    pts = [(0.0, 0.0), (float(d1), 0.01), (float(d3), 0.03), (float(d5), 0.05)]
    if notional_usd > pts[-1][0]:
        return None
    for (x0, y0), (x1, y1) in zip(pts, pts[1:], strict=False):
        if notional_usd <= x1:
            return y0 if x1 == x0 else y0 + (y1 - y0) * (notional_usd - x0) / (x1 - x0)
    return None


def breakeven(batch_usd: float, depth: dict) -> dict:
    s = slippage_wad(batch_usd, depth["d1"], depth["d3"], depth["d5"])
    if s is None:
        return {"slippage": None, "breakeven": None, "viable": False}
    f = s + GAS_USD_PER_TX / max(batch_usd, 1e-9)
    return {"slippage": s, "breakeven": f, "viable": f * WAD <= FEE_BOUND}


def max_viable_batch(depth: dict, fee: float) -> float:
    """Largest batch whose slippage plus gas share stays within `fee` (bisection on the table)."""
    lo, hi = 1.0, float(depth["d5"])
    for _ in range(60):
        mid = (lo + hi) / 2
        b = breakeven(mid, depth)
        if b["breakeven"] is not None and b["breakeven"] <= fee:
            lo = mid
        else:
            hi = mid
    return lo


def main() -> None:
    data = json.loads(INPUTS.read_text())
    print("asset,tierBps,date,variant,loss,ordLiq,delevCalls,delevDebt,delevNotional,capWeekday,capWindow,borrowed")
    for ev in data["events"]:
        asset = ev["asset"]
        for tier in (930_000_000_000_000_000, 900_000_000_000_000_000):
            for row in run_event(asset, tier, ev):
                print(row.csv())


if __name__ == "__main__":
    main()
