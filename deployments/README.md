# deployments/

Per-chain configuration lives here as `<chain>.json` (token, feed and infrastructure addresses, plus deployed Sundown contracts). Contract source in `contracts/src` must never hardcode chain addresses; scripts and tests read them from these files.

Each address entry must record how it was verified (`onchain-read`, `docs`, or `unverified`) so that "integrated" claims stay honest.
