# research/

Offline analysis only. Nothing here is deployed or imported by `contracts/src`. Findings in [REPORT.md](REPORT.md), defensible claims and non-claims in [CLAIMS.md](CLAIMS.md); data provenance in [DATA_PROVENANCE.md](DATA_PROVENANCE.md).

- Python 3.11, dependencies pinned in `requirements.txt` (compiled from `requirements.in` with `uv pip compile`).
- `data/raw/` is git-ignored: raw vendor data is never committed. `data/derived/` holds returns only.

## Reproduce

```bash
cd research
make venv        # uv venv + pinned install (once)
make test        # 46 unit tests (+1 skipped until contracts/test/fixtures/calendar_cases.json exists)
make backtest    # offline, deterministic (fixed seeds): results/, figures, risk_params.json, replay_events.json
# network steps, only when refreshing data:
make m21         # M2.1: per-asset, mechanisms, slippage grid, clustered frontier (offline)
make m22         # M2.2: liquidation designs under depth-driven slippage, market caps, two-tier (needs pool snapshot)
make data        # re-download daily history, rewrite data/derived
make intraday    # re-download ~730 days of hourly bars, rewrite results/intraday_*
make pools       # snapshot Robinhood Chain pool depth (DexScreener + RPC via cast)
```

## Modules

| Module | Role |
|---|---|
| `calendar_windows.py` | D1 blind windows and Short/Weekend/Long classes from `exchange_calendars` XNYS |
| `data.py` | download (git-ignored raw), derive committed gap series, quality report |
| `gap_stats.py` | per-class moments/quantiles, variance ratios (month-cluster bootstrap), censoring, dividend sensitivity |
| `intraday_study.py` | proxy-superset quantification, oracle staleness (N1) and censoring (N2) simulation on hourly bars |
| `estimators.py` | EWMA / rolling HS / blend / pooled-scaled EWMA, float reference **and integer (WAD) reference** for M4 differential tests |
| `backtest.py` | selection protocol, multiplier calibration, Kupiec / Christoffersen, ES, regimes |
| `credit_sim.py` | borrower-grid credit simulation: flat-LLTV controls vs stress rule |
| `run_backtest.py`, `outputs.py`, `figures.py` | orchestration, `deployments/risk_params.json`, `sim/replay_events.json`, `docs/figures/m2_*.png` |

## Labels

All numbers use the **daily proxy** (previous regular close -> next regular open), a conservative superset of the true blind exposure. Nothing in `results/` is an on-chain measurement.
