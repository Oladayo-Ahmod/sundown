#!/usr/bin/env bash
# Lists every unresolved placeholder token (double-brace PENDING colon NAME double-brace) in the repo
# and exits non-zero while any exist. Run before submitting: it must print "no pending tokens".
set -u
cd "$(dirname "$0")/.." || exit 2

# Pattern built in pieces so this script never matches itself; braces are escaped for ERE.
PATTERN='\{\{PEND''ING:[A-Za-z0-9_]+\}\}'

hits=$(grep -rInE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.next \
  --exclude-dir=lib --exclude-dir=.venv --exclude-dir=out --exclude-dir=cache \
  --exclude=check_pending.sh --exclude=pnpm-lock.yaml \
  "$PATTERN" . 2>/dev/null)

if [ -z "$hits" ]; then
  echo "no pending tokens"
  exit 0
fi

tokens=$(echo "$hits" | grep -oE "$PATTERN" | sort | uniq -c | sort -rn)
echo "Pending tokens (occurrences, name):"
echo "$tokens" | awk '{printf "  %4s  %s\n", $1, $2}'
echo
echo "Locations (file:line):"
echo "$hits" | cut -d: -f1,2 | sort -u | sed 's/^/  /'
echo
echo "$(echo "$tokens" | wc -l | tr -d ' ') distinct pending token(s) remain"
exit 1
