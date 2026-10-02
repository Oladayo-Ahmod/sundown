/**
 * Illustrative model of one trading week for the hero scene. Pure functions, shared by the three.js scene and the
 * static SVG fallback so both always agree.
 *
 * Time axis `t` is in hours from the moment the feed resumes (Sunday 20:00 ET):
 *   0 .. 120  the feed is live (24/5, Sunday 20:00 ET to Friday 20:00 ET)
 *   120 .. 168  the weekend blind window (Friday 20:00 ET to Sunday 20:00 ET): the feed holds its last value
 *   168 .. 180  the window has ended: the first update arrives and the price jumps by the gap
 * The price path is synthetic (a seeded random walk with a deliberate gap) and is shown only as an illustration.
 */
export const T_CLOSE = 120;
export const T_RESUME = 168;
export const T_END = 180;
export const T_HORIZON = 6; // stress period of the shipped guard starts 6 h before a window

export type Phase = "live" | "horizon" | "blind" | "resume";

export function phaseAt(t: number): Phase {
  if (t < T_CLOSE - T_HORIZON) return "live";
  if (t < T_CLOSE) return "horizon";
  if (t < T_RESUME) return "blind";
  return "resume";
}

const SUN_KEYS: [number, number][] = [
  [0, 0.02],
  [8, 0.55],
  [40, 0.8],
  [80, 0.8],
  [104, 0.5],
  [120, 0.0],
  [132, -0.4],
  [144, -0.5],
  [156, -0.4],
  [168, 0.0],
  [174, 0.35],
  [180, 0.6],
];

/** Sun altitude in [-1, 1]; 0 is the horizon. It sets exactly when the window starts and rises when it ends. */
export function sunAltitude(t: number): number {
  const x = Math.min(Math.max(t, 0), T_END);
  for (let i = 0; i < SUN_KEYS.length - 1; i++) {
    const [t0, a0] = SUN_KEYS[i]!;
    const [t1, a1] = SUN_KEYS[i + 1]!;
    if (x <= t1) {
      const u = (x - t0) / (t1 - t0);
      const e = 0.5 - 0.5 * Math.cos(Math.PI * u);
      return a0 + (a1 - a0) * e;
    }
  }
  return SUN_KEYS[SUN_KEYS.length - 1]![1];
}

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface PricePath {
  /** hourly true price, index = hour, 0..T_END, normalised around 0.5 */
  truth: number[];
  /** what the feed shows: frozen through the blind window */
  feed: number[];
  /** feed value immediately before and after the jump */
  frozen: number;
  resumed: number;
}

let cached: PricePath | undefined;
export function pricePath(): PricePath {
  if (cached) return cached;
  const rnd = mulberry32(20261002);
  const truth: number[] = [];
  let p = 0.52;
  for (let h = 0; h <= T_END; h++) {
    const inWindow = h > T_CLOSE && h <= T_RESUME;
    const vol = inWindow ? 0.0065 : 0.0105;
    const drift = inWindow ? -0.0042 : 0.0006; // the unobserved weekend drifts down: that is the gap
    p += (rnd() - 0.5) * 2 * vol + drift;
    p = Math.min(0.92, Math.max(0.12, p));
    truth.push(p);
  }
  // light smoothing so the ribbon reads as a price line, not static (the drift that makes the gap is kept)
  for (let pass = 0; pass < 3; pass++) {
    for (let h = 1; h < truth.length - 1; h++) {
      if (h === T_CLOSE || h === T_RESUME) continue;
      truth[h] = (truth[h - 1]! + 2 * truth[h]! + truth[h + 1]!) / 4;
    }
  }
  const frozen = truth[T_CLOSE]!;
  const resumed = truth[T_RESUME]!;
  const feed = truth.map((v, h) => (h > T_CLOSE && h < T_RESUME ? frozen : v));
  return { truth, feed, frozen, resumed };
}

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
/** "Fri 19:00 ET" for a model time. */
export function etLabel(t: number): string {
  const total = Math.round(t) + 20; // t=0 is Sunday 20:00
  const day = DAYS[Math.floor(total / 24) % 7]!;
  const hh = total % 24;
  return `${day} ${String(hh).padStart(2, "0")}:00 ET`;
}

export function readout(t: number): { phase: Phase; label: string; text: string } {
  const phase = phaseAt(t);
  const label = etLabel(t);
  switch (phase) {
    case "live":
      return { phase, label, text: "Feed live: updates are arriving and the price tracks the market." };
    case "horizon":
      return {
        phase,
        label,
        text: `Pre-window horizon (${T_CLOSE - Math.round(t)} h to go): the boosted tier's stress cap applies from 6 h before the window.`,
      };
    case "blind": {
      const elapsed = Math.round(t) - T_CLOSE;
      return {
        phase,
        label,
        text: `Blind window, hour ${elapsed} of 48 (Weekend class): the feed holds its last value; the real price keeps moving (dashed).`,
      };
    }
    default:
      return {
        phase,
        label,
        text: "Window ended: the first update arrives and the price jumps by the gap that built up while blind.",
      };
  }
}

export interface LiveWindow {
  blind: boolean;
  start: number; // unix seconds
  end: number;
  lastEnd: number;
  cls: string;
}

/** Maps a real window state onto the model axis. Returns null when the chain data cannot be mapped sensibly. */
export function liveT(w: LiveWindow, nowSec: number): number | null {
  if (w.blind && w.end > w.start) {
    const u = Math.min(Math.max((nowSec - w.start) / (w.end - w.start), 0), 1);
    return T_CLOSE + u * (T_RESUME - T_CLOSE);
  }
  if (!w.blind && w.lastEnd > 0 && w.start > w.lastEnd) {
    const u = Math.min(Math.max((nowSec - w.lastEnd) / (w.start - w.lastEnd), 0), 1);
    return u * T_CLOSE;
  }
  return null;
}

export const DEFAULT_T = 116; // an illustrative Friday dusk: used until (and unless) the chain answers
