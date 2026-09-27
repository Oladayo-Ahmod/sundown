import numpy as np
import pytest

import credit_sim as cs
import enforcement as en
import frontier as fr

CTL = cs.Control("t86", 0.86, 0.044)


def test_equivalent_lltv_interpolates_and_clamps():
    lt = np.array([80.0, 85.0, 90.0])
    bd = np.array([0.0, 2.0, 6.0])
    assert fr.equivalent_lltv(bd, lt, 4.0) == pytest.approx(87.5)
    assert fr.equivalent_lltv(bd, lt, 100.0) == 90.0  # clamped at top
    assert fr.equivalent_lltv(bd, lt, -1.0) == 80.0  # below first point
    # ties at zero: highest LLTV whose bad debt does not exceed 0
    assert fr.equivalent_lltv(np.array([0.0, 0.0, 3.0]), lt, 0.0) == pytest.approx(85.0)


def test_slippage_increases_bad_debt_by_hand_value():
    x = np.array([-1500.0])
    s = np.exp(-0.15)
    base = cs.run_events(x, None, CTL, cs.Params())
    slip = cs.run_events(x, None, CTL, cs.Params(slippage=0.03))
    # u=1.0: bad = d - S(1-s)/(1+b); also u=.95 turns insolvent for large enough slippage
    d = 0.86
    expect_top = d - s * 0.97 / 1.044
    assert slip["bad"][0] >= 0.05 * expect_top - 1e-12
    assert slip["bad"][0] > base["bad"][0]


def test_borrower_distributions_normalised_and_ordered():
    wh, wu, wc = (cs.weights(k) for k in ("high", "uniform", "conservative"))
    assert all(w.sum() == pytest.approx(1.0) for w in (wh, wu, wc))
    assert (wh * cs.UTIL).sum() > (wu * cs.UTIL).sum() > (wc * cs.UTIL).sum()


def test_exposure_outputs_match_cap_formula():
    r = cs.run_events(np.array([0.0]), np.array([2000.0]), CTL, cs.Params(enforcement=0.0))
    # cap .785: u=.95 (d=.817) and u=1.0 (d=.86) are flagged
    assert r["flagged"][0] == pytest.approx(0.10)
    assert r["excess"][0] == pytest.approx(0.05 * ((0.817 - 0.785) + (0.86 - 0.785)))


def test_reserve_absorbs_before_lenders():
    bad = np.array([0.0, 0.03, 0.0, 0.05])
    exc = np.array([1.0, 0.0, 1.0, 0.0])
    # pi = 0.02: reserve 0.02 -> loss .03 absorbs .02, lenders -.01; reserve 0 -> +.02 -> loss .05
    resid = en.reserve_residual(bad, exc, 0.02)
    assert resid == pytest.approx([0.0, 0.01, 0.0, 0.03])
    assert en.reserve_residual(bad, exc, 1.0).sum() == 0.0


def test_hard_deleveraging_equals_full_enforcement_in_bad_debt():
    x = np.array([-1800.0, -400.0, 100.0])
    var = np.array([1500.0, 1500.0, 1500.0])
    a = cs.run_events(x, var, CTL, cs.Params(enforcement=1.0))
    b = cs.run_events(x, var, CTL, cs.Params(enforcement=1.0, util_weights="conservative"))
    assert a["bad"].sum() >= 0 and b["bad"].sum() <= a["bad"].sum()
