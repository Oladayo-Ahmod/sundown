import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 font-mono text-[0.7rem] font-medium tracking-wide whitespace-nowrap",
  {
    variants: {
      variant: {
        default: "border-border bg-white/[0.07] text-foreground",
        simulation: "border-warn-border bg-warn-bg text-warn-fg",
        outline: "border-border bg-transparent text-muted-foreground",
        blind: "border-steel/50 bg-steel-bg text-steel",
        allow: "border-allow/50 bg-allow/10 text-allow",
        deny: "border-deny/50 bg-deny/10 text-deny",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

function Badge({
  className,
  variant,
  ...props
}: React.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
