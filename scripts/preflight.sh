#!/usr/bin/env bash
# Pre-submission checks (D35). Prints PASS / FAIL / SKIP per check and exits non-zero if any check FAILS.
#
#   scripts/preflight.sh [--quick]     --quick skips the slow checks (full tests, slither, replay)
#
# Environment (optional): ARBITRUM_SEPOLIA_RPC_URL (default: public endpoint), ETHERSCAN_API_KEY (Etherscan v2,
# enables the verification check), ROBINHOOD_MAINNET_RPC_URL (enables the fork tests inside `forge test`).
# Reads a repo-root .env if present (never printed).
set -u
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
RPC="${ARBITRUM_SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
DEPLOY="$ROOT/deployments/421614.json"
fails=0; results=()

record() { results+=("$1|$2|$3"); printf '%-6s %s  %s\n' "$2" "$1" "$3"; [ "$2" = "FAIL" ] && fails=$((fails + 1)); }
check() { # name, command...
  local name="$1"; shift
  local out; out=$("$@" 2>&1); local rc=$?
  if [ $rc -eq 0 ]; then record "$name" PASS "$(echo "$out" | tail -1 | cut -c1-110)"
  else record "$name" FAIL "$(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-200)"; fi
}

echo "== Sundown preflight ($(date -u +%FT%TZ))"

check "forge fmt" bash -c 'cd contracts && forge fmt --check'
check "forge build" bash -c 'cd contracts && forge build 2>&1 | tail -1'

if [ $QUICK -eq 0 ]; then
  fork="skipped (ROBINHOOD_MAINNET_RPC_URL not set)"; [ -n "${ROBINHOOD_MAINNET_RPC_URL:-}" ] && fork="fork tests ENABLED"
  check "forge test ($fork)" bash -c 'cd contracts && forge test 2>&1 | grep -E "^\[FAIL|Ran [0-9]+ test suites" | tail -3; ! forge test 2>&1 | grep -q "^\[FAIL"'
  check "gas snapshot" bash -c "cd contracts && forge snapshot --check --no-match-test 'testFuzz|invariant|test_replay' 2>&1 | tail -1"
  if command -v slither >/dev/null 2>&1; then
    check "slither (no high/medium)" bash -c 'cd contracts && out=$(slither . --config-file slither.config.json 2>&1); echo "$out" | tail -1; ! echo "$out" | grep -E "Impact: (High|Medium)" '
  else record "slither" SKIP "not installed"; fi
else
  record "forge test / snapshot / slither" SKIP "--quick"
fi

# --- deployed contracts: code present and verified at every address in deployments/421614.json
if [ -f "$DEPLOY" ]; then
  check "deployed code + Arbiscan verification" python3 scripts/check_deployed.py "$DEPLOY" "$RPC" "${ETHERSCAN_API_KEY:-}"
else
  record "deployed code + Arbiscan verification" SKIP "deployments/421614.json not present (nothing deployed yet)"
fi

# --- calendar fixture: regenerate from the independent oracle and compare byte for byte
tmp=$(mktemp -d)
if [ -d research ] && command -v uv >/dev/null 2>&1; then
  check "calendar fixture reproducible" bash -c "cd research && uv run python calendar_oracle.py --out '$tmp/calendar_cases.json' >/dev/null 2>&1 && cmp '$tmp/calendar_cases.json' ../contracts/test/fixtures/calendar_cases.json && echo identical; rm -f uv.lock"
else record "calendar fixture reproducible" SKIP "uv not installed"; fi

# --- replay reproducibility: inputs, on-chain run vs the exact-integer reference
if [ $QUICK -eq 0 ]; then
  check "replay inputs reproducible" bash -c "cp sim/replay_inputs.json '$tmp/in.json' && python3 sim/prepare_replay.py >/dev/null && cmp sim/replay_inputs.json '$tmp/in.json' && echo identical"
  check "replay: on-chain vs reference" bash -c "(cd contracts && forge test --match-test test_replayPrintsResults -vv > '$tmp/sol.log' 2>&1) && (cd research && python3 replay_reference.py > '$tmp/ref.csv') && python3 sim/compare_replay.py '$tmp/sol.log' '$tmp/ref.csv' | tail -4"
else record "replay checks" SKIP "--quick"; fi
rm -rf "$tmp"

# --- secrets
check "secret scan (full history)" bash -c "scripts/secret_scan.sh | tail -1"

echo
echo "== summary: $((${#results[@]} - fails)) not failing, $fails FAILED"
[ $fails -eq 0 ] && echo "PREFLIGHT: OK" || echo "PREFLIGHT: FAILED"
exit $fails
