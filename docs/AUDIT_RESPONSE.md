# Response to the claims audit

Written for: reviewers comparing `docs/CLAIMS_AUDIT.md` (pinned to `f80b047`) with the current branch. Each of the 27 correction rows is listed with the action taken. "Applied" means the audit's wording (or the owner's explicit wording where it replaces it) is now in the file; nothing was dropped silently and no row is disputed. Before editing, `main` was merged into `m2-research`; the ruff fixes arrived with that merge (research lint now passes).

| Row | Action | Where / notes |
|---|---|---|
| A1 | Applied | `README.md`, `docs/SUBMISSION.md`: "231 passed, 0 failed, 4 skipped (235 total; the 4 skipped are fork tests that need `ROBINHOOD_MAINNET_RPC_URL`)" |
| A2 | Applied | `web/src/data/forge_tests.json` regenerated (19 suites, 231 / 0 / 4 / 235) with the audit's note; rendered on `/preflight` |
| A3 | Applied | `docs/SUBMISSION.md` short description: no updates from Friday 20:00 ET to Sunday 20:00 ET and across NYSE holidays |
| A4 | Applied | `README.md`, `docs/SUBMISSION.md`, `research/PITCH_EVIDENCE.md`, `docs/DEMO_SCRIPT.md` and the home page now give separate figures: about 52 events a year for a never-adjusting borrower at the maximum; fee 4.3% of debt a year averaged over a uniform population, 11.8% for a population clustered near the limit (the web page prints the values from the data file) |
| A5 | Applied | Home page: first update after each holiday arrived within 85 seconds after 20:00 ET |
| A6 | Applied | `/replay` on-chain card and `/deployment` limits card credit the 90% refusal to the 86% standard-tier cap of the AAPL boosted-tier market (boosted entry is closed in a window) and say the stress cap, cure window and deleveraging are not exercised |
| A7 | Applied | "A separate Python implementation ... shares the authors' reading of the market's rules, so the agreement is not fully independent" in README, SUBMISSION, PITCH_EVIDENCE, DEMO_SCRIPT, home and risk pages (the replay page already said it) |
| A8 | Applied | `/preflight` fork-test row: passed once 2026-10-03 19:16 UTC (4 of 4, real feeds); a later full-suite run failed on a dropped connection; only the blind branch was exercised; no on-chain asset-identity check |
| A9 | Applied | The oracle status token was filled with the audit's wording in `README.md` and `docs/SUBMISSION.md` (validated once; not a reliability claim; limits stated). It does not say "integrated" |
| A10 | Applied | `/deployment`: on Sepolia the adapter reads simulated feeds; the same adapter was validated once against the real Robinhood Chain feeds (`docs/ORACLE_LIVE_VALIDATION.md`) |
| A11 | Applied | README, SUBMISSION and `/preflight`: 21 non-clone contracts verified on Arbiscan, 6 markets are EIP-1167 clones of the verified implementation (`scripts/check_deployed.py`, 2026-10-03). I did not re-run the explorer check myself; the statement is the audit's, backed by its cited run |
| A12 | Applied | `/preflight`: "All checks passed". Verified after the merge: `ruff check research/` passes |
| A13 | Applied | `/preflight` and `research/CLAIMS.md` (the row-1 status): the skipped test is a placeholder for a Python-side comparison; the comparison runs in the on-chain differential tests (8 tests). The second location the audit cites (`CLAIMS.md:89`) no longer contains the phrase |
| A14 | Applied | `/deployment` and `docs/DEMO_SCRIPT.md`: "Not demonstrable before the submission deadline (Sun 2026-10-04 08:59 WAT)", with the window end and next window start |
| A15 | Applied | `research/PITCH_EVIDENCE.md`, `docs/SUBMISSION.md`: +2.4 pp and 45% (deployed rule); +2.6 pp and 41% appear only labelled as the older convention |
| A16 | Applied | `/replay`: TSLA alone, NVDA none under the deployed rule, not distinguishable from zero |
| A17 | Applied | `docs/SUBMISSION.md` "What is next": extend live oracle validation to the Fresh, Stale and Reopening branches; the early-close item kept |
| A18 | Applied | `docs/DEMO_SCRIPT.md`: six web pages named, scenes use the first three |
| A19 | Applied | "27 deployed addresses (21 contracts and 6 market clones)" in README, SUBMISSION and `/deployment` |
| A20 | Applied | "simulated tokens (SimUSDG, SimStock) and simulated price feeds" in README, SUBMISSION (rows for chains, simulation, real-vs-simulated, demonstration, limitations) |
| A21 | Applied | Internal labels removed from README, SUBMISSION, DEMO_SCRIPT, PITCH_EVIDENCE and the web pages; documents are named instead. Remaining mentions are in `research/CLAIMS.md` (a research log with handoff sections addressed to the contracts track), which is not judge-facing copy; they are reported rather than rewritten |
| A22 | Applied | README and `/risk`: the stress period runs until the window has ended and a fresh price has arrived; deleveraging targets the cap minus a 0.5% margin |
| A23 | Applied | README halt policy: new supply, borrows and collateral withdrawals blocked; repay open; lender redemptions limited to idle liquidity; accrual frozen for the first 30 days |
| A24 | Applied | Calendar differential testing qualified as 2024-2035 (library accepts 2020-2040; 2020-2023 not differentially validated) in README and SUBMISSION |
| A25 | Applied | `docs/SUBMISSION.md`: 27 tests per `playwright test --list`, last passing 2026-10-03 (re-run for this response, see the handoff report) |
| A26 | Applied, as instructed by the owner | The tooling-disclosure placeholder and its sections were removed from README and SUBMISSION and not replaced with any statement about how the code was written; a plain "Tech stack" section lists only the software used |
| A27 | Applied | Owner's statement entered: started from scratch during the buildathon (first commit 2026-10-02); third-party code limited to the libraries in the README attribution |

Also changed under the owner's token instructions: repository URL and team entered; `scripts/check_pending.sh` now ignores `docs/CLAIMS_AUDIT.md` (it quotes a retired placeholder name inside code formatting and is not a document to submit).

Still pending, owner-only: the live-site URL, demo video URL, deployed Lighthouse measurement, and the submission track.
