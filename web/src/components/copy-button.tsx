"use client";

import { useState } from "react";

/** Copies an address or hash. Falls back to a hidden textarea where the async clipboard API is unavailable. */
export function CopyButton({ value, label }: { value: string; label: string }) {
  const [done, setDone] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      const t = document.createElement("textarea");
      t.value = value;
      t.setAttribute("readonly", "");
      t.style.position = "fixed";
      t.style.opacity = "0";
      document.body.appendChild(t);
      t.select();
      try {
        document.execCommand("copy");
      } catch {
        /* nothing more to try */
      }
      document.body.removeChild(t);
    }
    setDone(true);
    window.setTimeout(() => setDone(false), 1600);
  };
  return (
    <button
      type="button"
      onClick={copy}
      aria-label={`Copy ${label}`}
      className="num inline-flex min-h-8 min-w-[3.6rem] items-center justify-center rounded-full border border-border bg-white/[0.05] px-2.5 text-[0.68rem] tracking-wide text-muted-foreground transition-colors hover:border-white/35 hover:text-foreground"
    >
      <span aria-live="polite">{done ? "Copied" : "Copy"}</span>
    </button>
  );
}
