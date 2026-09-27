PY ?= .venv/bin/python

.PHONY: venv test lint data intraday backtest all

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

all: venv test backtest
