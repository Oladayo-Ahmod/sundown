"""Unit tests for the exact v3 swap simulator in exit_liquidity.py (no network)."""

from __future__ import annotations

import math
import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# exit_liquidity shells out to `cast sig` at import; stub it so tests run offline.
with mock.patch("subprocess.run") as run:
    run.return_value.stdout = "0x00000000"
    import exit_liquidity as ex

STOCK = "0x" + "11" * 20
USDG = "0x" + "22" * 20


def make_pool(sell_token0: bool, ticks, liquidity=2e18, fee=0.003, tick=0):
    # token0 = stock when sell_token0, else token1 = stock
    t0, t1 = (STOCK, USDG) if sell_token0 else (USDG, STOCK)
    return {
        "pool": "0xpool",
        "sqrtP": ex.sqrt_at(tick),
        "tick": tick,
        "liquidity": liquidity,
        "spacing": 10,
        "fee": fee,
        "token0": t0,
        "token1": t1,
        "ticks": ticks,
        "scan_ticks": (tick - 20000, tick + 20000),
    }


def numeric_sell(pool, sell_token0: bool, amount_in: float, steps=200_000) -> float:
    """Reference: integrate the marginal price over tiny input steps, crossing ticks by hand."""
    liq = float(pool["liquidity"])
    sqrt_p = pool["sqrtP"]
    remaining = amount_in * (1 - pool["fee"])
    cur = pool["tick"]
    bounds = (
        [(t, n) for t, n in reversed(pool["ticks"]) if t <= cur]
        if sell_token0
        else [(t, n) for t, n in pool["ticks"] if t > cur]
    )
    out = 0.0
    dx = remaining / steps
    bi = 0
    while remaining > 1e-12:
        step = min(dx, remaining)
        # marginal price (token1 per token0) is sqrtP^2 selling token0, its inverse selling token1
        if bi < len(bounds):
            target = ex.sqrt_at(bounds[bi][0])
            max_in = liq * (1 / target - 1 / sqrt_p) if sell_token0 else liq * (target - sqrt_p)
            if liq > 0 and step >= max_in:
                step = max_in
        if liq <= 0:
            return math.nan
        if sell_token0:
            new = 1 / (1 / sqrt_p + step / liq)
            out += liq * (sqrt_p - new)
        else:
            new = sqrt_p + step / liq
            out += liq * (1 / sqrt_p - 1 / new)
        sqrt_p = new
        remaining -= step
        if bi < len(bounds) and abs(sqrt_p - ex.sqrt_at(bounds[bi][0])) < 1e-12 * sqrt_p:
            liq += -bounds[bi][1] if sell_token0 else bounds[bi][1]
            bi += 1
        if bi >= len(bounds) and remaining > 1e-9 and liq <= 0:
            return math.nan
    return out


def test_single_range_matches_closed_form_token0():
    pool = make_pool(True, [])
    amount = 1e17
    got = ex.simulate_sell(pool, True, amount)
    eff = amount * (1 - pool["fee"])
    new = 1 / (1 / pool["sqrtP"] + eff / pool["liquidity"])
    assert math.isclose(got, pool["liquidity"] * (pool["sqrtP"] - new), rel_tol=1e-12)


def test_tick_crossing_matches_numeric_integration_both_directions():
    for sell0 in (True, False):
        ticks = [(-200, 5e17), (-100, -2e17), (100, 3e17), (300, -6e17)]
        pool = make_pool(sell0, ticks, liquidity=1.5e18, tick=10)
        amount = 2.5e17
        exact = ex.simulate_sell(pool, sell0, amount)
        ref = numeric_sell(pool, sell0, amount)
        assert exact is not None and not math.isnan(ref)
        assert math.isclose(exact, ref, rel_tol=2e-4), (sell0, exact, ref)


def test_output_is_monotone_and_marginal_price_falls():
    pool = make_pool(True, [(-300, 4e17)], liquidity=1e18)
    outs = [ex.simulate_sell(pool, True, a) for a in (1e16, 5e16, 1e17, 2e17)]
    assert all(o is not None for o in outs)
    assert outs == sorted(outs)
    rates = [o / a for o, a in zip(outs, (1e16, 5e16, 1e17, 2e17), strict=True)]
    assert rates == sorted(rates, reverse=True)


def test_exhausted_liquidity_returns_none():
    pool = make_pool(True, [(-50, 1e18)], liquidity=1e18)  # range ends at tick -50 with L -> 0
    assert ex.simulate_sell(pool, True, 1e21) is None


# A realistic pool: ~$100/share (price_raw = 100e6/1e18 -> tick about -230,270), deep liquidity.
REAL_TICK = -230_270


def test_slippage_includes_fee_and_oracle_basis():
    pool = make_pool(True, [], liquidity=1e22, fee=0.003, tick=REAL_TICK)
    mid = ex.usd_per_stock(pool, STOCK)
    assert 90 < mid < 110
    s = ex.slippage(pool, STOCK, 1.0, mid)
    assert math.isclose(s, 0.003, rel_tol=1e-3)  # ~fee for a negligible trade
    # oracle 5 % above the pool mid: the same trade realises ~5 % extra slippage
    s_basis = ex.slippage(pool, STOCK, 1.0, mid * 1.05)
    assert math.isclose(s_basis, 1 - (1 - 0.003) / 1.05, rel_tol=1e-3)


def test_max_notional_respects_target_and_is_zero_when_basis_exceeds_it():
    pool = make_pool(True, [], liquidity=1e17, fee=0.003, tick=REAL_TICK)  # ~$1M virtual USDG
    mid = ex.usd_per_stock(pool, STOCK)
    n = ex.max_notional(pool, STOCK, 0.03, mid)
    assert 1e4 < n < 1e6
    assert math.isclose(ex.slippage(pool, STOCK, n, mid), 0.03, abs_tol=1e-4)
    assert ex.max_notional(pool, STOCK, 0.03, mid * 1.2) == 0
