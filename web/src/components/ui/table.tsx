import * as React from "react";

import { cn } from "@/lib/utils";

/** Horizontally scrollable on narrow screens; focusable so keyboard users can scroll it. */
function Table({ className, ...props }: React.ComponentProps<"table">) {
  return (
    <div
      className="w-full overflow-x-auto rounded-md border border-border"
      role="region"
      tabIndex={0}
      aria-label={props["aria-label"] ?? "Data table"}
    >
      <table className={cn("w-full caption-bottom text-sm", className)} {...props} />
    </div>
  );
}

function TableCaption({ className, ...props }: React.ComponentProps<"caption">) {
  return <caption className={cn("p-3 text-left text-xs text-muted-foreground", className)} {...props} />;
}

function TableHeader(props: React.ComponentProps<"thead">) {
  return <thead className="bg-muted" {...props} />;
}

function TableBody(props: React.ComponentProps<"tbody">) {
  return <tbody className="[&_tr:last-child]:border-0" {...props} />;
}

function TableRow({ className, ...props }: React.ComponentProps<"tr">) {
  return <tr className={cn("border-b border-border", className)} {...props} />;
}

function TableHead({ className, ...props }: React.ComponentProps<"th">) {
  return (
    <th
      scope="col"
      className={cn("px-3 py-2 text-left align-bottom font-semibold whitespace-nowrap", className)}
      {...props}
    />
  );
}

function TableCell({ className, ...props }: React.ComponentProps<"td">) {
  return <td className={cn("px-3 py-2 align-top tabular-nums", className)} {...props} />;
}

export { Table, TableHeader, TableBody, TableRow, TableHead, TableCell, TableCaption };
