import { Badge } from "@/components/ui/badge";

/** SourceLine: every research number on a block comes from the listed files (kept verbatim from the evidence build). */
export function Sources({ files, note }: { files: readonly string[]; note?: string }) {
  return (
    <p
      className="mt-4 flex gap-2 border-t border-border/70 pt-3 text-[0.72rem] leading-relaxed text-muted-foreground"
      data-testid="sources"
    >
      <span className="t-eyebrow shrink-0 pt-px text-[0.64rem]">Source</span>
      <span className="min-w-0">
        {files.map((f, i) => (
          <span key={f}>
            <code className="break-all text-[0.7rem]">{f}</code>
            {i < files.length - 1 ? ", " : ""}
          </span>
        ))}
        {note ? <span> — {note}</span> : null}
      </span>
    </p>
  );
}

/** Inline research number carrying its source file as data and tooltip. */
export function N({ src, children }: { src: string; children: React.ReactNode }) {
  return (
    <span
      className="num rounded-[4px] bg-white/[0.06] px-1 py-px text-[0.92em] font-medium text-[#fff1da]"
      data-src={src}
      title={`source: ${src}`}
    >
      {children}
    </span>
  );
}

export function SimBadge({ children = "Simulation" }: { children?: React.ReactNode }) {
  return <Badge variant="simulation">{children}</Badge>;
}
