import * as React from "react";

import { cn } from "@/lib/utils";

/** Glass table surface; horizontally scrollable on narrow screens and focusable so keyboards can scroll it. */
function Table({ className, ...props }: React.ComponentProps<"table">) {
  return (
    <div
      className="glass w-full overflow-x-auto"
      role="region"
      tabIndex={0}
      aria-label={props["aria-label"] ?? "Data table"}
    >
      <table className={cn("w-full caption-bottom text-sm", className)} {...props} />
    </div>
  );
}

function TableCaption({ className, ...props }: React.ComponentProps<"caption">) {
  return <caption className={cn("p-4 text-left text-xs leading-relaxed text-muted-foreground", className)} {...props} />;
}

function TableHeader(props: React.ComponentProps<"thead">) {
  return <thead className="bg-white/[0.04]" {...props} />;
}

function TableBody(props: React.ComponentProps<"tbody">) {
  return <tbody className="[&_tr:last-child]:border-0" {...props} />;
}

function TableRow({ className, ...props }: React.ComponentProps<"tr">) {
  return (
    <tr className={cn("border-b border-border/70 transition-colors hover:bg-white/[0.035]", className)} {...props} />
  );
}

function TableHead({ className, ...props }: React.ComponentProps<"th">) {
  return (
    <th
      scope="col"
      className={cn(
        "px-3.5 py-3 text-left align-bottom font-mono text-[0.68rem] font-medium tracking-[0.08em] whitespace-nowrap text-muted-foreground uppercase",
        className,
      )}
      {...props}
    />
  );
}

function TableCell({ className, ...props }: React.ComponentProps<"td">) {
  return <td className={cn("px-3.5 py-2.5 align-top tabular-nums", className)} {...props} />;
}

export { Table, TableHeader, TableBody, TableRow, TableHead, TableCell, TableCaption };
