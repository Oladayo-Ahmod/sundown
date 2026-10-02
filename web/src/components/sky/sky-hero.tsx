"use client";

import dynamic from "next/dynamic";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { prefersReducedMotion } from "@/components/motion";
import { SkyStatic } from "@/components/sky/sky-static";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DEFAULT_T, T_CLOSE, T_END, T_RESUME, liveT, readout, type LiveWindow } from "@/lib/sky/week";
import { cn } from "@/lib/utils";

const SkyCanvas = dynamic(() => import("@/components/sky/sky-canvas"), { ssr: false });

type Chain =
  | { status: "pending" }
  | { status: "failed" }
  | { status: "ok"; w: LiveWindow & { blockTimestamp: number }; t: number | null };

/** The ~14 s opening loop: golden hour, sunset, blind night (ribbon frozen, real price dashed), resume jump. */
const CINEMA: readonly (readonly [number, number])[] = [
  [0, 102],
  [3.5, 116],
  [6.5, 124],
  [11.5, 166],
  [12.5, 170],
  [14, 176],
];
const CINEMA_LEN = 14;
const START_T = 102;

function cinemaT(sec: number): number {
  for (let i = 0; i < CINEMA.length - 1; i++) {
    const [s0, t0] = CINEMA[i]!;
    const [s1, t1] = CINEMA[i + 1]!;
    if (sec <= s1) return t0 + ((t1 - t0) * (sec - s0)) / (s1 - s0);
  }
  return CINEMA[CINEMA.length - 1]![1];
}

function webglAvailable(): boolean {
  try {
    const c = document.createElement("canvas");
    return !!(c.getContext("webgl2") || c.getContext("webgl"));
  } catch {
    return false;
  }
}

function lowTier(): boolean {
  const nav = navigator as Navigator & { deviceMemory?: number };
  return window.matchMedia("(max-width: 700px)").matches || (nav.hardwareConcurrency ?? 8) <= 4 || (nav.deviceMemory ?? 8) <= 4;
}

const fmtUtc = (s: number) => new Date(s * 1000).toISOString().replace("T", " ").slice(0, 16) + "Z";

/**
 * Full-bleed hero scene with the headline overlaid and a slim time-of-week dock. Server-rendered as a static SVG
 * dusk (sun on the horizon); after first paint it upgrades to three.js when the device allows and plays a ~14 s
 * loop until the visitor touches the slider. The real on-chain window state is a badge plus "Jump to live";
 * `variant="compact"` is the small accent used on /replay.
 */
export function SkyHero({
  variant = "hero",
  children,
}: {
  variant?: "hero" | "compact";
  children?: React.ReactNode;
}) {
  const [t, setT] = useState(DEFAULT_T);
  const [mode, setMode] = useState<"static" | "loading" | "webgl">("static");
  const [low, setLow] = useState(false);
  const [chain, setChain] = useState<Chain>({ status: "pending" });
  const [touched, setTouched] = useState(false);
  const [snap, setSnap] = useState(0);
  const hero = variant === "hero";

  // decide whether to upgrade to WebGL, after first paint
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("sky");
    const want = q === "webgl" ? true : q === "static" ? false : !prefersReducedMotion() && webglAvailable();
    if (!want || (q === "webgl" && !webglAvailable())) return;
    setLow(lowTier());
    const id = window.setTimeout(() => {
      setT(START_T);
      setMode("loading");
    }, 250);
    return () => window.clearTimeout(id);
  }, []);

  // read the real calendar once, also after first paint
  useEffect(() => {
    let dead = false;
    const id = window.setTimeout(() => {
      import("@/lib/calendar-read")
        .then(({ readLiveWindow }) => readLiveWindow())
        .then((w) => !dead && setChain({ status: "ok", w, t: liveT(w, w.blockTimestamp) }))
        .catch(() => !dead && setChain({ status: "failed" }));
    }, 900);
    return () => {
      dead = true;
      window.clearTimeout(id);
    };
  }, []);

  // the opening loop: runs while the scene is WebGL and the visitor has not touched the slider
  const playing = mode === "webgl" && !touched;
  const loopStart = useRef(0);
  useEffect(() => {
    if (!playing) return;
    let raf = 0;
    let lastSet = 0;
    loopStart.current = performance.now();
    setT(START_T);
    setSnap((n) => n + 1);
    const tick = (now: number) => {
      let sec = (now - loopStart.current) / 1000;
      if (sec >= CINEMA_LEN) {
        loopStart.current = now;
        sec = 0;
        setSnap((n) => n + 1);
      }
      if (now - lastSet > 50) {
        lastSet = now;
        setT(cinemaT(sec));
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing]);

  const r = useMemo(() => readout(Math.round(t)), [t]);
  const onReady = useCallback(() => setMode("webgl"), []);
  const onFail = useCallback(() => setMode("static"), []);
  const liveNow = chain.status === "ok" ? chain.t : null;

  const trackStops = `linear-gradient(90deg, #ffc46b 0%, #ff9a4d ${((T_CLOSE - 6) / T_END) * 100}%, #86a9dc ${(T_CLOSE / T_END) * 100}%, #86a9dc ${(T_RESUME / T_END) * 100}%, #ff9a4d ${(T_RESUME / T_END) * 100}%, #ffc46b 100%)`;

  const chainChip =
    chain.status === "pending" ? (
      <Badge variant="outline">Reading the on-chain calendar…</Badge>
    ) : chain.status === "failed" ? (
      <Badge variant="outline" className="whitespace-normal text-left">
        On-chain read unavailable: illustrative dusk shown
      </Badge>
    ) : (
      <Badge variant={chain.w.blind ? "blind" : "default"} data-testid="chain-calendar" className="whitespace-normal text-left">
        Live on-chain: {chain.w.blind ? "inside" : "outside"} a {chain.w.cls} blind window
        {chain.w.blind ? `, ends ${fmtUtc(chain.w.end)}` : `, next starts ${fmtUtc(chain.w.start)}`}
      </Badge>
    );

  const scene = (
    <div className="absolute inset-0 -z-10 [mask-image:linear-gradient(to_bottom,#000_86%,transparent)]" aria-hidden="true">
      {mode !== "webgl" ? <SkyStatic t={t} className="h-full w-full" /> : null}
      {mode !== "static" ? (
        <div className={cn("absolute inset-0 transition-opacity duration-700", mode === "webgl" ? "opacity-100" : "opacity-0")}>
          <SkyCanvas
            t={t}
            low={low}
            layout={hero ? "hero" : "compact"}
            startT={START_T}
            snap={snap}
            onReady={onReady}
            onFail={onFail}
          />
        </div>
      ) : null}
      {hero ? (
        <>
          <div className="absolute inset-0 hidden bg-[linear-gradient(90deg,rgb(7_6_15/0.9)_0%,rgb(7_6_15/0.66)_30%,rgb(7_6_15/0)_58%)] lg:block" />
          <div className="absolute inset-0 bg-[linear-gradient(180deg,rgb(7_6_15/0.86)_0%,rgb(7_6_15/0.5)_34%,rgb(7_6_15/0)_52%)] lg:hidden" />
          <div className="absolute inset-x-0 bottom-0 h-44 bg-[linear-gradient(0deg,rgb(7_6_15/0.9),transparent)]" />
        </>
      ) : null}
    </div>
  );

  const slider = (
    <div className="min-w-0">
      <label htmlFor="tow" className="t-eyebrow block">
        Time of week (Eastern Time): drag to move the sun
      </label>
      <div className="relative">
        <input
          id="tow"
          type="range"
          min={0}
          max={T_END}
          step={1}
          value={Math.round(t)}
          onChange={(e) => {
            setTouched(true);
            setT(Number(e.target.value));
          }}
          className="sun-range"
          style={{ ["--sun-track" as string]: trackStops }}
          aria-valuetext={`${r.label}: ${r.text}`}
          data-testid="tow"
        />
        {liveNow !== null ? (
          <span
            className="pointer-events-none absolute -bottom-0.5 h-2 w-0.5 rounded bg-foreground/80"
            style={{ left: `${(liveNow / T_END) * 100}%` }}
            aria-hidden="true"
          />
        ) : null}
      </div>
    </div>
  );

  const readoutLine = (
    <p className="text-sm leading-snug" aria-live="polite" data-testid="sky-readout">
      <span className="num mr-2 rounded-md bg-white/[0.08] px-1.5 py-0.5 text-[0.8rem] text-amber">{r.label}</span>
      {r.text}
    </p>
  );

  if (!hero) {
    return (
      <div className="glass relative isolate min-h-[300px] overflow-hidden" data-sky-mode={mode === "webgl" ? "webgl" : "static"} data-testid="sky-hero">
        {scene}
        <div className="relative flex min-h-[300px] flex-col justify-end gap-3 p-5">
          <div className="glass glass-strong space-y-2 p-4">
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="outline">Illustrative</Badge>
              {chainChip}
            </div>
            {readoutLine}
          </div>
        </div>
      </div>
    );
  }

  return (
    <figure>
      <div
        className="relative isolate ml-[calc(50%-50vw)] -mt-[6.4rem] h-[max(660px,100svh)] max-h-[980px] w-screen overflow-hidden"
        data-sky-mode={mode === "webgl" ? "webgl" : "static"}
        data-testid="sky-hero"
      >
        {scene}
        <div className="relative mx-auto flex h-full max-w-6xl flex-col justify-between px-4 pt-28 pb-4 sm:px-6">
          <div className="max-w-xl lg:max-w-[40rem]">{children}</div>
          <div className="glass glass-strong grid gap-3 p-3 sm:p-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:items-center lg:gap-6" data-testid="sky-panel">
            <div className="space-y-1.5">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="outline">Illustrative</Badge>
                {chainChip}
              </div>
              {readoutLine}
            </div>
            <div className="space-y-1">
              {slider}
              <div className="flex flex-wrap items-center gap-2">
                {liveNow !== null ? (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setTouched(true);
                      setT(liveNow);
                    }}
                  >
                    Jump to live
                  </Button>
                ) : null}
                {touched && mode === "webgl" ? (
                  <Button variant="ghost" size="sm" onClick={() => setTouched(false)}>
                    Play the loop
                  </Button>
                ) : null}
                <span className="hidden font-mono text-[0.64rem] tracking-wide text-muted-foreground sm:inline">
                  Sun 20:00 feed resumes · Fri 20:00 window starts · Sun 20:00 ends
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
      <figcaption className="mx-auto mt-3 max-w-6xl px-1 text-xs leading-relaxed text-muted-foreground">
        Illustrative: the price path is synthetic and the sun is a metaphor (it sets when the blind window starts and
        rises when it ends). The window times follow the D1 calendar rule (Fri 20:00 ET to Sun 20:00 ET); the status
        badge is read from the production calendar contract on Arbitrum Sepolia.
      </figcaption>
    </figure>
  );
}
