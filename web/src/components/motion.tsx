"use client";

/**
 * Motion primitives built on anime.js v4 (`animate`, `stagger`; loaded on demand so they stay out of the first
 * paint). Rules: content is always in the DOM and readable first; animation only adds, never gates, access to
 * data; everything is skipped (final state shown immediately) under `prefers-reduced-motion`; a timer reveals any
 * element that an observer has not reached, so nothing can stay hidden.
 */
import Link from "next/link";
import { useEffect, useRef } from "react";

import { cn } from "@/lib/utils";

export function prefersReducedMotion(): boolean {
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

const loadAnime = () => import("animejs");

function clearInline(el: HTMLElement) {
  el.style.removeProperty("opacity");
  el.style.removeProperty("transform");
  el.style.removeProperty("will-change");
}

/** Scroll-triggered reveal. Elements already in view on load are left alone (no flash of hidden content). */
export function Reveal({
  children,
  className,
  delay = 0,
  y = 22,
  as: Tag = "div",
}: {
  children: React.ReactNode;
  className?: string;
  delay?: number;
  y?: number;
  as?: "div" | "section" | "li" | "header" | "p";
}) {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefersReducedMotion()) return;
    if (el.getBoundingClientRect().top < window.innerHeight * 0.92) return;
    el.style.opacity = "0";
    el.style.transform = `translateY(${y}px)`;
    el.style.willChange = "opacity, transform";
    let done = false;
    const show = () => {
      if (done) return;
      done = true;
      io.disconnect();
      loadAnime().then(({ animate }) => {
        animate(el, {
          opacity: [0, 1],
          y: [y, 0],
          duration: 850,
          delay,
          ease: "outExpo",
          onComplete: () => clearInline(el),
        });
      });
    };
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) show();
      },
      { threshold: 0.08, rootMargin: "0px 0px -6% 0px" },
    );
    io.observe(el);
    const safety = window.setTimeout(() => {
      if (!done) {
        done = true;
        io.disconnect();
        clearInline(el);
      }
    }, 6000);
    return () => {
      io.disconnect();
      window.clearTimeout(safety);
      clearInline(el);
    };
  }, [delay, y]);
  const T = Tag as React.ElementType;
  return (
    <T ref={ref} className={className}>
      {children}
    </T>
  );
}

/** Words of a headline that rise in a stagger on load. Text is server-rendered visible; motion only adds. */
export function StaggerText({ children, className }: { children: React.ReactNode; className?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefersReducedMotion()) return;
    const words = Array.from(el.querySelectorAll<HTMLElement>("[data-w]"));
    words.forEach((w) => {
      w.style.opacity = "0";
    });
    let cancelled = false;
    loadAnime().then(({ animate, stagger }) => {
      if (cancelled) return;
      animate(words, {
        opacity: [0, 1],
        y: ["0.5em", "0em"],
        duration: 900,
        delay: stagger(55, { start: 120 }),
        ease: "outExpo",
        onComplete: () => words.forEach((w) => clearInline(w)),
      });
    });
    return () => {
      cancelled = true;
      words.forEach((w) => clearInline(w));
    };
  }, []);
  return (
    <span ref={ref} className={className}>
      {children}
    </span>
  );
}

/** One word of StaggerText. */
export function W({ children, em = false }: { children: React.ReactNode; em?: boolean }) {
  return (
    <span data-w className="inline-block will-change-transform">
      {em ? <em>{children}</em> : children}
    </span>
  );
}

function fmtNum(v: number, digits: number) {
  return v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/** "1,224.5" as HTML with the thousands separator in a narrow span; textContent stays the exact string. */
function figureHtml(s: string): string {
  return s.replace(/,/g, '<span class="sep">,</span>');
}

/** Tabular mono number that counts up when it scrolls into view. The final value is server-rendered. */
export function CountUp({
  value,
  digits = 0,
  prefix = "",
  suffix = "",
  className,
  src,
}: {
  value: number;
  digits?: number;
  prefix?: string;
  suffix?: string;
  className?: string;
  src?: string;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const finalText = `${prefix}${fmtNum(value, digits)}${suffix}`;
  useEffect(() => {
    const el = ref.current;
    if (!el || prefersReducedMotion()) return;
    if (el.getBoundingClientRect().top < window.innerHeight * 0.9) return;
    const write = (v: number) => {
      el.innerHTML = figureHtml(`${prefix}${fmtNum(v, digits)}${suffix}`);
    };
    write(0);
    let done = false;
    const final = () => {
      done = true;
      write(value);
    };
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting) || done) return;
        done = true;
        io.disconnect();
        loadAnime().then(({ animate }) => {
          const o = { v: 0 };
          animate(o, {
            v: value,
            duration: 1400,
            ease: "outExpo",
            onUpdate: () => write(o.v),
            onComplete: final,
          });
        });
      },
      { threshold: 0.4 },
    );
    io.observe(el);
    const safety = window.setTimeout(() => {
      io.disconnect();
      if (!done) final();
    }, 8000);
    return () => {
      io.disconnect();
      window.clearTimeout(safety);
      write(value);
    };
  }, [value, digits, prefix, suffix]);
  return (
    <span
      ref={ref}
      className={cn("num", className)}
      data-src={src}
      data-final={finalText}
      dangerouslySetInnerHTML={{ __html: figureHtml(finalText) }}
    />
  );
}

/** Updates the spotlight position of the glass panel under the pointer (one listener for the whole page). */
export function PointerGlow() {
  useEffect(() => {
    if (prefersReducedMotion() || !window.matchMedia("(hover: hover)").matches) return;
    let raf = 0;
    const onMove = (e: PointerEvent) => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const panel = (e.target as HTMLElement | null)?.closest<HTMLElement>(".glass-spot");
        if (!panel) return;
        const r = panel.getBoundingClientRect();
        panel.style.setProperty("--mx", `${e.clientX - r.left}px`);
        panel.style.setProperty("--my", `${e.clientY - r.top}px`);
      });
    };
    document.addEventListener("pointermove", onMove, { passive: true });
    return () => {
      document.removeEventListener("pointermove", onMove);
      cancelAnimationFrame(raf);
    };
  }, []);
  return null;
}

/** Link that leans toward the pointer a few pixels and springs back (anime.js). Pointer devices only. */
export function MagneticLink({
  href,
  className,
  children,
  strength = 0.22,
}: {
  href: string;
  className?: string;
  children: React.ReactNode;
  strength?: number;
}) {
  const ref = useRef<HTMLAnchorElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefersReducedMotion() || !window.matchMedia("(hover: hover)").matches) return;
    let anim: { cancel?: () => void } | undefined;
    const move = (e: PointerEvent) => {
      const r = el.getBoundingClientRect();
      const x = (e.clientX - (r.left + r.width / 2)) * strength;
      const y = (e.clientY - (r.top + r.height / 2)) * strength;
      loadAnime().then(({ animate }) => {
        anim?.cancel?.();
        anim = animate(el, { x, y, duration: 220, ease: "outQuad" });
      });
    };
    const leave = () => {
      loadAnime().then(({ animate }) => {
        anim?.cancel?.();
        anim = animate(el, { x: 0, y: 0, duration: 700, ease: "outElastic(1, .6)" });
      });
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerleave", leave);
    return () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerleave", leave);
    };
  }, [strength]);
  return (
    <Link ref={ref} href={href} prefetch={false} className={className}>
      {children}
    </Link>
  );
}
