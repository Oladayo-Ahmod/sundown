"""Central configuration for the M2 research pipeline (offline analysis, not production)."""

import os
from pathlib import Path

RESEARCH = Path(__file__).resolve().parent
REPO = RESEARCH.parent
RAW_DIR = RESEARCH / "data" / "raw"  # git-ignored vendor data
DERIVED_DIR = RESEARCH / "data" / "derived"  # committed: returns only, no vendor prices
RESULTS_DIR = RESEARCH / "results"
FIGURES_DIR = REPO / "docs" / "figures"
RISK_PARAMS_PATH = REPO / "deployments" / "risk_params.json"
REPLAY_EVENTS_PATH = REPO / "sim" / "replay_events.json"
CALENDAR_FIXTURE = REPO / "contracts" / "test" / "fixtures" / "calendar_cases.json"

# Research universe (D5). Deployed subset must be inside the 32 feed-backed tokens (N4).
# AAPL/NVDA/TSLA/SPY/QQQ/MSFT/AMZN/GOOGL/META have feed proxies listed in DISCOVERY.md;
# JPM/XOM/WMT are research-only and their feed membership is UNVERIFIED.
UNIVERSE = ["AAPL", "NVDA", "TSLA", "SPY", "QQQ", "MSFT",
            "AMZN", "GOOGL", "META", "JPM", "XOM", "WMT"]
DEPLOY_SUBSET = ["TSLA", "NVDA", "AAPL", "SPY"]
HISTORY_START = "2010-01-01"

# D1 blind-window rule. UNVERIFIED: early-close days do not move window boundaries
# (extended sessions still run to 20:00 ET). One-line switch mirrored from the contract
# config; the research proxy is unaffected either way, only the d1_early_close flag is used.
EARLY_CLOSE_SHIFTS_WINDOW = False
WINDOW_OPEN_HOUR_ET = 20

# Window classes by closed calendar days n (D1). "Overnight" (n = 0) is a reference
# class only: it is not a blind window.
BLIND_CLASSES = ["Short", "Weekend", "Long"]
ALL_CLASSES = ["Overnight", *BLIND_CLASSES]

# Train / validation / test split (calibrate on train, evaluate strictly out of sample).
CAL_END = "2014-12-31"  # m calibrated on [start, CAL_END] during model selection
TRAIN_END = "2017-12-31"  # validation = (CAL_END, TRAIN_END]; final refit on [start, TRAIN_END]
TEST_START = "2018-01-01"

QUANTILES = [0.95, 0.99, 0.995, 0.999]
SEED = 20261002

# Oracle (N1): Chainlink push feeds, 0.5 % deviation, 24 h heartbeat.
ORACLE_DEVIATION_BPS = 50
ORACLE_HEARTBEAT_S = 86_400

# Stress-rule buffers (bps of collateral value).
SAFETY_BUFFER_BPS = 100
LOOKAHEAD_HOURS = 24  # H: tightening starts this long before a window (design 3.4)

# N5 controls. Morpho on Robinhood LLTVs observed via the Morpho API (DISCOVERY.md f).
# Morpho Blue liquidation incentive factor: min(1.15, 1 / (0.3 * LLTV + 0.7))
# (documented Morpho Blue formula, not re-verified in this session).
MORPHO_LLTVS = [0.385, 0.625, 0.77, 0.86]
AAVE_LLTVS = [0.65, 0.79]  # secondary-source (LlamaRisk via press), see DISCOVERY.md f
AAVE_MAX_BONUS = 0.055
COUNTERFACTUAL_LLTVS = [0.90, 0.93, 0.95]  # not observed in the wild; labelled counterfactual


def morpho_bonus(lltv: float) -> float:
    return min(1.15, 1.0 / (0.3 * lltv + 0.7)) - 1.0


# Liquidation convention. "market" (default) is the deployed rule (SundownMarket._planLiquidation):
# the bonus is capped at collateral/debt - 1 while collateral exceeds debt, so a liquidation never
# worsens an account. "older" is the M2.2 convention that charges the full bonus on any liquidated
# account: an UPPER BOUND on lender loss, kept behind SUNDOWN_LIQ_CONVENTION=older (it overwrites
# results/; archived pre-M2.4 copies are in results/older_convention/).
LIQ_CONVENTION = os.environ.get("SUNDOWN_LIQ_CONVENTION", "market")
NONWORSENING_DEFAULT = LIQ_CONVENTION != "older"
OLDER_DIR = RESULTS_DIR / "older_convention"
