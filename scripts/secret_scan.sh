#!/usr/bin/env bash
# Full-history secret scan. Uses gitleaks when installed, otherwise `git log -p` with grep.
# Exit 1 if anything that looks like a secret is found. 64-hex strings are reported for review but do not fail the
# scan by themselves (transaction hashes, pool ids and file hashes are public identifiers).
set -u
cd "$(git rev-parse --show-toplevel)"
fail=0

if command -v gitleaks >/dev/null 2>&1; then
  echo "scanner: gitleaks"
  gitleaks detect --no-banner --redact --log-opts="--all" || fail=1
else
  echo "scanner: git log -p + grep (gitleaks not installed)"
  hist=$(mktemp); trap 'rm -f "$hist"' EXIT
  git log --all -p --no-color --format='COMMIT %h' > "$hist"
  echo "commits scanned: $(git rev-list --all | wc -l)"

  n=$(grep -c -E -- '-----BEGIN [A-Z ]*PRIVATE KEY' "$hist"); echo "private-key blocks: $n"; [ "$n" -ne 0 ] && fail=1
  n=$(grep -c -E 'AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}' "$hist")
  echo "known token formats: $n"; [ "$n" -ne 0 ] && fail=1
  n=$(grep -c -i -E '(api[_-]?key|secret|passw(or)?d|private[_-]?key|auth[_-]?token|access[_-]?token|etherscan)[A-Za-z_]*\s*[:=]\s*["'"'"']?[A-Za-z0-9_-]{16,}' "$hist")
  echo "key/secret/password assignments: $n"; [ "$n" -ne 0 ] && fail=1
  n=$(grep -o -i -E 'https?://[^ "'"'"')<>]*(alchemy|infura|quicknode|quiknode|ankr|chainstack|drpc|blastapi|getblock|moralis|tenderly|helius)[^ "'"'"')<>]*' "$hist" | sort -u | wc -l)
  echo "RPC-provider URLs: $n"; [ "$n" -ne 0 ] && fail=1
  n=$(grep -o -i -E 'https?://[^ "'"'"')<>]*[?&](api_?key|key|token|apikey|access_token)=[^ "'"'"')<>&]+' "$hist" | sort -u | wc -l)
  echo "URLs carrying a key parameter: $n"; [ "$n" -ne 0 ] && fail=1
  echo "distinct 64-hex strings (informational): $(grep -o -E '(0x)?[0-9a-fA-F]{64}\b' "$hist" | sort -u | wc -l)"
fi

echo "tracked sensitive files (besides *.example):"
bad=$(git ls-files | grep -i -E '(^|/)\.env|broadcast/|\.pem$|\.key$|keystore|id_rsa|\.p12$|\.secrets' | grep -v -E '\.example$')
if [ -n "$bad" ]; then echo "$bad"; fail=1; else echo "  none"; fi
echo "ever tracked in history:"
bad=$(git log --all --name-only --format= | sort -u | grep -i -E '(^|/)\.env|broadcast/|\.pem$|\.key$|keystore|id_rsa|\.secrets' | grep -v -E '\.example$')
if [ -n "$bad" ]; then echo "$bad"; fail=1; else echo "  none"; fi
for p in .env broadcast/x contracts/broadcast/421614/run.json keystore/x .secrets/x; do
  git check-ignore -q "$p" && echo "ignored: $p" || { echo "NOT ignored: $p"; fail=1; }
done

if [ "$fail" -eq 0 ]; then echo "SECRET SCAN: PASS"; else echo "SECRET SCAN: FAIL"; fi
exit "$fail"
