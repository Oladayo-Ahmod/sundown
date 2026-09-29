import type { ReactNode } from "react";

/**
 * Dependency-free SVG charts (server-rendered). Colours come from CSS variables so they follow
 * the theme; every chart has an accessible name and a data-table alternative.
 */

const W = 560;
const H = 320;
const M = { l: 52, r: 14, t: 14, b: 44 };
const IW = W - M.l - M.r;
const IH = H - M.t - M.b;

type Scale = (v: number) => number;
const linear = (d0: number, d1: number, r0: number, r1: number): Scale => (v) =>
  r0 + ((v - d0) / (d1 - d0)) * (r1 - r0);

function ticks(lo: number, hi: number, n: number): number[] {
  const step = (hi - lo) / n;
  return Array.from({ length: n + 1 }, (_, i) => lo + i * step);
}

function nice(v: number): string {
  if (Math.abs(v) >= 1000) return `${(v / 1000).toFixed(1)}k`;
  return Number.isInteger(v) ? String(v) : v.toFixed(1);
}

export function ChartFrame({
  label,
  description,
  legend,
  table,
  children,
}: {
  label: string;
  description: string;
  legend?: ReactNode;
  table?: ReactNode;
  children: ReactNode;
}) {
  return (
    <figure className="m-0">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={label} className="h-auto w-full">
        <title>{label}</title>
        <desc>{description}</desc>
        {children}
      </svg>
      {legend ? <figcaption className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs">{legend}</figcaption> : null}
      {table ? (
        <details className="mt-2 text-sm">
          <summary className="min-h-11 cursor-pointer py-2 font-medium sm:min-h-0">View data table</summary>
          <div className="mt-2">{table}</div>
        </details>
      ) : null}
    </figure>
  );
}

export function LegendItem({ color, children }: { color: string; children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: color }} />
      {children}
    </span>
  );
}

function Axes({
  xTicks,
  yTicks,
  xScale,
  yScale,
  xLabel,
  yLabel,
  yFmt = nice,
  xFmt = nice,
}: {
  xTicks: number[];
  yTicks: number[];
  xScale: Scale;
  yScale: Scale;
  xLabel: string;
  yLabel: string;
  yFmt?: (v: number) => string;
  xFmt?: (v: number) => string;
}) {
  return (
    <g>
      {yTicks.map((t) => (
        <g key={`y${t}`}>
          <line className="chart-grid" x1={M.l} x2={W - M.r} y1={yScale(t)} y2={yScale(t)} />
          <text className="chart-text" x={M.l - 6} y={yScale(t) + 4} textAnchor="end">
            {yFmt(t)}
          </text>
        </g>
      ))}
      {xTicks.map((t) => (
        <text key={`x${t}`} className="chart-text" x={xScale(t)} y={H - M.b + 18} textAnchor="middle">
          {xFmt(t)}
        </text>
      ))}
      <text className="chart-text" x={M.l + IW / 2} y={H - 6} textAnchor="middle">
        {xLabel}
      </text>
      <text
        className="chart-text"
        transform={`translate(13 ${M.t + IH / 2}) rotate(-90)`}
        textAnchor="middle"
      >
        {yLabel}
      </text>
    </g>
  );
}

/* ------------------------------------------------------------------ histogram (step lines) */

export type HistSeries = { name: string; color: string; density: readonly number[] };

export function GapHistogram({
  edges,
  series,
  label,
  description,
}: {
  edges: readonly number[];
  series: readonly HistSeries[];
  label: string;
  description: string;
}) {
  const lo = edges[0] ?? -1000;
  const hi = edges[edges.length - 1] ?? 600;
  const floor = 1e-4;
  const x = linear(lo, hi, M.l, W - M.r);
  const yMin = Math.log10(floor);
  const yMax = Math.log10(0.4);
  const y = linear(yMin, yMax, H - M.b, M.t);
  const yTicks = [-4, -3, -2, -1];
  return (
    <ChartFrame
      label={label}
      description={description}
      legend={series.map((s) => (
        <LegendItem key={s.name} color={s.color}>
          {s.name}
        </LegendItem>
      ))}
    >
      <Axes
        xTicks={[-1000, -500, 0, 500]}
        yTicks={yTicks}
        xScale={x}
        yScale={y}
        xLabel="gap, bps (clipped to -1000..+600)"
        yLabel="share of windows"
        yFmt={(t) => `1e${t}`}
      />
      {series.map((s) => {
        const pts: string[] = [];
        s.density.forEach((d, i) => {
          const a = edges[i];
          const b = edges[i + 1];
          if (a === undefined || b === undefined) return;
          const yy = y(Math.log10(Math.max(d, floor)));
          pts.push(`${x(a)},${yy}`, `${x(b)},${yy}`);
        });
        return (
          <polyline key={s.name} points={pts.join(" ")} fill="none" stroke={s.color} strokeWidth={1.8} />
        );
      })}
    </ChartFrame>
  );
}

/* ------------------------------------------------------------------ VaR time series */

export function VarSeries({
  dates,
  loss,
  varBps,
  label,
  description,
}: {
  dates: readonly string[];
  loss: readonly number[];
  varBps: readonly number[];
  label: string;
  description: string;
}) {
  const t = dates.map((d) => Date.parse(d));
  const t0 = Math.min(...t);
  const t1 = Math.max(...t);
  const yMax = Math.ceil(Math.max(...loss, ...varBps) / 500) * 500;
  const yMin = Math.floor(Math.min(...loss) / 250) * 250;
  const x = linear(t0, t1, M.l, W - M.r);
  const y = linear(yMin, yMax, H - M.b, M.t);
  const years = Array.from(
    { length: new Date(t1).getUTCFullYear() - new Date(t0).getUTCFullYear() + 1 },
    (_, i) => new Date(t0).getUTCFullYear() + i,
  ).filter((yr) => yr % 2 === 0);
  const line = t.map((tt, i) => `${x(tt)},${y(varBps[i] ?? 0)}`).join(" ");
  return (
    <ChartFrame
      label={label}
      description={description}
      legend={
        <>
          <LegendItem color="var(--chart-text)">realised loss</LegendItem>
          <LegendItem color="var(--chart-1)">99% gap-VaR (out of sample)</LegendItem>
          <LegendItem color="var(--chart-4)">exceedance</LegendItem>
        </>
      }
    >
      <Axes
        xTicks={years.map((yr) => Date.UTC(yr, 0, 1))}
        yTicks={ticks(yMin, yMax, 4)}
        xScale={x}
        yScale={y}
        xLabel="window open date"
        yLabel="bps"
        xFmt={(v) => String(new Date(v).getUTCFullYear())}
      />
      {t.map((tt, i) => (
        <circle key={i} cx={x(tt)} cy={y(loss[i] ?? 0)} r={1.8} fill="var(--chart-text)" opacity={0.7} />
      ))}
      <polyline points={line} fill="none" stroke="var(--chart-1)" strokeWidth={1.8} />
      {t.map((tt, i) =>
        (loss[i] ?? 0) > (varBps[i] ?? 0) ? (
          <circle
            key={`e${i}`}
            cx={x(tt)}
            cy={y(loss[i] ?? 0)}
            r={4}
            fill="var(--chart-4)"
            stroke="var(--background)"
            strokeWidth={1}
          />
        ) : null,
      )}
    </ChartFrame>
  );
}

/* ------------------------------------------------------------------ frontier */

export type FrontierPoint = {
  lltv_pct: number;
  flat_bps: number | null;
  treat_bps: number | null;
  treat_ci: readonly (number | null)[];
};

export function FrontierChart({
  curve,
  points,
  label,
  description,
}: {
  curve: { lltv_pct: readonly number[]; bps: readonly (number | null)[]; lo: readonly (number | null)[]; hi: readonly (number | null)[] };
  points: readonly FrontierPoint[];
  label: string;
  description: string;
}) {
  const keep = curve.lltv_pct.map((l, i) => ({ l, i })).filter((o) => o.l >= 80);
  const xMax = Math.ceil(Math.max(...keep.map((o) => curve.hi[o.i] ?? 0), ...points.map((p) => p.treat_ci[1] ?? 0)) / 20) * 20;
  const x = linear(0, xMax, M.l, W - M.r);
  const y = linear(80, 96, H - M.b, M.t);
  const band =
    keep.map((o) => `${x(curve.lo[o.i] ?? 0)},${y(o.l)}`).join(" ") +
    " " +
    [...keep].reverse().map((o) => `${x(curve.hi[o.i] ?? 0)},${y(o.l)}`).join(" ");
  const line = keep.map((o) => `${x(curve.bps[o.i] ?? 0)},${y(o.l)}`).join(" ");
  return (
    <ChartFrame
      label={label}
      description={description}
      legend={
        <>
          <LegendItem color="var(--chart-2)">flat LLTV (95% band)</LegendItem>
          <LegendItem color="var(--chart-1)">Sundown stress rule + deleveraging (95% CI)</LegendItem>
        </>
      }
    >
      <Axes
        xTicks={ticks(0, xMax, 4)}
        yTicks={[80, 84, 88, 92, 96]}
        xScale={x}
        yScale={y}
        xLabel="annualised bad debt, bps of outstanding"
        yLabel="base LLTV, %"
      />
      <polygon points={band} fill="var(--chart-2)" opacity={0.22} />
      <polyline points={line} fill="none" stroke="var(--chart-2)" strokeWidth={2} />
      {points.map((p) => {
        const lo = p.treat_ci[0] ?? 0;
        const hi = p.treat_ci[1] ?? 0;
        return (
          <g key={p.lltv_pct}>
            <line x1={x(lo)} x2={x(hi)} y1={y(p.lltv_pct)} y2={y(p.lltv_pct)} stroke="var(--chart-1)" strokeWidth={1.5} />
            <circle cx={x(p.treat_bps ?? 0)} cy={y(p.lltv_pct)} r={5} fill="var(--chart-1)" stroke="var(--background)" strokeWidth={1.5} />
          </g>
        );
      })}
    </ChartFrame>
  );
}

/* ------------------------------------------------------------------ paired bars */

export function PairedBars({
  items,
  aLabel,
  bLabel,
  yLabel,
  label,
  description,
}: {
  items: readonly { label: string; a: number; b: number }[];
  aLabel: string;
  bLabel: string;
  yLabel: string;
  label: string;
  description: string;
}) {
  const yMax = Math.max(1, ...items.flatMap((i) => [i.a, i.b])) * 1.1;
  const y = linear(0, yMax, H - M.b, M.t);
  const bw = IW / items.length;
  return (
    <ChartFrame
      label={label}
      description={description}
      legend={
        <>
          <LegendItem color="var(--chart-2)">{aLabel}</LegendItem>
          <LegendItem color="var(--chart-1)">{bLabel}</LegendItem>
        </>
      }
    >
      <Axes xTicks={[]} yTicks={ticks(0, yMax, 4)} xScale={() => 0} yScale={y} xLabel="" yLabel={yLabel} />
      {items.map((it, i) => {
        const x0 = M.l + i * bw + bw * 0.15;
        const w = bw * 0.33;
        return (
          <g key={it.label}>
            <rect x={x0} y={y(it.a)} width={w} height={H - M.b - y(it.a)} fill="var(--chart-2)" rx={2} />
            <rect x={x0 + w + 3} y={y(it.b)} width={w} height={H - M.b - y(it.b)} fill="var(--chart-1)" rx={2} />
            <text className="chart-text" x={x0 + w} y={H - M.b + 18} textAnchor="middle">
              {it.label}
            </text>
          </g>
        );
      })}
    </ChartFrame>
  );
}
