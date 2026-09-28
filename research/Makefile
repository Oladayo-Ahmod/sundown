PY ?= .venv/bin/python

.PHONY: venv test lint data intraday backtest m21 pools exit-liquidity all

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

# M2.1: per-asset results, mechanisms, slippage grid, clustered frontier (offline; needs backtest)
m21: backtest
	$(PY) m21_analysis.py
	$(PY) figures_m21.py

# Network step: Robinhood Chain pool depth snapshot (DexScreener + public RPC, needs cast).
pools:
	PATH="$$HOME/.foundry/bin:$$PATH" $(PY) pool_depth.py

# Network step: exact on-chain Uniswap v3 exit-liquidity depth (RPC only, needs cast); M3 step 3a.
exit-liquidity:
	PATH="$$HOME/.foundry/bin:$$PATH" $(PY) exit_liquidity.py

all: venv test backtest m21
