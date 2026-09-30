import numpy as np
import pandas as pd
import pytest

import credit_sim as cs
import static_rule as sr
from config import RESULTS_DIR


def test_required_repay_reaches_target():
    d, t_val, fee, target = 0.93, 1.0, 0.02, 0.8885
    r = float(sr.required_repay(np.array([d]), np.array([t_val]), np.array([target]), fee)[0])
    ltv = (d - r) / (t_val - r * (1 + fee))
    assert ltv == pytest.approx(target, abs=1e-9)
    assert r == pytest.approx(0.443, abs=2e-3)  # deleveraging near max LTV is expensive


def test_stress_fraction_formula():
    sf = sr.stress_fraction(np.array([915.29, 5000.0, 20000.0]))
    assert sf[0] == pytest.approx(1 - 0.091529 - 0.015)
    assert sf[1] == pytest.approx(0.485)
    assert sf[2] == 0.0


def _events(n=200, seed=1):
    rng = np.random.default_rng(seed)
    x = rng.normal(-100, 500, n)
    oc = rng.normal(0, 150, n)
    return x, oc


def test_flat_book_matches_credit_sim_with_infinite_depth_and_no_drift():
    x, _ = _events()
    oc = np.zeros_like(x)
    gv = np.full_like(x, 300.0)
    r = sr.simulate_book(x, oc, gv, 0.86, sr.DepthInfinite(), 1e6, rule=False, bonus=0.044)
    ref = cs.run_events(x, None, cs.Control("t", 0.86, 0.044), cs.Params())
    assert r.loss_ratio == pytest.approx(ref["loss_ratio"], abs=1e-9)


def test_rule_that_does_not_bind_is_identical_to_flat():
    x, oc = _events()
    gv = np.full_like(x, 300.0)  # stress fraction 95.5 % > 93 % tier
    a = sr.simulate_book(x, oc, gv, 0.93, sr.DepthInfinite(), 1e6, rule=False)
    b = sr.simulate_book(x, oc, gv, 0.93, sr.DepthInfinite(), 1e6, rule=True, behaviour="naive")
    assert b.flagged_share.sum() == 0 and b.fee_paid.sum() == 0
    assert b.loss_ratio == pytest.approx(a.loss_ratio)


def test_binding_rule_flags_trims_and_charges_fee_only_when_naive():
    x, oc = _events()
    gv = np.full_like(x, 915.29)  # stress fraction 89.35 %
    naive = sr.simulate_book(x, oc, gv, 0.93, sr.DepthInfinite(), 1e6, behaviour="naive")
    rational = sr.simulate_book(x, oc, gv, 0.93, sr.DepthInfinite(), 1e6, behaviour="rational")
    assert (naive.flagged_share > 0).all() and naive.fee_paid.sum() > 0
    assert rational.fee_paid.sum() == 0 and rational.flagged_share.sum() == 0
    # fee charged = fee x repaid debt
    assert naive.fee_paid.sum() == pytest.approx(sr.FEE_FLOOR * naive.trimmed_debt.sum(), rel=1e-9)
    assert (naive.debt_post <= naive.debt_pre + 1e-9).all()


def test_executes_only_within_depth_capacity():
    x, oc = _events(50)
    gv = np.full_like(x, 915.29)
    tiny = sr.DepthV3(10.0, 20.0, 30.0)  # essentially no exit liquidity
    r = sr.simulate_book(x, oc, gv, 0.93, tiny, 1e6, behaviour="naive")
    assert r.trimmed_debt.max() < 100  # a handful of dollars at most
    assert r.unexecuted_debt.sum() > 0  # enforcement silently does not happen without depth


def test_depth_v3_capacity_and_inverse():
    d = sr.DepthV3(85_822, 196_590, 220_049)
    assert d.capacity(np.array([0.0]))[0] == 0.0
    assert d.capacity(np.array([0.01 + sr.GAS]))[0] == pytest.approx(85_822)
    assert d.capacity(np.array([0.5]))[0] == pytest.approx(220_049)  # saturates
    assert d.slippage_for(85_822) == pytest.approx(0.01)
    assert d.slippage_for(1e9) == float("inf")


def test_static_gapvar_file_matches_class_stats_and_provenance():
    gv = pd.read_csv(RESULTS_DIR / "static_gapvar.csv")
    cs_ = pd.read_csv(RESULTS_DIR / "class_stats.csv")
    for r in gv.itertuples():
        want = cs_[(cs_.ticker == r.ticker) & (cs_.cls == r.cls)]["loss_q99.5_bps"].iloc[0]
        assert r.gap_var_bps_q995 == pytest.approx(want, abs=0.01)
    assert {"source_file", "method", "basis"} <= set(gv.columns)
    aapl_w = gv[(gv.ticker == "AAPL") & (gv.cls == "Weekend")].iloc[0]
    assert bool(aapl_w.binds_tier90) and bool(aapl_w.binds_tier93)
    assert not gv[gv.ticker == "SPY"][["binds_tier90", "binds_tier93"]].any().any()
