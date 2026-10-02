"use client";

import dynamic from "next/dynamic";
import { useCallback, useEffect, useMemo, useState } from "react";

import { SkyStatic } from "@/components/sky/sky-static";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { prefersReducedMotion } from "@/components/motion";
import { DEFAULT_T, T_CLOSE, T_END, T_RESUME, liveT, readout, type LiveWindow } from "@/lib/sky/week";
import { cn } from "@/lib/utils";

const SkyCanvas = dynamic(() => import("@/components/sky/sky-canvas"), { ssr: false });

type Chain =
  | { status: "pending" }
  | { status: "failed" }
  | { status: "ok"; w: LiveWindow & { blockTimestamp: number }; t: number | null };

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
 * Hero scene and its "time of week" control. Server-rendered as a static SVG sky; after first paint (idle) it
 * upgrades to the three.js scene when the device allows, and reads the on-chain calendar once to set the sun.
 * `variant="compact"` is the small accent used on /replay: same scene and chain read, no scrubber.
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

  // decide whether to upgrade to WebGL, after first paint
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("sky");
    const want = q === "webgl" ? true : q === "static" ? false : !prefersReducedMotion() && webglAvailable();
    if (!want || (q === "webgl" && !webglAvailable())) return;
    setLow(lowTier());
    const id = window.setTimeout(() => setMode("loading"), 350);
    return () => window.clearTimeout(id);
  }, []);

  // read the real calendar once, also after first paint
  useEffect(() => {
    let dead = false;
    const run = () => {
      import("@/lib/calendar-read")
        .then(({ readLiveWindow }) => readLiveWindow())
        .then((w) => {
          if (dead) return;
          const mapped = liveT(w, w.blockTimestamp);
          setChain({ status: "ok", w, t: mapped });
          if (mapped !== null) setT((prev) => (touched ? prev : mapped));
        })
        .catch(() => !dead && setChain({ status: "failed" }));
    };
    const id = window.setTimeout(run, 900);
    return () => {
      dead = true;
      window.clearTimeout(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const r = useMemo(() => readout(t), [t]);
  const onReady = useCallback(() => setMode("webgl"), []);
  const onFail = useCallback(() => setMode("static"), []);
  const liveNow = chain.status === "ok" ? chain.t : null;

  const trackStops = `linear-gradient(90deg, #ffc46b 0%, #ff9a4d ${((T_CLOSE - 6) / T_END) * 100}%, #86a9dc ${(T_CLOSE / T_END) * 100}%, #86a9dc ${(T_RESUME / T_END) * 100}%, #ff9a4d ${(T_RESUME / T_END) * 100}%, #ffc46b 100%)`;

  const chainChip =
    chain.status === "pending" ? (
      <Badge variant="outline">Reading the on-chain calendar…</Badge>
    ) : chain.status === "failed" ? (
      <Badge variant="outline" className="whitespace-normal text-left">On-chain read unavailable: illustrative Friday dusk shown</Badge>
    ) : (
      <Badge variant={chain.w.blind ? "blind" : "default"} data-testid="chain-calendar" className="whitespace-normal text-left">
        On-chain calendar now: {chain.w.blind ? "inside" : "outside"} a {chain.w.cls} blind window
        {chain.w.blind ? `, ends ${fmtUtc(chain.w.end)}` : `, next starts ${fmtUtc(chain.w.start)}`}
      </Badge>
    );

  return (
    <figure className="space-y-3">
    <div
      className={cn(
        "glass relative isolate overflow-hidden",
        variant === "hero" ? "min-h-[600px] sm:min-h-[680px]" : "min-h-[300px]",
      )}
      data-sky-mode={mode === "webgl" ? "webgl" : "static"}
      data-testid="sky-hero"
    >
      <div className="absolute inset-0 -z-10" aria-hidden="true">
        <SkyStatic t={t} className="h-full w-full" />
        {mode !== "static" ? (
          <div
            className={cn("absolute inset-0 transition-opacity duration-1000", mode === "webgl" ? "opacity-100" : "opacity-0")}
          >
            <SkyCanvas t={t} low={low} onReady={onReady} onFail={onFail} />
          </div>
        ) : null}
        {/* scrim: keeps the text column on a near-solid dark ground and the lower panel readable */}
        <div className="absolute inset-x-0 bottom-0 h-40 bg-[linear-gradient(0deg,rgb(7_6_15/0.85),transparent)]" />
      </div>

      <div className="relative flex h-full min-h-[inherit] flex-col justify-between gap-8 p-5 sm:p-9 lg:p-12">
        {children ? <div className="max-w-2xl">{children}</div> : <div />}

        <div
          className={cn("glass glass-strong space-y-3 p-4 sm:p-5", variant === "hero" ? "max-w-3xl" : "max-w-3xl")}
          data-testid="sky-panel"
        >
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant="outline">Illustrative</Badge>
            {chainChip}
          </div>
          {variant === "hero" ? (
            <div>
              <label htmlFor="tow" className="t-eyebrow">
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
                    style={{ left: `calc(${(liveNow / T_END) * 100}% )` }}
                    aria-hidden="true"
                  />
                ) : null}
              </div>
              <div className="mt-1 flex justify-between font-mono text-[0.66rem] tracking-wide text-muted-foreground">
                <span>Sun 20:00 feed resumes</span>
                <span className="hidden sm:inline">Fri 20:00 window starts</span>
                <span>Sun 20:00 ends</span>
              </div>
            </div>
          ) : null}
          <p className="text-sm leading-relaxed" aria-live="polite" data-testid="sky-readout">
            <span className="num mr-2 rounded-md bg-white/[0.08] px-1.5 py-0.5 text-[0.82rem] text-amber">{r.label}</span>
            {r.text}
          </p>
          {liveNow !== null && variant === "hero" ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setTouched(false);
                setT(liveNow);
              }}
            >
              Jump to now
            </Button>
          ) : null}

        </div>
      </div>
    </div>
              <figcaption className="max-w-3xl px-1 text-xs leading-relaxed text-muted-foreground">
            Illustrative: the price path is synthetic and the sun is a metaphor (it sets when the blind window starts and
            rises when it ends). The window times follow the D1 calendar rule ({"Fri 20:00 ET to Sun 20:00 ET"}); the
            status badge is read from the production calendar contract on Arbitrum Sepolia.
          </figcaption>
    </figure>
  );
}
