"""Exact-integer reference model of the Sundown market core (offline analysis, not production).

An independent re-implementation of the arithmetic in contracts/src (KinkedRate, SharesMath,
SundownMarket with FlatGuard) written from docs/MARKET_DESIGN.md, not by transliterating the
Solidity: Python big integers with the same rounding rules. It generates
contracts/test/fixtures/market_cases.json, which the Foundry tests replay against the real
contracts (rate curve, compounding, share conversions and a randomized multi-actor scenario with
borrows, repayments, liquidations at several prices, bad debt and lender deposits/redemptions).

Run: python market_reference.py [--out PATH] [--seed N]
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import random
from dataclasses import dataclass, field
from pathlib import Path

WAD = 10**18
SECONDS_PER_YEAR = 365 * 24 * 3600
VIRTUAL_SHARES = 10**6  # borrow shares (SharesMath) and the vault share offset (decimals offset 6)
VIRTUAL_ASSETS = 1
DEFAULT_OUT = Path(__file__).resolve().parents[1] / "contracts/test/fixtures/market_cases.json"


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


# ---------------------------------------------------------------- rate model


def apr_wad(base: int, slope1: int, slope2: int, kink: int, util: int) -> int:
    if util <= kink:
        return base + slope1 * util // kink
    return base + slope1 + slope2 * (util - kink) // (WAD - kink)


def rate_per_second(base: int, slope1: int, slope2: int, kink: int, util: int) -> int:
    return apr_wad(base, slope1, slope2, kink, util) // SECONDS_PER_YEAR


def compound_factor(rate: int, elapsed: int) -> int:
    x = rate * elapsed
    x2 = x * x // WAD
    x3 = x2 * x // WAD
    return x + x2 // 2 + x3 // 6


def exact_growth(rate: int, elapsed: int) -> float:
    """Reference exp(x) - 1 in floating point, for documenting the Taylor truncation error."""
    return math.expm1(rate * elapsed / WAD)


# ---------------------------------------------------------------- shares


def to_shares_down(a: int, ta: int, ts: int) -> int:
    return a * (ts + VIRTUAL_SHARES) // (ta + VIRTUAL_ASSETS)


def to_shares_up(a: int, ta: int, ts: int) -> int:
    return ceil_div(a * (ts + VIRTUAL_SHARES), ta + VIRTUAL_ASSETS)


def to_assets_down(s: int, ta: int, ts: int) -> int:
    return s * (ta + VIRTUAL_ASSETS) // (ts + VIRTUAL_SHARES)


def to_assets_up(s: int, ta: int, ts: int) -> int:
    return ceil_div(s * (ta + VIRTUAL_ASSETS), ts + VIRTUAL_SHARES)


# ---------------------------------------------------------------- market model


class Invalid(Exception):
    """The operation would revert in the contract."""


@dataclass
class Params:
    lltv: int = 800_000_000_000_000_000
    close_factor: int = 500_000_000_000_000_000
    critical_health: int = 950_000_000_000_000_000
    max_bonus: int = 55_000_000_000_000_000
    collateral_cap: int = 1000 * 10**18
    min_debt: int = 10 * 10**6
    base: int = 0
    slope1: int = 40_000_000_000_000_000
    slope2: int = 750_000_000_000_000_000
    kink: int = 800_000_000_000_000_000
    ltv: int = 750_000_000_000_000_000  # FlatGuard borrow LTV
    bonus: int = 40_000_000_000_000_000  # FlatGuard flat bonus
    value_scale: int = 10**30  # 10^(18 collateral dec + 18 - 6 loan dec)


@dataclass
class Market:
    p: Params = field(default_factory=Params)
    now: int = 0
    last: int = 0
    price: int = 100 * WAD
    idle: int = 0
    tba: int = 0  # totalBorrowAssets
    tbs: int = 0  # totalBorrowShares
    bad: int = 0
    tc: int = 0  # totalCollateral
    supply: int = 0  # vault shares
    vault: dict = field(default_factory=dict)  # user -> vault shares
    pos: dict = field(default_factory=dict)  # user -> [borrowShares, collateral]

    # --- accrual
    def pending(self) -> int:
        elapsed = self.now - self.last
        if elapsed <= 0 or self.tba == 0:
            return 0
        util = self.tba * WAD // (self.idle + self.tba)
        r = rate_per_second(self.p.base, self.p.slope1, self.p.slope2, self.p.kink, util)
        return ceil_div(self.tba * compound_factor(r, elapsed), WAD)

    def total_assets(self) -> int:
        return self.idle + self.tba + self.pending()

    def accrue(self) -> None:
        self.tba += self.pending()
        self.last = self.now

    def _pos(self, u: str) -> list:
        return self.pos.setdefault(u, [0, 0])

    def debt(self, u: str) -> int:
        return to_assets_up(self._pos(u)[0], self.tba, self.tbs)

    def cv(self, collateral: int) -> int:
        return collateral * self.price // self.p.value_scale

    # --- lenders (ERC-4626, offset 6)
    def deposit(self, u: str, assets: int) -> int:
        if assets <= 0:
            raise Invalid
        shares = assets * (self.supply + VIRTUAL_SHARES) // (self.total_assets() + 1)
        self.accrue()
        self.idle += assets
        self.supply += shares
        self.vault[u] = self.vault.get(u, 0) + shares
        return shares

    def redeem(self, u: str, shares: int) -> int:
        ta = self.total_assets()
        # ERC-4626 maxRedeem as overridden by the market: min(balance, shares worth the idle assets)
        max_redeem = min(
            self.vault.get(u, 0), self.idle * (self.supply + VIRTUAL_SHARES) // (ta + 1)
        )
        if shares <= 0 or shares > max_redeem:
            raise Invalid
        assets = shares * (ta + 1) // (self.supply + VIRTUAL_SHARES)
        if assets > self.idle or assets == 0:
            raise Invalid
        self.accrue()
        self.idle -= assets
        self.supply -= shares
        self.vault[u] -= shares
        return assets

    # --- collateral
    def deposit_collateral(self, u: str, amount: int) -> None:
        if amount <= 0 or self.tc + amount > self.p.collateral_cap:
            raise Invalid
        self.tc += amount
        self._pos(u)[1] += amount

    def _capacity_ok(self, u: str) -> bool:
        debt = self.debt(u)
        if self.price <= 0:
            return False
        cv = self.cv(self._pos(u)[1])
        cap = min(cv * self.p.ltv // WAD, cv * self.p.lltv // WAD)
        return cap >= debt >= self.p.min_debt

    def withdraw_collateral(self, u: str, amount: int) -> None:
        if amount <= 0 or amount > self._pos(u)[1]:
            raise Invalid
        self.accrue()
        self._pos(u)[1] -= amount
        self.tc -= amount
        if self.debt(u) != 0 and not self._capacity_ok(u):
            raise Invalid

    # --- borrow / repay
    def borrow(self, u: str, assets: int) -> int:
        if assets <= 0:
            raise Invalid
        self.accrue()
        if assets > self.idle:
            raise Invalid
        shares = to_shares_up(assets, self.tba, self.tbs)
        self._pos(u)[0] += shares
        self.tbs += shares
        self.tba += assets
        self.idle -= assets
        if not self._capacity_ok(u):
            raise Invalid
        return shares

    def repay(self, payer: str, on_behalf: str, assets: int) -> int:
        if assets <= 0:
            raise Invalid
        self.accrue()
        debt = self.debt(on_behalf)
        if debt == 0:
            raise Invalid
        if assets >= debt:
            shares, paid = self._pos(on_behalf)[0], debt
        else:
            shares, paid = to_shares_down(assets, self.tba, self.tbs), assets
        self._pos(on_behalf)[0] -= shares
        self.tbs -= shares
        self.tba = 0 if paid >= self.tba else self.tba - paid
        self.idle += paid
        rest = self.debt(on_behalf)
        if rest != 0 and rest < self.p.min_debt:
            raise Invalid
        return paid

    # --- liquidation (FlatGuard)
    def liquidate(
        self,
        borrower: str,
        repay_assets: int,
        bonus: int | None = None,
        force: bool = False,
    ) -> tuple[int, int]:
        """`bonus`/`force` let a guard model override the flat bonus and the allowed test (deleverage)."""
        if repay_assets <= 0:
            raise Invalid
        self.accrue()
        pos = self._pos(borrower)
        debt = self.debt(borrower)
        if debt == 0 or self.price <= 0:
            raise Invalid
        collateral = pos[1]
        cv = self.cv(collateral)
        if not force and not debt > cv * self.p.lltv // WAD:  # FlatGuard.liquidationAllowed
            raise Invalid
        max_repay = ceil_div(debt * self.p.close_factor, WAD)
        if (cv * self.p.lltv // WAD) * WAD < self.p.critical_health * debt:
            max_repay = debt
        repay = min(repay_assets, max_repay, debt)
        rest = debt - repay
        if rest != 0 and rest < self.p.min_debt:
            repay = debt
        b = min(self.p.bonus if bonus is None else bonus, self.p.max_bonus)
        if cv > debt:
            b = min(b, cv * WAD // debt - WAD)
        seized = repay * (WAD + b) // WAD * self.p.value_scale // self.price
        if seized > collateral:
            seized = collateral
            repay = seized * self.price // self.p.value_scale * WAD // (WAD + b)
        if repay == 0:
            raise Invalid
        burned = pos[0] if repay >= debt else min(to_shares_down(repay, self.tba, self.tbs), pos[0])
        pos[0] -= burned
        self.tbs -= burned
        self.tba = 0 if repay >= self.tba else self.tba - repay
        pos[1] -= seized
        self.tc -= seized
        self.idle += repay
        return repay, seized

    def liquidatable(self, u: str) -> bool:
        debt = self.debt(u)
        return debt > 0 and self.price > 0 and debt > self.cv(self._pos(u)[1]) * self.p.lltv // WAD

    def realize_bad_debt(self, borrower: str) -> int:
        self.accrue()
        pos = self._pos(borrower)
        if pos[1] != 0 or pos[0] == 0:
            raise Invalid
        written = min(to_assets_up(pos[0], self.tba, self.tbs), self.tba)
        self.tbs -= pos[0]
        pos[0] = 0
        self.tba -= written
        self.bad += written
        return written


# ---------------------------------------------------------------- fixtures

ACTORS = ["a0", "a1", "a2", "a3"]
SNAP_STRIDE = 6 + 3 * len(ACTORS)
OPS = {
    "deposit": 0, "redeem": 1, "depositCollateral": 2, "withdrawCollateral": 3, "borrow": 4,
    "repay": 5, "liquidate": 6, "warp": 7, "setPrice": 8, "realize": 9, "accrue": 10,
}  # fmt: skip


def snapshot(m: Market) -> list[int]:
    out = [m.idle, m.tba, m.tbs, m.supply, m.bad, m.tc]
    for a in ACTORS:
        pos = m._pos(a)
        out += [pos[0], pos[1], m.vault.get(a, 0)]
    return out


def rate_cases() -> dict:
    p = Params()
    utils = sorted({0, WAD, p.kink, p.kink - 1, p.kink + 1, *(i * WAD // 40 for i in range(41))})
    return {
        "util": utils,
        "apr": [apr_wad(p.base, p.slope1, p.slope2, p.kink, u) for u in utils],
        "rate": [rate_per_second(p.base, p.slope1, p.slope2, p.kink, u) for u in utils],
    }


def compound_cases() -> dict:
    p = Params()
    rates = [
        rate_per_second(p.base, p.slope1, p.slope2, p.kink, u)
        for u in (WAD // 100, WAD // 2, p.kink, WAD)
    ] + [1, 10**9]
    times = [1, 60, 3600, 86_400, 30 * 86_400, SECONDS_PER_YEAR, 5 * SECONDS_PER_YEAR]
    rs, es, fs = [], [], []
    for r in rates:
        for t in times:
            rs.append(r)
            es.append(t)
            fs.append(compound_factor(r, t))
    return {"rate": rs, "elapsed": es, "factor": fs}


def shares_cases(rng: random.Random, n: int = 2000) -> dict:
    cols: dict[str, list[int]] = {k: [] for k in ("a", "ta", "ts", "down", "up", "adown", "aup")}
    for _ in range(n):
        ta = rng.choice([0, 1, rng.randrange(10**3), rng.randrange(10**12), rng.randrange(10**21)])
        ts = rng.choice([0, 1, rng.randrange(10**6), rng.randrange(10**15), rng.randrange(10**27)])
        a = rng.choice([0, 1, rng.randrange(10**6), rng.randrange(10**12), rng.randrange(10**18)])
        cols["a"].append(a)
        cols["ta"].append(ta)
        cols["ts"].append(ts)
        cols["down"].append(to_shares_down(a, ta, ts))
        cols["up"].append(to_shares_up(a, ta, ts))
        cols["adown"].append(to_assets_down(a, ta, ts))  # `a` reused as a share amount
        cols["aup"].append(to_assets_up(a, ta, ts))
    return cols


def scenario(rng: random.Random, steps: int = 900) -> dict:
    m = Market()
    cols: dict[str, list] = {k: [] for k in ("op", "actor", "target", "a", "ret1", "ret2", "snap")}
    prices = [20, 30, 40, 55, 70, 80, 90, 95, 100, 110, 120, 140]
    tries = 0
    while len(cols["op"]) < steps and tries < steps * 40:
        tries += 1
        before = copy.deepcopy(m)
        op = rng.choices(
            ["deposit", "redeem", "depositCollateral", "withdrawCollateral", "borrow", "repay",
             "liquidate", "warp", "setPrice", "realize", "accrue"],
            weights=[8, 3, 8, 2, 14, 5, 14, 8, 10, 6, 2],
        )[0]  # fmt: skip
        actor = rng.choice(ACTORS)
        target = rng.choice(ACTORS)
        if op == "liquidate":
            liq = [a for a in ACTORS if m.liquidatable(a)]
            if liq and rng.random() < 0.9:
                target = rng.choice(liq)
        if op == "realize":
            bad = [a for a in ACTORS if m._pos(a)[1] == 0 and m._pos(a)[0] > 0]
            if bad:
                target = rng.choice(bad)
        ret1 = ret2 = 0
        try:
            if op == "deposit":
                a = rng.choice(
                    [10**6, 100 * 10**6, 5000 * 10**6, rng.randrange(10**6, 20_000 * 10**6)]
                )
                m.deposit(actor, a)
            elif op == "redeem":
                a = rng.randrange(1, max(2, m.vault.get(actor, 0) + 1))
                ret1 = m.redeem(actor, a)
            elif op == "depositCollateral":
                a = rng.choice([10**17, 10**18, 5 * 10**18, rng.randrange(10**16, 50 * 10**18)])
                m.deposit_collateral(actor, a)
            elif op == "withdrawCollateral":
                a = rng.randrange(1, max(2, m._pos(actor)[1] + 1))
                m.withdraw_collateral(actor, a)
            elif op == "borrow":
                coll_value = m.cv(m._pos(actor)[1])
                a = rng.choice(
                    [
                        10 * 10**6,
                        rng.randrange(10**6, max(10**6 + 1, coll_value)),
                        coll_value * 3 // 4,
                    ]
                    + [coll_value * 3 // 4] * 4  # bias toward maximum leverage
                )
                m.borrow(actor, max(1, a))
            elif op == "repay":
                a = rng.choice([10**6, rng.randrange(1, max(2, m.debt(target) + 1)), 10**15])
                ret1 = m.repay(actor, target, a)
            elif op == "liquidate":
                a = rng.choice(
                    [10**6, rng.randrange(1, max(2, m.debt(target) + 1)), 10**15, m.debt(target)]
                )
                ret1, ret2 = m.liquidate(target, a)
            elif op == "warp":
                a = rng.choice([1, 3600, 86_400, rng.randrange(1, 30 * 86_400), 90 * 86_400])
                m.now += a
            elif op == "setPrice":
                a = rng.choice(prices) * WAD
                m.price = a
            elif op == "realize":
                a = 0
                ret1 = m.realize_bad_debt(target)
            else:
                a = 0
                m.accrue()
        except Invalid:
            m = before
            continue
        cols["op"].append(OPS[op])
        cols["actor"].append(ACTORS.index(actor))
        cols["target"].append(ACTORS.index(target))
        cols["a"].append(a)
        cols["ret1"].append(ret1)
        cols["ret2"].append(ret2)
        cols["snap"].append(snapshot(m))
    stats = {k: cols["op"].count(v) for k, v in OPS.items()}
    cols["snap"] = [x for row in cols["snap"] for x in row]  # flat; stride = SNAP_STRIDE
    return {"cols": cols, "stats": stats, "final_bad_debt": m.bad}


def run_script(steps: list[tuple]) -> dict:
    """Run a hand-written op list in the scenario column format (every step must be valid)."""
    m = Market()
    cols: dict[str, list] = {k: [] for k in ("op", "actor", "target", "a", "ret1", "ret2", "snap")}
    for name, actor, target, a in steps:
        who, tgt = ACTORS[actor], ACTORS[target]
        ret1 = ret2 = 0
        if name == "deposit":
            m.deposit(who, a)
        elif name == "redeem":
            ret1 = m.redeem(who, a)
        elif name == "depositCollateral":
            m.deposit_collateral(who, a)
        elif name == "borrow":
            m.borrow(who, a)
        elif name == "repay":
            ret1 = m.repay(who, tgt, a)
        elif name == "liquidate":
            ret1, ret2 = m.liquidate(tgt, a)
        elif name == "warp":
            m.now += a
        elif name == "setPrice":
            m.price = a
        elif name == "realize":
            ret1 = m.realize_bad_debt(tgt)
        elif name == "accrue":
            m.accrue()
        else:
            raise ValueError(name)
        cols["op"].append(OPS[name])
        cols["actor"].append(actor)
        cols["target"].append(target)
        cols["a"].append(a)
        cols["ret1"].append(ret1)
        cols["ret2"].append(ret2)
        cols["snap"].append(snapshot(m))
    stats = {k: cols["op"].count(v) for k, v in OPS.items()}
    cols["snap"] = [x for row in cols["snap"] for x in row]
    return {"cols": cols, "stats": stats, "final_bad_debt": m.bad}


def bad_debt_scenario() -> dict:
    """Exact-integer cover for `realizeBadDebt`.

    Three insolvent borrowers at different interest ages, a lender redeeming between
    realizations (the share price drop is exact), and a last tiny-debt borrower whose
    write-off drains `totalBorrowAssets` to zero. The `min(..., totalBorrowAssets)` clamp
    never binds here: it is unreachable from valid states (the minimum-debt rule leaves no
    sub-unit residual debt), so it stays as defense in depth.
    """
    day = 86_400
    steps: list[tuple] = [
        ("deposit", 0, 0, 100_000 * 10**6),
        ("depositCollateral", 1, 1, 10 * 10**18),
        ("depositCollateral", 2, 2, 10 * 10**18),
        ("depositCollateral", 3, 3, 10 * 10**18),
        ("borrow", 1, 1, 750 * 10**6),
        ("warp", 0, 0, 7 * day),
        ("borrow", 2, 2, 700 * 10**6),
        ("warp", 0, 0, 20 * day),
        ("borrow", 3, 3, 10 * 10**6),
        ("warp", 0, 0, 40 * day),
        ("setPrice", 0, 0, 20 * WAD),
        # a1: fully insolvent -> liquidated to zero collateral, residual debt realized
        ("liquidate", 0, 1, 10**15),
        ("realize", 0, 1, 0),
        ("warp", 0, 0, 3 * day),
        ("redeem", 0, 0, 10_000 * 10**12),
        # a2: realized after another accrual interval
        ("liquidate", 0, 2, 10**15),
        ("warp", 0, 0, 90 * day),
        ("realize", 0, 2, 0),
        ("redeem", 0, 0, 5_000 * 10**12),
        # a3: tiny debt, price crash so that seized collateral is worth almost nothing
        ("setPrice", 0, 0, 10**12),
        ("liquidate", 0, 3, 10**15),
        ("warp", 0, 0, 1),
        ("realize", 0, 3, 0),
    ]
    return run_script(steps)


def build(seed: int) -> dict:
    rng = random.Random(seed)
    return {
        "meta": {
            "generator": "research/market_reference.py",
            "seed": seed,
            "ops": OPS,
            "snapStride": SNAP_STRIDE,
        },
        "rate": rate_cases(),
        "compound": compound_cases(),
        "shares": shares_cases(rng),
        "scenario": scenario(rng),
        "badDebt": bad_debt_scenario(),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--seed", type=int, default=20261002)
    args = ap.parse_args()
    out = build(args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, separators=(",", ":")))
    st = out["scenario"]["stats"]
    print(
        f"wrote {args.out} ops={sum(st.values())} stats={st} "
        f"bad_debt={out['scenario']['final_bad_debt']}"
    )


if __name__ == "__main__":
    main()
