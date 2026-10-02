import numpy as np
import pytest

import credit_sim as cs
import liquidation as lq


def test_matches_credit_sim_with_infinite_depth_and_no_drift():
    rng = np.random.default_rng(4)
    x = rng.normal(-300, 700, 300)
    ctl = cs.Control("t", 0.86, 0.044)
    ref = cs.run_events(x, None, ctl, cs.Params())
    d = lq.Design("flat", "flat", 0.044, 1.0)
    out = lq.simulate(x, np.zeros_like(x), [lq.Tier(0.86)], d, None, 1e6)
    assert out["loss_ratio"] == pytest.approx(ref["loss_ratio"], abs=1e-9)


def test_capacity_formula_and_no_liquidation_when_bonus_below_gas():
    y = 1e6
    assert lq.capacity(0.044, y) == pytest.approx(y * (0.044 - lq.GAS) / (1 - 0.044 + lq.GAS))
    assert lq.capacity(lq.GAS / 2, y) == 0.0
    # average slippage of selling exactly the capacity equals bonus - gas
    n = float(lq.capacity(0.055, y))
    assert n / (n + y) == pytest.approx(0.055 - lq.GAS, rel=1e-9)


def test_shallow_pool_increases_bad_debt_and_depth_helps():
    x = np.array([-1200.0, -1800.0, -900.0])
    oc = np.array([-200.0, -300.0, 0.0])
    d = lq.Design("flat", "flat", 0.055, 1.0)
    deep = lq.simulate(x, oc, [lq.Tier(0.93)], d, 1e12, 1e6)["bad"].sum()
    mid = lq.simulate(x, oc, [lq.Tier(0.93)], d, 1e6, 1e6)["bad"].sum()
    shallow = lq.simulate(x, oc, [lq.Tier(0.93)], d, 2e5, 1e6)["bad"].sum()
    assert shallow >= mid >= deep


def test_protocol_cap_cannot_beat_rational_capacity():
    x = np.array([-1500.0])
    oc = np.array([-250.0])
    free = lq.simulate(x, oc, [lq.Tier(0.9)], lq.Design("f", "flat", 0.055), 1e6, 1e6)
    capped = lq.simulate(x, oc, [lq.Tier(0.9)], lq.Design("c", "cap", 0.055, phi=0.02), 1e6, 1e6)
    assert capped["bad"].sum() >= free["bad"].sum() - 1e-9
    assert capped["sold"].sum() <= free["sold"].sum() + 1e-9


def test_two_tier_enforcement_reduces_boosted_debt():
    cap = np.array([0.80])
    t0 = [lq.Tier(0.77, 0.7), lq.Tier(0.93, 0.3)]
    t1 = [lq.Tier(0.77, 0.7), lq.Tier(0.93, 0.3, cap=cap)]
    d = lq.Design("f", "flat", 0.055)
    a = lq.simulate(np.array([0.0]), np.array([0.0]), t0, d, None, 1e6)
    b = lq.simulate(np.array([0.0]), np.array([0.0]), t1, d, None, 1e6)
    assert b["debt"][0] < a["debt"][0] and b["flagged"][0] > 0
