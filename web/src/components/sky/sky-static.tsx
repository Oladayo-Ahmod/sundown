import { css, skyColours } from "@/lib/sky/palette";
import { T_CLOSE, T_END, T_RESUME, pricePath, sunAltitude } from "@/lib/sky/week";

const W = 1200;
const H = 560;
const HORIZON = 330;
const X0 = 70;
const X1 = 1130;
const xOf = (t: number) => X0 + ((X1 - X0) * t) / T_END;
const yOf = (p: number) => 270 - (p - 0.12) * 330;

/**
 * The same sky as the three.js scene, as a static SVG: used on the server (no layout shift, no WebGL needed), for
 * `prefers-reduced-motion`, when WebGL is unavailable, and for phones that fail the capability check.
 */
export function SkyStatic({ t, className }: { t: number; className?: string }) {
  const alt = sunAltitude(t);
  const c = skyColours(alt);
  const path = pricePath();
  const sunX = 360 + 460 * (t / T_END);
  const sunY = HORIZON - alt * 230;
  const vis = alt > -0.62;
  const hi = Math.min(Math.floor(t), T_END);

  // feed polyline up to t (frozen through the window, then the jump)
  const live1: string[] = [];
  const frozen: string[] = [];
  const live2: string[] = [];
  for (let h = 0; h <= hi; h++) {
    const pt = `${xOf(h).toFixed(1)},${yOf(path.feed[h]!).toFixed(1)}`;
    if (h <= T_CLOSE) live1.push(pt);
    else if (h < T_RESUME) frozen.push(pt);
    else {
      if (h === T_RESUME) live2.push(`${xOf(h).toFixed(1)},${yOf(path.frozen).toFixed(1)}`);
      live2.push(pt);
    }
  }
  if (hi >= T_CLOSE && hi < T_RESUME) frozen.unshift(`${xOf(T_CLOSE).toFixed(1)},${yOf(path.frozen).toFixed(1)}`);
  const ghost: string[] = [];
  for (let h = T_CLOSE; h <= Math.min(hi, T_RESUME); h++) ghost.push(`${xOf(h).toFixed(1)},${yOf(path.truth[h]!).toFixed(1)}`);
  const headP = t < T_RESUME ? (t >= T_CLOSE ? path.frozen : path.feed[hi]!) : path.feed[hi]!;

  const stars = Array.from({ length: 46 }, (_, i) => {
    const a = Math.sin(i * 12.9898) * 43758.5453;
    const b = Math.sin(i * 78.233) * 12345.6789;
    return { x: (a - Math.floor(a)) * W, y: (b - Math.floor(b)) * (HORIZON - 40), r: 0.7 + ((i * 7) % 5) * 0.28 };
  });

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="xMidYMid slice"
      className={className}
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <linearGradient id="sk-sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={css(c.top)} />
          <stop offset="0.55" stopColor={css(c.mid)} />
          <stop offset="1" stopColor={css(c.hor)} />
        </linearGradient>
        <radialGradient id="sk-glow">
          <stop offset="0" stopColor="#ffd9a1" stopOpacity="0.9" />
          <stop offset="0.35" stopColor="#ff7a2f" stopOpacity="0.4" />
          <stop offset="1" stopColor="#ff7a2f" stopOpacity="0" />
        </radialGradient>
        <linearGradient id="sk-ground" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={css(c.hor)} stopOpacity="0.5" />
          <stop offset="0.25" stopColor="#0a0818" />
          <stop offset="1" stopColor="#05040c" />
        </linearGradient>
        <clipPath id="sk-above">
          <rect x="0" y="0" width={W} height={HORIZON} />
        </clipPath>
      </defs>
      <rect width={W} height={H} fill="url(#sk-sky)" />
      <g opacity={Math.min(1, c.night * 1.1)}>
        {stars.map((s, i) => (
          <circle key={i} cx={s.x} cy={s.y} r={s.r} fill="#dfe8ff" opacity={0.35 + (i % 4) * 0.15} />
        ))}
      </g>
      {vis ? (
        <g clipPath="url(#sk-above)">
          <circle cx={sunX} cy={sunY} r="190" fill="url(#sk-glow)" opacity={Math.min(1, (alt + 0.62) * 1.5)} />
          <circle cx={sunX} cy={sunY} r="30" fill={alt > 0.4 ? "#fff1d6" : "#ffb070"} />
        </g>
      ) : null}
      <rect y={HORIZON} width={W} height={H - HORIZON} fill="url(#sk-ground)" />
      <g stroke="#86a9dc" strokeOpacity="0.16" strokeWidth="1">
        {Array.from({ length: 9 }, (_, i) => {
          const y = HORIZON + Math.pow((i + 1) / 9, 2.1) * (H - HORIZON);
          return <line key={`h${i}`} x1="0" y1={y} x2={W} y2={y} />;
        })}
        {Array.from({ length: 15 }, (_, i) => {
          const x = (i - 7) * 150;
          return <line key={`v${i}`} x1={W / 2 + x * 0.15} y1={HORIZON} x2={W / 2 + x * 1.8} y2={H} />;
        })}
      </g>
      <line x1="0" y1={HORIZON} x2={W} y2={HORIZON} stroke={css(c.hor)} strokeOpacity="0.5" />
      {ghost.length > 1 ? (
        <polyline points={ghost.join(" ")} fill="none" stroke="#86a9dc" strokeOpacity="0.6" strokeWidth="1.5" strokeDasharray="5 6" />
      ) : null}
      {live1.length > 1 ? <polyline points={live1.join(" ")} fill="none" stroke="#ffc46b" strokeWidth="2.4" strokeLinejoin="round" /> : null}
      {frozen.length > 1 ? <polyline points={frozen.join(" ")} fill="none" stroke="#86a9dc" strokeWidth="2.4" /> : null}
      {live2.length > 1 ? <polyline points={live2.join(" ")} fill="none" stroke="#ff9a4d" strokeWidth="2.4" strokeLinejoin="round" /> : null}
      <circle cx={xOf(t)} cy={yOf(headP)} r="6" fill={t >= T_CLOSE && t < T_RESUME ? "#a9c4ee" : "#fff1d6"} />
    </svg>
  );
}
