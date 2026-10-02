"use client";

import { useEffect, useRef } from "react";

import type { SkyScene } from "@/lib/sky/scene";

/**
 * Owns one three.js scene: lazy import (the three.js chunk exists only behind this file), pauses when off screen or
 * when the tab is hidden, caps the device pixel ratio (in the scene), and disposes everything on unmount.
 */
export default function SkyCanvas({
  t,
  low,
  layout,
  startT,
  snap,
  onReady,
  onFail,
}: {
  t: number;
  low: boolean;
  layout: "hero" | "compact";
  startT: number;
  /** change this number to jump the scene to `t` without easing (loop restart) */
  snap: number;
  onReady: () => void;
  onFail: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sceneRef = useRef<SkyScene | null>(null);
  const tRef = useRef(t);
  tRef.current = t;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    let scene: SkyScene | null = null;
    let cancelled = false;
    let visible = true;
    let tabVisible = !document.hidden;
    let ro: ResizeObserver | undefined;
    let io: IntersectionObserver | undefined;

    const sync = () => {
      if (!scene) return;
      if (visible && tabVisible) scene.start();
      else scene.stop();
    };
    const onVis = () => {
      tabVisible = !document.hidden;
      sync();
    };
    const onLost = (e: Event) => {
      e.preventDefault();
      onFail();
    };

    import("@/lib/sky/scene")
      .then(({ SkyScene }) => {
        if (cancelled) return;
        scene = new SkyScene({ canvas, low, layout, startT });
        sceneRef.current = scene;
        const parent = canvas.parentElement ?? canvas;
        const size = () => scene?.setSize(parent.clientWidth, parent.clientHeight);
        size();
        ro = new ResizeObserver(size);
        ro.observe(parent);
        io = new IntersectionObserver(
          (es) => {
            visible = es.some((e) => e.isIntersecting);
            sync();
          },
          { threshold: 0.01 },
        );
        io.observe(canvas);
        document.addEventListener("visibilitychange", onVis);
        canvas.addEventListener("webglcontextlost", onLost);
        scene.setTarget(tRef.current);
        scene.renderOnce();
        sync();
        onReady();
      })
      .catch(() => {
        if (!cancelled) onFail();
      });

    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", onVis);
      canvas.removeEventListener("webglcontextlost", onLost);
      ro?.disconnect();
      io?.disconnect();
      scene?.dispose();
      sceneRef.current = null;
    };
    // the scene is created once per mount; `t` is pushed below
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [low]);

  const snapRef = useRef(snap);
  useEffect(() => {
    const jump = snapRef.current !== snap;
    snapRef.current = snap;
    sceneRef.current?.setTarget(t, jump);
  }, [t, snap]);

  return <canvas ref={canvasRef} className="absolute inset-0 h-full w-full" aria-hidden="true" />;
}
