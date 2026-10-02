import { CountUp } from "@/components/motion";
import { Sources } from "@/components/provenance";
import { cn } from "@/lib/utils";

/** Glass stat tile: a tabular mono figure (counts up on scroll), its label, and the file it comes from. */
export function Stat({
  label,
  value,
  digits = 0,
  prefix,
  suffix,
  unit,
  note,
  source,
  tone = "amber",
  className,
}: {
  label: string;
  value: number;
  digits?: number;
  prefix?: string;
  suffix?: string;
  unit?: string;
  note?: string;
  source: string;
  tone?: "amber" | "steel" | "ember";
  className?: string;
}) {
  const toneClass = tone === "steel" ? "text-steel" : tone === "ember" ? "text-primary" : "text-amber";
  return (
    <div className={cn("glass glass-spot flex h-full flex-col justify-between gap-3 p-5", className)}>
      <p className="t-eyebrow">{label}</p>
      <p className="leading-none">
        <CountUp
          value={value}
          digits={digits}
          prefix={prefix}
          suffix={suffix}
          src={source}
          className={cn("text-[2.6rem] font-medium tracking-tight sm:text-[3rem]", toneClass)}
        />
        {unit ? <span className="num ml-1.5 text-sm text-muted-foreground">{unit}</span> : null}
      </p>
      <div>
        {note ? <p className="text-xs leading-relaxed text-muted-foreground">{note}</p> : null}
        <Sources files={[source]} />
      </div>
    </div>
  );
}
