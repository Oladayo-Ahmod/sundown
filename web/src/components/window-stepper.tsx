"use client";

import { useEffect, useRef } from "react";

import { prefersReducedMotion } from "@/components/motion";

export interface Step {
  when: string;
  title: string;
  body: string;
}

/**
 * "How a window plays out": five steps, drawn in sequence by an anime.js timeline when the list scrolls into view
 * (a progress line fills while each step lights up). Reduced motion: the final, static list. The text is always in
 * the DOM; the animation only adds emphasis.
 */
export function WindowStepper({ steps }: { steps: readonly Step[] }) {
  const root = useRef<HTMLOListElement>(null);

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const items = Array.from(el.querySelectorAll<HTMLElement>("[data-step]"));
    const dots = items.map((i) => i.querySelector<HTMLElement>("[data-dot]")!);
    const fill = el.querySelector<HTMLElement>("[data-fill]");
    let played = false;
    let cancelled = false;
    const play = () => {
      if (played) return;
      played = true;
      import("animejs").then(({ createTimeline }) => {
        if (cancelled) return;
        items.forEach((i) => {
          i.style.opacity = "0.35";
        });
        const tl = createTimeline({ defaults: { ease: "outExpo" } });
        if (fill) tl.add(fill, { scaleY: [0, 1], duration: 700 * items.length, ease: "linear" }, 0);
        items.forEach((item, idx) => {
          const at = idx * 700;
          tl.add(item, { opacity: [0.35, 1], x: [-10, 0], duration: 600 }, at);
          tl.add(dots[idx]!, { scale: [0.6, 1.25, 1], duration: 700, ease: "outBack" }, at);
        });
      });
    };
    const io = new IntersectionObserver(
      (es) => {
        if (es.some((e) => e.isIntersecting)) {
          io.disconnect();
          play();
        }
      },
      { threshold: 0.25 },
    );
    io.observe(el);
    const safety = window.setTimeout(() => {
      io.disconnect();
      if (!played) {
        items.forEach((i) => i.style.removeProperty("opacity"));
      }
    }, 9000);
    return () => {
      cancelled = true;
      io.disconnect();
      window.clearTimeout(safety);
      items.forEach((i) => i.style.removeProperty("opacity"));
    };
  }, []);

  return (
    <ol ref={root} className="relative space-y-5 pl-9 sm:pl-12">
      <span className="absolute top-2 bottom-2 left-[0.7rem] w-px bg-border sm:left-[1.1rem]" aria-hidden="true" />
      <span
        data-fill
        className="absolute top-2 bottom-2 left-[0.7rem] w-px origin-top bg-[linear-gradient(180deg,#ffc46b,#86a9dc)] sm:left-[1.1rem]"
        aria-hidden="true"
      />
      {steps.map((s, i) => (
        <li key={s.title} data-step className="relative">
          <span
            data-dot
            className="num absolute top-0.5 -left-9 flex h-6 w-6 items-center justify-center rounded-full border border-warn-border bg-background-raised text-[0.7rem] text-amber sm:-left-12"
            aria-hidden="true"
          >
            {i + 1}
          </span>
          <p className="num text-xs tracking-wide text-steel">{s.when}</p>
          <h3 className="font-display text-xl leading-tight">{s.title}</h3>
          <p className="mt-1 max-w-2xl text-sm leading-relaxed text-muted-foreground">{s.body}</p>
        </li>
      ))}
    </ol>
  );
}
