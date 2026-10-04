import { Children, isValidElement, type ReactElement, type ReactNode } from "react";

import { TableBody, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";

/** Counts the TableRow elements inside every TableBody of an element tree (works on mapped, server-built rows). */
function countRows(node: ReactNode): number {
  let n = 0;
  const walk = (x: ReactNode, inBody: boolean) => {
    Children.forEach(x, (c) => {
      if (!isValidElement(c)) return;
      const el = c as ReactElement<{ children?: ReactNode }>;
      if (el.type === TableRow && inBody) {
        n += 1;
        return;
      }
      walk(el.props.children, inBody || el.type === TableBody);
    });
  };
  walk(node, false);
  return n;
}

/**
 * Native <details> disclosure for dense evidence: the summary line carries the title and a row count; the full
 * table (and its caption and sources) stays in the DOM and opens with the keyboard (Enter or Space on the summary).
 */
export function Disclosure({
  title,
  children,
  count,
  note,
  defaultOpen = false,
  className,
}: {
  title: string;
  /** one line shown under the title while the section is closed */
  note?: string;
  children: ReactNode;
  /** overrides the automatic row count, e.g. "3 charts" */
  count?: string;
  defaultOpen?: boolean;
  className?: string;
}) {
  const rows = countRows(children);
  const label = count ?? (rows > 0 ? `${rows} row${rows === 1 ? "" : "s"}` : "");
  return (
    <details className={cn("group glass", className)} open={defaultOpen || undefined} data-testid="disclosure">
      <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between gap-3 rounded-[inherit] px-4 py-3 marker:hidden [&::-webkit-details-marker]:hidden">
        <span className="min-w-0">
          <span className="block text-sm font-medium">{title}</span>
          {note ? <span className="mt-0.5 block text-xs leading-snug text-muted-foreground">{note}</span> : null}
        </span>
        <span className="flex items-center gap-3">
          {label ? <span className="num text-xs whitespace-nowrap text-muted-foreground">{label}</span> : null}
          <span
            aria-hidden="true"
            className="num flex h-6 w-6 items-center justify-center rounded-full border border-border text-amber transition-transform group-open:rotate-45"
          >
            +
          </span>
        </span>
      </summary>
      <div className="space-y-4 px-3 pb-4 sm:px-4">{children}</div>
    </details>
  );
}
