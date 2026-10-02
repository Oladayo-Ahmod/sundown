import { Badge } from "@/components/ui/badge";

/** Visible provenance line: every research number on a block comes from the listed files. */
export function Sources({ files, note }: { files: readonly string[]; note?: string }) {
  return (
    <p className="mt-3 text-xs leading-relaxed text-muted-foreground" data-testid="sources">
      <span className="font-semibold">Source:</span>{" "}
      {files.map((f, i) => (
        <span key={f}>
          <code className="font-mono break-all">{f}</code>
          {i < files.length - 1 ? ", " : ""}
        </span>
      ))}
      {note ? <span> — {note}</span> : null}
    </p>
  );
}

/** Inline research number carrying its source file as data and tooltip. */
export function N({ src, children }: { src: string; children: React.ReactNode }) {
  return (
    <span className="font-semibold tabular-nums" data-src={src} title={`source: ${src}`}>
      {children}
    </span>
  );
}

export function SimBadge({ children = "Simulation" }: { children?: React.ReactNode }) {
  return <Badge variant="simulation">{children}</Badge>;
}
