PY ?= .venv/bin/python

.PHONY: venv test lint data intraday backtest m21 m22 m23 pools exit-liquidity all

venv:
	uv venv --python 3.11 .venv
	uv pip install --python $(PY) -r requirements.txt

test:
	$(PY) -m pytest -q

lint:
	$(PY) -m ruff check .

# Network step: re-download daily history (git-ignored) and rewrite committed derived series.
data:
	$(PY) data.py

# Network step: hourly pre/post-market bars (last ~730 days) -> results/intraday_*.{csv,json}.
intraday:
	$(PY) intraday_study.py --refresh

# Offline, deterministic (fixed seeds, pinned deps): reads committed derived series only.
backtest:
	$(PY) run_backtest.py
	$(PY) figures.py

# M2.2: liquidation designs under depth-driven slippage, market caps, two-tier (offline; needs m21)
m22: m21
	$(PY) m22_analysis.py
	$(PY) m22_ci.py
	$(PY) figures_m22.py

# M2.1: per-asset results, mechanisms, slippage grid, clustered frontier (offline; needs backtest)
m21: backtest
	$(PY) m21_analysis.py
	$(PY) figures_m21.py

# M2.3: evidence for the shipped static stress rule (offline; needs exit_liquidity.json, morpho snapshot)
m23:
	$(PY) static_gapvar.py
	$(PY) static_rule_analysis.py

# Network step: Robinhood Chain pool depth snapshot (DexScreener + public RPC, needs cast).
pools:
	PATH="$$HOME/.foundry/bin:$$PATH" $(PY) pool_depth.py

# Network step: exact on-chain Uniswap v3 exit-liquidity depth (RPC only, needs cast); M3 step 3a.
exit-liquidity:
	PATH="$$HOME/.foundry/bin:$$PATH" $(PY) exit_liquidity.py

all: venv test backtest m21
