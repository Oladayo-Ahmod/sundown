import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const alertVariants = cva("glass relative w-full p-4 text-sm sm:p-5", {
  variants: {
    variant: {
      default: "",
      simulation:
        "[--card:rgb(40_28_12/0.88)] border-l-[3px] border-l-warn-border text-warn-fg [&_strong]:text-[#ffe9c2] [&_code]:text-[#ffe0ad]",
    },
  },
  defaultVariants: { variant: "default" },
});

/** Callout. The `simulation` variant is the amber label for anything simulated: never restyled away. */
function Alert({
  className,
  variant,
  ...props
}: React.ComponentProps<"div"> & VariantProps<typeof alertVariants>) {
  return <div role="note" className={cn(alertVariants({ variant }), className)} {...props} />;
}

function AlertTitle({ className, ...props }: React.ComponentProps<"h3">) {
  return <h3 className={cn("mb-1 font-semibold leading-snug", className)} {...props} />;
}

function AlertDescription({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("leading-relaxed [&_p]:mb-2 [&_p:last-child]:mb-0", className)} {...props} />;
}

export { Alert, AlertTitle, AlertDescription };
