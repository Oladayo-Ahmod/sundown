/** Formatting helpers. Values arrive from research JSON; null means "not available". */

export function fmt(v: number | null | undefined, digits = 1): string {
  if (v === null || v === undefined || Number.isNaN(v)) return "n/a";
  return v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function pct(v: number | null | undefined, digits = 1): string {
  return v === null || v === undefined ? "n/a" : `${fmt(v, digits)}%`;
}

export function ci(lo: number | null | undefined, hi: number | null | undefined, digits = 1): string {
  return `[${fmt(lo, digits)}, ${fmt(hi, digits)}]`;
}

export function usd(v: number, digits = 2): string {
  return v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function pValue(v: number | null | undefined): string {
  if (v === null || v === undefined) return "n/a";
  if (v < 0.001) return "<0.001";
  return v.toFixed(3);
}
