import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-full text-sm font-medium tracking-wide transition-[transform,box-shadow,background-color,border-color] duration-200 disabled:pointer-events-none disabled:opacity-60 min-h-11 sm:min-h-10 active:scale-[0.98]",
  {
    variants: {
      variant: {
        default:
          "bg-[linear-gradient(135deg,#ffb86b,#ff7a2f)] text-primary-foreground shadow-[0_8px_28px_-8px_rgb(255_122_47/0.7),inset_0_1px_0_rgb(255_255_255/0.45)] hover:shadow-[0_10px_34px_-6px_rgb(255_122_47/0.85),inset_0_1px_0_rgb(255_255_255/0.5)]",
        outline:
          "border border-white/20 bg-white/[0.06] text-foreground backdrop-blur hover:border-white/35 hover:bg-white/[0.1]",
        ghost: "text-foreground hover:bg-white/[0.08]",
      },
      size: {
        default: "px-5 py-2",
        sm: "px-3.5 py-1.5",
      },
    },
    defaultVariants: { variant: "default", size: "default" },
  },
);

function Button({
  className,
  variant,
  size,
  asChild = false,
  ...props
}: React.ComponentProps<"button"> & VariantProps<typeof buttonVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "button";
  return <Comp className={cn(buttonVariants({ variant, size, className }))} {...props} />;
}

export { Button, buttonVariants };
