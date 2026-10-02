import { MagneticLink, Reveal, StaggerText, W } from "@/components/motion";
import { N, Sources, SimBadge } from "@/components/provenance";
import { SkyHero } from "@/components/sky/sky-hero";
import { Stat } from "@/components/stat";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { borrowerRow, gaps, headline, lender, MARKET_RULE, must, staticRule } from "@/lib/data";
import { ci, fmt, pct } from "@/lib/format";
import { cn } from "@/lib/utils";

function q99Weekend(ticker: string): number | null {
  const row = gaps.stats.find((s) => s.ticker === ticker && s.cls === "Weekend");
  return row ? (row["loss_q99_bps"] ?? null) : null;
}

function SectionHead({ n, eyebrow, children, extra }: { n: string; eyebrow: string; children: React.ReactNode; extra?: React.ReactNode }) {
  return (
    <header className="space-y-3">
      <p className="t-eyebrow flex items-center gap-3">
        <span className="num text-amber">{n}</span>
        <span className="h-px w-10 bg-border" aria-hidden="true" />
        {eyebrow}
      </p>
      <div className="flex flex-wrap items-end gap-x-4 gap-y-2">{children}{extra}</div>
    </header>
  );
}

export default function Home() {
  const h = headline;
  const m = h.measured_borrow_apr_pct;
  const t = staticRule.crosscheck.totals;
  const src = {
    credit: "research/results/credit_summary.csv",
    flat: "research/results/credit_frontier_datecluster.csv",
    conc: "research/results/bad_debt_regime_concentration.csv",
    rates: "research/results/morpho_rates_snapshot.json",
    bt: "research/results/backtest_test_chosen.csv",
    stats: "research/results/class_stats.csv",
    lend: "research/results/static_rule_lender.csv",
    borrower: "research/results/static_rule_borrower.csv",
    cross: "research/results/static_replay_crosscheck_totals.csv",
    replayDoc: "docs/REPLAY_RESULTS.md",
    sens: "research/results/static_rule_sensitivity.csv",
  };
  const a93 = lender(MARKET_RULE, "AAPL", 93, "uniform", "A flat");
  const n93 = lender(MARKET_RULE, "AAPL", 93, "uniform", "B boosted + rule, naive");
  const r93 = lender(MARKET_RULE, "AAPL", 93, "uniform", "B boosted + rule, rational");
  const dN = lender(MARKET_RULE, "AAPL", 93, "uniform", "DIFF A minus B(naive)");
  const dR = lender(MARKET_RULE, "AAPL", 93, "uniform", "DIFF A minus B(rational)");
  const rVsC = lender(MARKET_RULE, "AAPL", 93, "uniform", "DIFF B(rational) minus C");
  const spy93 = lender(MARKET_RULE, "SPY", 93, "uniform", "A flat");
  const bNaive = borrowerRow(93, "uniform", "naive");
  const bNaiveHigh = borrowerRow(93, "clustered near max", "naive");
  const oos = must(
    staticRule.hindsight.find((r) => r.tier === 93 && r.case.includes("pre-2018")),
    "hindsight oos 93",
  );
  const eq93 = must(
    staticRule.equal_risk.find((r) => r.tier === 93),
    "equal risk 93",
  );

  return (
    <div className="space-y-24 sm:space-y-32">
      {/* ------------------------------------------------------------ hero */}
      <section aria-labelledby="hero" className="space-y-10 pt-6 sm:pt-10">
        <div className="grid gap-8 lg:grid-cols-12 lg:items-end">
          <div className="space-y-6 lg:col-span-8">
            <div className="flex flex-wrap gap-2">
              <Badge variant="outline">Research phase</Badge>
              <SimBadge>Simulation results</SimBadge>
            </div>
            <h1
              id="hero"
              className="font-display text-[clamp(2.3rem,1.1rem+4.2vw,4.5rem)] leading-[0.96] text-balance"
            >
              <StaggerText>
                <W>Tokenized</W> <W>stocks</W> <W>trade</W> <W>almost</W> <W>around</W> <W>the</W> <W>clock.</W>{" "}
                <W>Lending</W> <W>markets</W> <W>still</W> <W>price</W> <W>their</W> <W>weekend</W> <W>risk</W>{" "}
                <W em>once.</W>
              </StaggerText>
            </h1>
          </div>
          <div className="space-y-5 lg:col-span-4 lg:pb-3">
            <p className="text-base leading-relaxed text-muted-foreground">
              Sundown is a research project on a session-aware credit-risk layer for tokenized-stock collateral on
              Arbitrum and Robinhood Chain. This site shows what the evidence supports, with confidence intervals, and
              what it does not.
            </p>
            <div className="flex flex-wrap gap-3">
              <MagneticLink href="/risk" className={cn(buttonVariants())}>
                See the risk evidence
              </MagneticLink>
              <MagneticLink href="/replay" className={cn(buttonVariants({ variant: "outline" }))}>
                Replay real gaps
              </MagneticLink>
            </div>
          </div>
        </div>
        <SkyHero />
      </section>

      {/* ------------------------------------------------------------ 01 problem */}
      <section aria-labelledby="problem" className="space-y-8">
        <SectionHead n="01" eyebrow="The blind window">
          <h2 id="problem" className="t-section max-w-2xl">
            The problem: an oracle that goes <em>quiet</em>
          </h2>
        </SectionHead>
        <ul className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <Reveal as="li">
            <Card className="h-full">
              <CardHeader>
                <CardTitle>The oracle goes quiet</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Chainlink&apos;s 24/5 equity feeds publish from Sunday 20:00 ET to Friday 20:00 ET and hold the
                last value across weekends and NYSE holidays. On Robinhood Chain the first update after each of the two holidays we
                checked arrived within 85 seconds after 20:00 ET on the evening before the next trading day.
                <Sources files={["docs/DISCOVERY.md"]} note="documented and verified-onchain labels" />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={90}>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>Static limits price it once</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Stock-collateral markets on Robinhood Chain&apos;s Morpho use fixed LLTVs of 38.5%, 62.5%, 77% and
                86%. A fixed number cannot tighten before a closure or react to a volatile name.
                <Sources files={["docs/DISCOVERY.md"]} note="Morpho API read, section f" />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={180}>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>The gaps are real</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                Over 2010 to 2026 the 99th-percentile weekend gap down (previous close to next open) was{" "}
                <N src={src.stats}>{fmt(q99Weekend("SPY"), 0)}</N> bps for SPY,{" "}
                <N src={src.stats}>{fmt(q99Weekend("AAPL"), 0)}</N> for AAPL and{" "}
                <N src={src.stats}>{fmt(q99Weekend("TSLA"), 0)}</N> for TSLA. A daily proxy overstates the
                blind exposure; it is never presented as exact.
                <Sources files={[src.stats]} />
              </CardContent>
            </Card>
          </Reveal>
        </ul>
      </section>

      {/* ------------------------------------------------------------ 02 what we built */}
      <section aria-labelledby="built" className="space-y-8">
        <SectionHead n="02" eyebrow="What we built">
          <h2 id="built" className="t-section max-w-2xl">
            A calendar-aware oracle, a small lending core, and a guard you can <em>swap</em>
          </h2>
        </SectionHead>
        <ul className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <Reveal as="li">
            <Card className="h-full">
              <CardHeader>
                <CardTitle>Calendar-aware oracle</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                <code>ChainlinkEquityOracle</code> tells scheduled blindness from unexpected staleness, using the on-chain
                D1 blind-window calendar (<code>UsMarketCalendar</code>, <code>MarketCalendar</code>) behind a{" "}
                <code>WindowCache</code>.
                <Sources files={["docs/DESIGN.md", "docs/CALENDAR_NOTES.md"]} />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={90}>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>Isolated lending market</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                <code>SundownMarket</code>: an ERC-4626 supply vault plus isolated single-collateral lending, kinked
                per-second rate, partial liquidation with a non-worsening bonus cap, per-market collateral cap and an
                issuer-failure halt policy. The market contains no session logic: it reads a swappable guard.
                <Sources files={["docs/MARKET_DESIGN.md"]} />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={180}>
            <Card className="h-full">
              <CardHeader>
                <CardTitle>Two guards, one difference</CardTitle>
              </CardHeader>
              <CardContent className="text-sm leading-relaxed">
                <code>FlatGuard</code> is the control (static LTV, flat bonus). <code>SundownGuard</code> adds a static
                stress cap from 6 h before a blind window until the window has ended and a fresh price has arrived, a 3 h
                cure window and permissionless deleveraging; standard accounts are never touched. Deployed boosted tier:{" "}
                <strong>AAPL at 93% only</strong>.
                <Sources files={["docs/GUARD_DESIGN.md"]} />
              </CardContent>
            </Card>
          </Reveal>
        </ul>
      </section>

      {/* ------------------------------------------------------------ 03 evidence */}
      <section aria-labelledby="claims" className="space-y-8">
        <SectionHead n="03" eyebrow="Evidence" extra={<SimBadge>Research simulation</SimBadge>}>
          <h2 id="claims" className="t-section max-w-2xl">
            Three claims we can <em>defend</em>
          </h2>
        </SectionHead>
        <p className="max-w-3xl text-muted-foreground">
          What ships is a <strong>static</strong> through-the-cycle stress rule for one boosted tier, AAPL at 93%:
          session-aware LLTV, boosted weekday capacity, tighter weekend capacity. It is a capacity policy, not loss
          prevention. Bad debt is annualised, in basis points of outstanding debt, from replaying real gaps against
          simulated markets; intervals are 95% bootstrap CIs clustered by window date.
        </p>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Reveal>
            <Stat
              label="Flat 86% LLTV, bad debt"
              value={h.flat.bps_yr_86.est}
              digits={1}
              unit="bps/yr"
              note={`95% CI ${ci(h.flat.bps_yr_86.lo, h.flat.bps_yr_86.hi)}`}
              source={src.credit}
            />
          </Reveal>
          <Reveal delay={70}>
            <Stat
              label="Forge replay: unprotected 93% control"
              value={t.forge_control}
              prefix="$"
              note="Lender loss over 4 events (forge in-process EVM, not a public chain)"
              source={src.cross}
              tone="ember"
            />
          </Reveal>
          <Reveal delay={140}>
            <Stat
              label="Same replay: session-aware market"
              value={t.forge_session_aware}
              prefix="$"
              note="Lender loss over 1 event; the 2020-03-16 gap still produced a loss"
              source={src.cross}
              tone="steel"
            />
          </Reveal>
          <Reveal delay={210}>
            <Stat
              label="Measured AAPL borrow APR"
              value={m.AAPL}
              digits={2}
              suffix="%"
              note={`${pct(100 * m.aapl_util, 2)} utilised, block ${m.block}`}
              source={src.rates}
            />
          </Reveal>
        </div>

        <ol className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <Reveal as="li">
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 1
                </Badge>
                <CardTitle>Today&apos;s LLTVs lose almost nothing to weekend gaps</CardTitle>
                <CardDescription>So we do not claim to fix them.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  At 86% LLTV (the highest in the wild) bad debt is{" "}
                  <N src={src.credit}>{fmt(h.flat.bps_yr_86.est, 1)}</N> bps/yr, CI{" "}
                  <N src={src.flat}>{ci(h.flat.bps_yr_86.lo, h.flat.bps_yr_86.hi)}</N>. At 77% it is{" "}
                  <N src={src.credit}>{fmt(h.flat.bps_yr_77, 2)}</N> bps/yr.
                </p>
                <p>
                  Worst single window: <N src={src.credit}>{pct(h.flat.worst_window_pct_86)}</N> of debt.{" "}
                  <N src={src.conc}>{pct(h.flat.mar2020_share_pct_86, 0)}</N> of the 86% loss is one episode, March
                  2020. These levels use the deployed market&apos;s liquidation rule; the older full-bonus convention gave about 4.5 bps/yr (an upper bound).
                </p>
                <Sources files={[src.credit, src.flat, src.conc]} />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={90}>
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 2
                </Badge>
                <CardTitle>The shipped rule works as designed on AAPL at 93%, and two implementations agree</CardTitle>
                <CardDescription>Forge in-process EVM replay, not a public chain.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  Replay of the 10 worst real AAPL gaps on 20 seeded borrowers (no cures): the unprotected 93% control
                  lost <N src={src.cross}>${fmt(t.forge_control, 0)}</N> over <N src={src.replayDoc}>4</N> events; the
                  session-aware market <N src={src.cross}>${fmt(t.forge_session_aware, 0)}</N> over{" "}
                  <N src={src.replayDoc}>1</N>; a standard 86% market{" "}
                  <N src={src.cross}>${fmt(t.forge_standard_86, 0)}</N> at 7.5% lower capacity. The 2020-03-16 gap
                  (13.9%) <strong>still produced a loss</strong>.
                </p>
                <p>
                  A separate Python implementation reproduces this to 0.01% (
                  <N src={src.cross}>${fmt(t.python_nonworsening_control, 2)}</N> and{" "}
                  <N src={src.cross}>${fmt(t.python_nonworsening_session_aware, 2)}</N>) once it uses the market&apos;s
                  liquidation rule (it shares the authors&apos; reading of the market&apos;s rules, so the agreement is not fully independent); the earlier liquidation convention overstated the control by 45% (
                  <N src={src.cross}>${fmt(t.python_control, 0)}</N>), so both are reported.
                </p>
                <p>
                  Over 914 AAPL windows 2010 to 2026 (in-sample for the cap) the rule cuts 93% bad debt from{" "}
                  <N src={src.lend}>{fmt(a93.bps, 1)}</N> to <N src={src.lend}>{fmt(n93.bps, 1)}</N> to{" "}
                  <N src={src.lend}>{fmt(r93.bps, 1)}</N> bps/yr: a reduction of{" "}
                  <N src={src.lend}>{fmt(dN.bps, 1)}</N> (CI <N src={src.lend}>{ci(dN.lo, dN.hi)}</N>) for borrowers
                  who never adjust and <N src={src.lend}>{fmt(dR.bps, 1)}</N> (CI{" "}
                  <N src={src.lend}>{ci(dR.lo, dR.hi)}</N>) for borrowers who trim before each window.
                </p>
                <Sources files={[src.cross, src.replayDoc, src.lend]} />
              </CardContent>
            </Card>
          </Reveal>
          <Reveal as="li" delay={180}>
            <Card className="h-full">
              <CardHeader>
                <Badge variant="outline" className="w-fit">
                  Claim 3
                </Badge>
                <CardTitle>Its economics are modest, and we say so</CardTitle>
                <CardDescription>SPY is inert; AAPL buys little at a real cost.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-2 text-sm leading-relaxed">
                <p>
                  <strong>SPY:</strong> the cap never binds, so a &ldquo;boosted&rdquo; SPY tier is a flat market (93%:{" "}
                  <N src={src.lend}>{fmt(spy93.bps, 1)}</N> bps/yr, unprotected). <strong>AAPL:</strong> the rule is
                  not distinguishable from a flat market at the 89.35% weekend-cap level (rule minus flat-at-cap{" "}
                  <N src={src.lend}>+{fmt(rVsC.bps, 1)}</N> bps/yr, CI <N src={src.lend}>{ci(rVsC.lo, rVsC.hi)}</N>)
                  and offers <N src={src.borrower}>{fmt(eq93.extra_weekday_pp, 2)}</N> pp more weekday capacity.
                </p>
                <p>
                  A never-adjusting borrower sitting at the maximum is deleveraged about{" "}
                  <N src={src.borrower}>{fmt(bNaive.flagged_per_yr_top_bucket, 0)}</N> times a year. Averaged over a
                  uniform population of never-adjusting borrowers the 2% fee costs{" "}
                  <N src={src.borrower}>{fmt(bNaive.fee_pct_debt_yr, 1)}</N>% of debt a year; for a population clustered
                  near the limit, <N src={src.borrower}>{fmt(bNaiveHigh.fee_pct_debt_yr, 1)}</N>%,
                  against a measured AAPL borrow APR of <N src={src.rates}>{fmt(m.AAPL, 2)}</N>% (
                  <N src={src.rates}>{pct(100 * m.aapl_util, 2)}</N> utilised, block{" "}
                  <N src={src.rates}>{m.block}</N>).
                </p>
                <p>
                  Out of sample the rule does nothing: with a cap calibrated before March 2020, 93% bad debt is{" "}
                  <N src={src.sens}>{fmt(oos.flat, 1)}</N> bps/yr flat and <N src={src.sens}>{fmt(oos.rational, 1)}</N>{" "}
                  with the rule.
                </p>
                <Sources files={[src.lend, src.borrower, src.rates, src.sens]} />
              </CardContent>
            </Card>
          </Reveal>
        </ol>
        <p className="max-w-3xl text-sm text-muted-foreground">
          Context: the AAPL and NVDA stock-collateral markets are <N src={src.rates}>{pct(100 * m.aapl_util, 2)}</N> and{" "}
          <N src={src.rates}>{pct(100 * m.nvda_util, 1)}</N> utilised at <N src={src.rates}>{fmt(m.AAPL, 2)}</N>% and{" "}
          <N src={src.rates}>{fmt(m.NVDA, 2)}</N>% borrow APR; the SPY market is idle (
          <N src={src.rates}>{pct(100 * m.spy_util, 0)}</N> utilised, <N src={src.rates}>{fmt(m.SPY, 2)}</N>% APR).
          Results for the earlier time-varying research estimator, which is not shipped, are on the risk page and are
          labelled as such.
        </p>
      </section>

      {/* ------------------------------------------------------------ 04 limits and non-claims */}
      <section aria-labelledby="not" className="space-y-8">
        <SectionHead n="04" eyebrow="Limits">
          <h2 id="not" className="t-section max-w-2xl">
            Claims we will <em>not</em> make
          </h2>
        </SectionHead>
        <Reveal>
          <Card>
            <CardContent className="pt-6">
              <ul className="list-disc space-y-3 pl-5 text-sm leading-relaxed marker:text-amber">
                <li>
                  That Sundown is safer than Aave or Morpho, or that it protects conventional LLTV markets or prevents
                  losses: the 2020-03-16 gap still produced a loss and the benefit disappears out of sample.
                </li>
                <li>
                  Any enforcement, protection or benefit for SPY at either tier or for AAPL at 90%; anything for TSLA or
                  NVDA beyond &ldquo;not recommended for a boosted tier&rdquo;.
                </li>
                <li>
                  That the shipped rule is safer than a flat market at the weekend-cap level, or that the earlier
                  time-varying estimator&apos;s results (+2.4 pp LTV, 45% bad-debt reduction) describe it.
                </li>
                <li>
                  That our 99% gap-VaR is calibrated: out of sample it realises{" "}
                  <N src={src.bt}>{fmt(h.var99_weekend.rate_pct, 2)}</N>% on weekends (target 1%, CI{" "}
                  <N src={src.bt}>{ci(h.var99_weekend.ci[0], h.var99_weekend.ci[1], 2)}</N>); March 2020 breaks it.
                </li>
                <li>
                  That naive borrowers are good customers, that attentive borrowers have no cost, that a keeper will run,
                  or that the boosted tier is profitable for lenders or borrowers.
                </li>
                <li>
                  That the replay ran on a public chain (it did not), that exit liquidity is guaranteed, or that any
                  on-chain integration, issuer-risk mitigation or oracle security is validated by this work.
                </li>
              </ul>
              <Sources files={[src.bt, "research/PITCH_EVIDENCE.md", "research/CLAIMS.md"]} />
            </CardContent>
          </Card>
        </Reveal>
      </section>
    </div>
  );
}
