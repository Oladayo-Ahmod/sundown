"use client";

import { useEffect, useRef } from "react";

import { prefersReducedMotion } from "@/components/motion";

export interface TimelineNumbers {
  event: string;
  gapPct: number;
  controlLoss: string;
  sessionLoss: string;
  standardLoss: string;
  tierLltvPct: number;
  capPct: number;
  deleverageToPct: number;
  weekdayCap: string;
  controlWindowCap: string;
  sessionWindowCap: string;
  standardWindowCap: string;
}

const W = 1080;
const H = 380;
const X = { open: 90, cure: 270, start: 400, end: 780 };
const yOf = (pct: number) => 70 + (93 - pct) * 36; // 93% at y=70, 86% at y=322

/**
 * Control (flat 93%) versus the session-aware market through ONE blind window: the 2020-03-16 AAPL event of the
 * forge replay. Every level and loss is a number from docs/REPLAY_RESULTS.md; the time axis is not to scale.
 * An anime.js timeline draws the two paths in sequence when the figure scrolls into view; reduced motion shows the
 * finished drawing. The same facts are listed as text below the figure.
 */
export function WindowTimeline({ n }: { n: TimelineNumbers }) {
  const root = useRef<SVGSVGElement>(null);

  useEffect(() => {
    const svg = root.current;
    if (!svg || prefersReducedMotion()) return;
    const q = <T extends Element>(sel: string) => Array.from(svg.querySelectorAll<T>(sel));
    const paths = q<SVGPathElement>("[data-draw]");
    const fades = q<SVGElement>("[data-fade]");
    paths.forEach((p) => {
      p.style.strokeDasharray = "1";
      p.style.strokeDashoffset = "1";
    });
    fades.forEach((f) => (f.style.opacity = "0"));
    let started = false;
    let cancelled = false;
    const reveal = () => {
      paths.forEach((p) => {
        p.style.removeProperty("stroke-dasharray");
        p.style.removeProperty("stroke-dashoffset");
      });
      fades.forEach((f) => f.style.removeProperty("opacity"));
    };
    const play = () => {
      if (started) return;
      started = true;
      import("animejs").then(({ createTimeline }) => {
        if (cancelled) return;
        const tl = createTimeline({ defaults: { ease: "inOutQuad" }, onComplete: reveal });
        const byName = (name: string) => paths.filter((p) => p.dataset.draw === name);
        const fade = (name: string) => fades.filter((f) => f.dataset.fade === name);
        tl.add(fade("axis"), { opacity: [0, 1], duration: 400 }, 0);
        tl.add(byName("control"), { strokeDashoffset: [1, 0], duration: 1100 }, 300);
        tl.add(byName("session"), { strokeDashoffset: [1, 0], duration: 1300 }, 1100);
        tl.add(fade("cap"), { opacity: [0, 1], duration: 400 }, 1500);
        tl.add(byName("gap"), { strokeDashoffset: [1, 0], duration: 600, ease: "inQuad" }, 2500);
        tl.add(fade("loss"), { opacity: [0, 1], duration: 500 }, 3000);
      });
    };
    const io = new IntersectionObserver(
      (es) => {
        if (es.some((e) => e.isIntersecting)) {
          io.disconnect();
          play();
        }
      },
      { threshold: 0.35 },
    );
    io.observe(svg);
    const safety = window.setTimeout(() => {
      io.disconnect();
      if (!started) reveal();
    }, 9000);
    return () => {
      cancelled = true;
      io.disconnect();
      window.clearTimeout(safety);
      reveal();
    };
  }, []);

  const yT = yOf(n.tierLltvPct);
  const yC = yOf(n.capPct);
  const yD = yOf(n.deleverageToPct);
  const yS = yOf(86);
  const gapY = yD + 78;

  return (
    <figure className="space-y-3">
      <div className="overflow-x-auto" role="region" tabIndex={0} aria-label="Timeline chart; scrolls sideways on narrow screens">
      <svg
        ref={root}
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label={`Control versus session-aware market through one blind window, ${n.event}`}
        className="h-auto w-full min-w-[720px]"
        data-testid="window-timeline"
      >
        <g data-fade="axis">
          {[X.open, X.cure, X.start, X.end].map((x) => (
            <line key={x} x1={x} x2={x} y1="40" y2="338" stroke="var(--chart-grid)" strokeDasharray="3 5" />
          ))}
          <g className="chart-text" textAnchor="middle">
            <text x={X.open} y="30">Fri 14:00</text>
            <text x={X.cure} y="30">Fri 17:00</text>
            <text x={X.start} y="30">Fri 20:00</text>
            <text x={X.end} y="30">Sun 20:00 reopen</text>
            <text x={X.open} y="358" fill="currentColor" opacity="0.8">horizon opens</text>
            <text x={X.cure} y="358">cure window ends</text>
            <text x={X.start} y="358">window starts</text>
            <text x={X.end} y="358">gap at reopen</text>
          </g>
          <g className="chart-text">
            <text x="8" y={yT + 4}>{n.tierLltvPct}%</text>
            <text x="8" y={yC + 4}>{n.capPct}%</text>
            <text x="8" y={yS + 4}>86%</text>
          </g>
          <line x1="52" x2={X.end + 40} y1={yS} y2={yS} stroke="var(--chart-3)" strokeDasharray="6 6" opacity="0.8" />
        </g>

        {/* control: flat at the tier LLTV the whole time */}
        <path data-draw="control" pathLength="1" d={`M ${X.open - 40} ${yT} H ${X.end}`} fill="none" stroke="var(--chart-4)" strokeWidth="3" strokeLinecap="round" />
        {/* session-aware: the cap applies at the horizon, deleveraging brings accounts to the cap minus a margin */}
        <path
          data-draw="session"
          pathLength="1"
          d={`M ${X.open - 40} ${yT} H ${X.open} V ${yC} H ${X.cure} V ${yD} H ${X.end}`}
          fill="none"
          stroke="var(--chart-1)"
          strokeWidth="3"
          strokeLinejoin="round"
        />
        <g data-fade="cap" className="chart-text">
          <text x={X.open + 8} y={yC - 8} fill="var(--chart-1)">stress cap {n.capPct}%</text>
          <text x={X.cure + 8} y={yD + 20} fill="var(--chart-1)">deleveraged to {n.deleverageToPct}%</text>
          <text x={X.end - 8} y={yT - 10} textAnchor="end" fill="var(--chart-4)">flat control {n.tierLltvPct}%</text>
          <text x={X.open + 10} y={yS - 8} fill="var(--chart-3)">standard 86%: loss {n.standardLoss}</text>
        </g>

        {/* the gap hits both at reopen */}
        <path data-draw="gap" pathLength="1" d={`M ${X.end} ${yT} V ${gapY + 22}`} fill="none" stroke="var(--chart-4)" strokeWidth="3" strokeDasharray="1" />
        <path data-draw="gap" pathLength="1" d={`M ${X.end + 26} ${yD} V ${gapY}`} fill="none" stroke="var(--chart-1)" strokeWidth="3" />
        <g data-fade="loss" className="chart-text">
          <text x={X.end - 10} y={gapY + 42} fill="var(--chart-4)" textAnchor="end">control loss {n.controlLoss}</text>
          <text x={X.end + 40} y={gapY + 18} fill="var(--chart-1)">session-aware loss {n.sessionLoss}</text>
          <text x={X.end + 40} y={(yD + gapY) / 2} >{n.gapPct}% gap</text>
        </g>
      </svg>
      </div>
      <figcaption className="text-xs leading-relaxed text-muted-foreground">
        <strong>Schematic of one real event, not to scale in time.</strong> {n.event}: the forge replay (docs/REPLAY_RESULTS.md,
        forge in-process EVM, not a public chain) applies a {n.gapPct}% gap once at reopen to 20 seeded borrowers with no cures.
        Weekday capacity is {n.weekdayCap} for control and session-aware alike; in-window capacity is {n.controlWindowCap} for
        control, {n.sessionWindowCap} session-aware and {n.standardWindowCap} for the standard 86% market.
      </figcaption>
      <ol className="sr-only">
        <li>Friday 14:00 ET, horizon opens: the session-aware market applies its {n.capPct}% stress cap.</li>
        <li>Friday 17:00 ET, cure window ends: accounts still above the cap are deleveraged to {n.deleverageToPct}%.</li>
        <li>Friday 20:00 ET, the blind window starts.</li>
        <li>
          Sunday 20:00 ET, reopen: a {n.gapPct}% gap. Lender loss: control {n.controlLoss}, session-aware {n.sessionLoss},
          standard 86% {n.standardLoss}.
        </li>
      </ol>
    </figure>
  );
}
