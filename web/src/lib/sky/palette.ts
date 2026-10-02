/** Sky colours by sun altitude. One source for the three.js scene and the static SVG fallback. */
export type RGB = [number, number, number];

const hex = (h: string): RGB => {
  const n = parseInt(h.slice(1), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
};

const DAY = { top: hex("#17123f"), mid: hex("#3a2a7d"), hor: hex("#ff9d58") };
const DUSK = { top: hex("#1c1048"), mid: hex("#7a2f86"), hor: hex("#ff6a3a") };
const NIGHT = { top: hex("#04030a"), mid: hex("#0b0820"), hor: hex("#16264a") };

const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(Math.max((x - a) / (b - a), 0), 1);
  return t * t * (3 - 2 * t);
};
const mix3 = (a: RGB, b: RGB, c: RGB, wa: number, wb: number, wc: number): RGB => [
  a[0] * wa + b[0] * wb + c[0] * wc,
  a[1] * wa + b[1] * wb + c[1] * wc,
  a[2] * wa + b[2] * wb + c[2] * wc,
];

export interface SkyColours {
  top: RGB;
  mid: RGB;
  hor: RGB;
  night: number; // 0..1: how dark (stars)
  day: number;
}

export function skyColours(alt: number): SkyColours {
  const day = smooth(0.2, 0.65, alt);
  const night = smooth(0.05, -0.35, alt);
  const dusk = Math.max(0, 1 - day - night);
  const s = day + dusk + night || 1;
  const [wd, wu, wn] = [day / s, dusk / s, night / s];
  return {
    top: mix3(DAY.top, DUSK.top, NIGHT.top, wd, wu, wn),
    mid: mix3(DAY.mid, DUSK.mid, NIGHT.mid, wd, wu, wn),
    hor: mix3(DAY.hor, DUSK.hor, NIGHT.hor, wd, wu, wn),
    night,
    day,
  };
}

export const css = (c: RGB) => `rgb(${Math.round(c[0] * 255)} ${Math.round(c[1] * 255)} ${Math.round(c[2] * 255)})`;
