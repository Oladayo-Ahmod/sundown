import numpy as np
import pandas as pd
import pytest

import backtest as bt
import estimators as est

WAD = est.WAD


def test_ewma_no_lookahead():
    rng = np.random.default_rng(0)
    x = rng.normal(0, 100, 200)
    a = est.ewma_sigma2(x**2, 0.94)
    y = x.copy()
    y[120:] = 9999.0
    b = est.ewma_sigma2(y**2, 0.94)
    assert np.allclose(a[:121], b[:121], equal_nan=True)  # forecast at t=120 uses only x[:120]
    assert np.isnan(a[: est.K_MIN]).all() and np.isfinite(a[est.K_MIN])


def test_hs_no_lookahead_and_order_statistic():
    loss = np.arange(1.0, 201.0)  # 1..200
    f = est.hs_quantile(loss, 126, 0.99)
    # at t=150, past = loss[24:150] (126 values 25..150), k = ceil(0.99*126) = 125 -> 149
    assert f[150] == 149.0
    loss2 = loss.copy()
    loss2[150:] = 1e9
    assert est.hs_quantile(loss2, 126, 0.99)[150] == 149.0


def test_hs_returns_sample_max_when_tail_unresolvable():
    loss = np.arange(1.0, 101.0)
    f = est.hs_quantile(loss, 500, 0.999)
    assert f[99] == 99.0  # max of the 99 priors


def test_integer_ewma_matches_float():
    rng = np.random.default_rng(3)
    x = np.round(rng.standard_t(4, 300) * 120)
    lam, q, m = 0.94, 0.99, 1.37
    sig2 = est.ewma_sigma2(x**2, lam)
    num = den = 0
    lam_wad = int(lam * WAD)
    z_wad = int(round(est.z(q) * WAD))
    m_wad = int(round(m * WAD))
    for t in range(len(x)):
        if t >= est.K_MIN:
            v_int = est.ewma_var_int(num, den, z_wad, m_wad) / WAD
            v_flt = m * est.z(q) * np.sqrt(sig2[t])
            assert v_int >= v_flt * (1 - 1e-9)  # rounds against user (never below float)
            assert abs(v_int - v_flt) / v_flt < 1e-6
        num, den = est.ewma_update_int(num, den, int(x[t]), lam_wad)


def test_integer_hs_matches_float():
    rng = np.random.default_rng(5)
    loss = np.round(rng.normal(0, 150, 400))
    for q in (0.95, 0.99, 0.995):
        f = est.hs_quantile(loss, 250, q)
        for t in (50, 200, 399):
            past = [int(v) for v in loss[max(0, t - 250):t]]
            assert est.hs_quantile_int(past, round(q * 1e4)) == f[t]


def test_calibrated_multiplier_hits_target_in_sample():
    rng = np.random.default_rng(9)
    n = 400
    df = pd.DataFrame({"ticker": "T", "cls": "Weekend", "loss": rng.normal(0, 100, n) * 1.0,
                       "d2": pd.date_range("2010-01-01", periods=n, freq="7D")})
    raw = est.raw_forecast(df.cls.to_numpy(), df.loss.to_numpy(), est.Candidate("ewma", lam=0.97),
                           0.95)
    mask = np.ones(n, bool)
    m = bt.calibrate_multiplier(df, raw, 0.95, mask)
    var = bt.apply_multiplier(df, raw, m)
    ok = np.isfinite(var)
    assert (df.loss.to_numpy()[ok] > var[ok]).mean() <= 0.05 + 1e-9


def test_kupiec_known_value():
    # hand-computed: ll0 = 245 ln .99 + 5 ln .01, ll1 = 245 ln .98 + 5 ln .02 -> LR = 1.9568
    lr, p = bt.kupiec(250, 5, 0.01)
    assert lr == pytest.approx(1.9568, abs=1e-3)
    assert p == pytest.approx(0.1619, abs=1e-3)
    assert bt.kupiec(250, 0, 0.01)[0] > 0 and bt.kupiec(100, 1, 0.01)[1] == pytest.approx(1.0)


def test_christoffersen_detects_clustering():
    rng = np.random.default_rng(1)
    iid = rng.random(2000) < 0.05
    clustered = np.zeros(2000, bool)
    for s in range(0, 2000, 100):
        clustered[s:s + 5] = True  # 5-long bursts, same 5% rate
    assert bt.christoffersen_independence([iid])[1] > 0.01
    assert bt.christoffersen_independence([clustered])[1] < 1e-6
    assert np.isnan(bt.christoffersen_independence([np.zeros(50, bool)])[1])


def test_class_scales_weekend_is_one():
    rng = np.random.default_rng(2)
    rows = []
    for cls, sd in (("Short", 80), ("Weekend", 100), ("Long", 130)):
        for _ in range(100):
            rows.append(("T", cls, rng.normal(0, sd)))
    df = pd.DataFrame(rows, columns=["ticker", "cls", "loss"])
    k = bt.class_scales(df)
    assert k["Weekend"] == pytest.approx(1.0)
    assert 0.6 < k["Short"] < 1.0 < k["Long"] < 1.6
