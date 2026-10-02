/**
 * Read-only on-chain reads for /markets and /preflight. Every call is `eth_call` / `eth_getCode` through the public
 * client in `chain.ts`; nothing here signs or sends a transaction. The tokens and price feeds behind these markets
 * are simulation fixtures (see the `Sim*` entries of the deployment record).
 */
import { formatUnits, type Address } from "viem";

import {
  sundownMarketAbi,
  sundownMarketFactoryAbi,
  sundownGuardAbi,
  flatGuardAbi,
  chainlinkEquityOracleAbi,
  windowCacheAbi,
  simEquityFeedAbi,
  simStockAbi,
  simUsdgAbi,
} from "@/abi";
import {
  HALT_REASON,
  MARKETS,
  MARKET_STATE,
  PRICE_STATUS,
  SYMBOLS,
  WINDOW_CLASS,
  addr,
  deployment,
  readClient,
  type ContractName,
  type MarketRef,
  type Symbol,
} from "@/lib/chain";

const WAD = 10n ** 18n;
const wadPct = (v: bigint, digits = 2) => Number(formatUnits(v * 100n, 18)).toFixed(digits);
const oracleOf = (s: Symbol) => addr(`ChainlinkEquityOracle_${s}` as ContractName);
const feedOf = (s: Symbol) => addr(`SimEquityFeed_${s}` as ContractName);

export interface WindowView {
  blind: boolean;
  startUtc: number;
  endUtc: number;
  cls: string;
}

export interface OracleView {
  symbol: Symbol;
  feedDescription: string;
  feedAnswerUsd: string;
  feedUpdatedAt: number;
  adapterPriceUsd: string;
  adapterStatus: string;
  adapterUpdatedAt: number;
  haircutPct: string;
}

export interface MarketView {
  ref: MarketRef;
  guardName: string;
  lltvPct: string;
  closeFactorPct: string;
  maxBonusPct: string;
  collateralCap: string;
  minDebt: string;
  state: string;
  haltReason: string;
  totalSupplyAssets: string;
  totalBorrowAssets: string;
  utilizationPct: string;
  totalCollateral: string;
  badDebtRealized: string;
  /** Present for the boosted market only. */
  guard?: {
    standardLltvPct: string;
    boostedLltvPct: string;
    stressFractionWeekendPct: string;
    stressFractionLongPct: string;
    preWindowHorizonH: string;
    cureWindowH: string;
    boostedEntryDisabled: boolean;
    borrowsBlocked: boolean;
  };
}

export interface MarketsSnapshot {
  blockNumber: string;
  blockTimestamp: number;
  window: WindowView;
  oracles: OracleView[];
  markets: MarketView[];
}

const guardName = (g: string): string => {
  const hit = Object.entries(deployment.contracts).find(([n, a]) => a.toLowerCase() === g.toLowerCase() && /Guard/.test(n));
  return hit ? hit[0] : g;
};

const usd = (priceWad: bigint) => Number(formatUnits(priceWad, 18)).toFixed(2);

async function readWindow(): Promise<WindowView> {
  const w = await readClient().readContract({ address: addr("WindowCache"), abi: windowCacheAbi, functionName: "peek" });
  return { blind: w.blind, startUtc: Number(w.start), endUtc: Number(w.end), cls: WINDOW_CLASS[w.cls] ?? String(w.cls) };
}

async function readOracle(symbol: Symbol): Promise<OracleView> {
  const c = readClient();
  const [peek, round, description] = await Promise.all([
    c.readContract({ address: oracleOf(symbol), abi: chainlinkEquityOracleAbi, functionName: "peek" }),
    c.readContract({ address: feedOf(symbol), abi: simEquityFeedAbi, functionName: "latestRoundData" }),
    c.readContract({ address: feedOf(symbol), abi: simEquityFeedAbi, functionName: "description" }),
  ]);
  return {
    symbol,
    feedDescription: description,
    feedAnswerUsd: Number(formatUnits(round[1], 8)).toFixed(2),
    feedUpdatedAt: Number(round[3]),
    adapterPriceUsd: usd(peek.priceWad),
    adapterStatus: PRICE_STATUS[peek.status] ?? String(peek.status),
    adapterUpdatedAt: Number(peek.updatedAt),
    haircutPct: wadPct(peek.haircutWad),
  };
}

async function readMarket(ref: MarketRef): Promise<MarketView> {
  const c = readClient();
  const m = { address: ref.address, abi: sundownMarketAbi } as const;
  const [cfg, state, halt, totalAssets, totalBorrow, totalColl, badDebt] = await Promise.all([
    c.readContract({ ...m, functionName: "config" }),
    c.readContract({ ...m, functionName: "state" }),
    c.readContract({ ...m, functionName: "haltReason" }),
    c.readContract({ ...m, functionName: "totalAssets" }),
    c.readContract({ ...m, functionName: "totalBorrowAssets" }),
    c.readContract({ ...m, functionName: "totalCollateral" }),
    c.readContract({ ...m, functionName: "badDebtRealized" }),
  ]);
  const loanD = cfg.loanDecimals;
  const colD = cfg.collateralDecimals;
  const fmtLoan = (v: bigint) => Number(formatUnits(v, loanD)).toLocaleString("en-US", { maximumFractionDigits: 2 });
  const fmtCol = (v: bigint) => Number(formatUnits(v, colD)).toLocaleString("en-US", { maximumFractionDigits: 4 });
  const util = totalAssets === 0n ? "0.00" : ((Number(totalBorrow) / Number(totalAssets)) * 100).toFixed(2);

  const view: MarketView = {
    ref,
    guardName: guardName(cfg.guard),
    lltvPct: wadPct(BigInt(cfg.lltvWad)),
    closeFactorPct: wadPct(BigInt(cfg.closeFactorWad), 0),
    maxBonusPct: wadPct(BigInt(cfg.maxBonusWad)),
    collateralCap: `${fmtCol(BigInt(cfg.collateralCap))} s${ref.symbol}`,
    minDebt: `${fmtLoan(BigInt(cfg.minDebt))} sUSDG`,
    state: MARKET_STATE[state] ?? String(state),
    haltReason: HALT_REASON[halt] ?? String(halt),
    totalSupplyAssets: `${fmtLoan(totalAssets)} sUSDG`,
    totalBorrowAssets: `${fmtLoan(totalBorrow)} sUSDG`,
    utilizationPct: util,
    totalCollateral: `${fmtCol(totalColl)} s${ref.symbol}`,
    badDebtRealized: `${fmtLoan(badDebt)} sUSDG`,
  };

  if (ref.tier === "boosted_93") {
    const g = { address: cfg.guard as Address, abi: sundownGuardAbi } as const;
    const [p, sfW, sfL, entryOff, blocked] = await Promise.all([
      c.readContract({ ...g, functionName: "currentParams" }),
      c.readContract({ ...g, functionName: "stressFraction", args: [1] }),
      c.readContract({ ...g, functionName: "stressFraction", args: [2] }),
      c.readContract({ ...g, functionName: "boostedEntryDisabled" }),
      c.readContract({ ...g, functionName: "borrowsBlocked" }),
    ]);
    view.guard = {
      standardLltvPct: wadPct(BigInt(p.standardLltv)),
      boostedLltvPct: wadPct(BigInt(p.boostedLltv)),
      stressFractionWeekendPct: wadPct(sfW),
      stressFractionLongPct: wadPct(sfL),
      preWindowHorizonH: (Number(p.preWindowHorizon) / 3600).toString(),
      cureWindowH: (Number(p.cureWindow) / 3600).toString(),
      boostedEntryDisabled: entryOff,
      borrowsBlocked: blocked,
    };
  }
  return view;
}

export async function readMarketsSnapshot(): Promise<MarketsSnapshot> {
  const c = readClient();
  const [block, window, oracles, markets] = await Promise.all([
    c.getBlock(),
    readWindow(),
    Promise.all(SYMBOLS.map(readOracle)),
    Promise.all(MARKETS.map(readMarket)),
  ]);
  return { blockNumber: block.number.toString(), blockTimestamp: Number(block.timestamp), window, oracles, markets };
}

// ------------------------------------------------------------------------------------------------ preflight

export interface Check {
  id: string;
  label: string;
  ok: boolean;
  detail: string;
}

export interface PreflightSnapshot {
  blockNumber: string;
  blockTimestamp: number;
  checks: Check[];
}

/** EIP-1167 runtime code of a minimal proxy to `impl`. */
const cloneCode = (impl: string) => `0x363d3d373d3d3d363d73${impl.slice(2)}5af43d82803e903d91602b57fd5bf3`.toLowerCase();
const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** The on-chain half of scripts/preflight.sh (D35), as read-only browser checks. */
export async function readPreflight(): Promise<PreflightSnapshot> {
  const c = readClient();
  const names = Object.keys(deployment.contracts) as ContractName[];
  const impl = addr("SundownMarketImplementation");
  const checks: Check[] = [];

  const [block, codes] = await Promise.all([c.getBlock(), Promise.all(names.map((n) => c.getCode({ address: addr(n) })))]);

  const missing = names.filter((_, i) => !codes[i] || codes[i] === "0x");
  checks.push({
    id: "code",
    label: "Code present at every recorded address",
    ok: missing.length === 0,
    detail: missing.length ? `no code at: ${missing.join(", ")}` : `${names.length} of ${names.length} addresses have code`,
  });

  const markets = MARKETS.map((m) => m.name);
  const badClone = markets.filter((n) => (codes[names.indexOf(n)] ?? "").toLowerCase() !== cloneCode(impl));
  checks.push({
    id: "clones",
    label: "Every market is a minimal proxy of the recorded SundownMarketImplementation",
    ok: badClone.length === 0,
    detail: badClone.length ? `not a clone of ${impl}: ${badClone.join(", ")}` : `${markets.length} markets clone ${impl}`,
  });

  const fac = { address: addr("SundownMarketFactory"), abi: sundownMarketFactoryAbi } as const;
  const count = await c.readContract({ ...fac, functionName: "marketCount" });
  const onchain = await Promise.all(
    Array.from({ length: Number(count) }, (_, i) => c.readContract({ ...fac, functionName: "marketAt", args: [BigInt(i)] })),
  );
  const recorded = markets.map((n) => addr(n).toLowerCase()).sort();
  const sameSet = onchain.length === recorded.length && onchain.map((a) => a.toLowerCase()).sort().join() === recorded.join();
  checks.push({
    id: "factory",
    label: "Factory market list equals the deployment record",
    ok: sameSet,
    detail: `factory reports ${count} markets; record lists ${recorded.length}`,
  });

  const cfgs = await Promise.all(
    MARKETS.map((m) => c.readContract({ address: m.address, abi: sundownMarketAbi, functionName: "config" })),
  );
  const guards = Object.entries(deployment.contracts).filter(([n]) => /Guard/.test(n)).map(([, a]) => a);
  const guardOk = cfgs.every((cfg, i) => {
    const sym = MARKETS[i]?.symbol;
    return sym !== undefined && guards.some((g) => eq(g, cfg.guard)) && eq(cfg.oracle, oracleOf(sym));
  });
  checks.push({
    id: "wiring",
    label: "Each market uses a recorded guard and its own symbol's oracle adapter",
    ok: guardOk,
    detail: guardOk ? "guard and oracle addresses in every market config match the record" : "mismatch between market config and record",
  });

  const roleOk = cfgs.every((cfg) => eq(cfg.guardian, deployment.guardian) && eq(cfg.governance, deployment.deployer));
  checks.push({
    id: "roles",
    label: "Guardian and governance match the record (guardian is a separate key from the deployer)",
    ok: roleOk && !eq(deployment.guardian, deployment.deployer),
    detail: `guardian ${deployment.guardian}, governance ${deployment.deployer}`,
  });

  const boosted = MARKETS.find((m) => m.tier === "boosted_93")!;
  const sg = { address: addr("SundownGuard_AAPL93"), abi: sundownGuardAbi } as const;
  const [gMarket, gOracle] = await Promise.all([
    c.readContract({ ...sg, functionName: "market" }),
    c.readContract({ ...sg, functionName: "ORACLE" }),
  ]);
  checks.push({
    id: "guard-binding",
    label: "SundownGuard_AAPL93 is bound to the boosted AAPL market and the AAPL adapter",
    ok: eq(gMarket, boosted.address) && eq(gOracle, oracleOf("AAPL")),
    detail: `market ${gMarket}, oracle ${gOracle}`,
  });

  const flat = await Promise.all([
    c.readContract({ address: addr("FlatGuard_86"), abi: flatGuardAbi, functionName: "LTV_WAD" }),
    c.readContract({ address: addr("FlatGuard_93"), abi: flatGuardAbi, functionName: "LTV_WAD" }),
  ]);
  checks.push({
    id: "flat-guards",
    label: "Flat guards are 86% and 93%",
    ok: flat[0] === (86n * WAD) / 100n && flat[1] === (93n * WAD) / 100n,
    detail: `FlatGuard_86 ${wadPct(flat[0], 0)}%, FlatGuard_93 ${wadPct(flat[1], 0)}%`,
  });

  const flags = await Promise.all([
    c.readContract({ address: addr("SimUSDG"), abi: simUsdgAbi, functionName: "IS_SIMULATION" }),
    ...SYMBOLS.map((s) => c.readContract({ address: addr(`SimStock_${s}` as ContractName), abi: simStockAbi, functionName: "IS_SIMULATION" })),
    ...SYMBOLS.map((s) => c.readContract({ address: feedOf(s), abi: simEquityFeedAbi, functionName: "IS_SIMULATION" })),
  ]);
  checks.push({
    id: "fixtures",
    label: "Tokens and price feeds self-declare as simulation (IS_SIMULATION)",
    ok: flags.every(Boolean),
    detail: `${flags.filter(Boolean).length} of ${flags.length} fixture contracts return IS_SIMULATION = true`,
  });

  const win = await readWindow();
  checks.push({
    id: "window",
    label: "Calendar window cache answers",
    ok: win.endUtc > win.startUtc,
    detail: `${win.blind ? "inside" : "outside"} a ${win.cls} blind window; window ${new Date(win.startUtc * 1000).toISOString().slice(0, 16)}Z to ${new Date(win.endUtc * 1000).toISOString().slice(0, 16)}Z`,
  });

  const orcs = await Promise.all(SYMBOLS.map(readOracle));
  const bad = orcs.filter((o) => o.adapterStatus === "Invalid" || o.adapterStatus === "SequencerDown");
  checks.push({
    id: "oracles",
    label: "Oracle adapters return a usable status on the simulated feeds",
    ok: bad.length === 0,
    detail: orcs.map((o) => `${o.symbol} ${o.adapterStatus}`).join(", "),
  });

  return { blockNumber: block.number.toString(), blockTimestamp: Number(block.timestamp), checks };
}
