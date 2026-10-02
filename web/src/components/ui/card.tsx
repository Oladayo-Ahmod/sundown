import * as React from "react";

import { cn } from "@/lib/utils";

/** Glass panel: translucent fill, blur, gradient hairline, pointer spotlight (see globals.css, PointerGlow). */
function Card({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("glass glass-spot min-w-0 text-foreground", className)} {...props} />;
}

function CardHeader({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("flex flex-col gap-2 p-5 pb-2 sm:p-6 sm:pb-2", className)} {...props} />;
}

function CardTitle({ className, ...props }: React.ComponentProps<"h3">) {
  return (
    <h3
      className={cn("font-display text-xl leading-tight font-normal tracking-tight sm:text-[1.4rem]", className)}
      {...props}
    />
  );
}

function CardDescription({ className, ...props }: React.ComponentProps<"p">) {
  return <p className={cn("text-sm text-muted-foreground", className)} {...props} />;
}

function CardContent({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("p-5 pt-2 sm:p-6 sm:pt-2", className)} {...props} />;
}

function CardFooter({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("flex items-center p-5 pt-0 sm:p-6 sm:pt-0", className)} {...props} />;
}

export { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter };
