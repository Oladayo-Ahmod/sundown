"use client";

import { useId, useMemo, useState } from "react";

import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { fmt, usd } from "@/lib/format";

export type ReplayEvent = {
  asset: string;
  class: string;
  prev_close_date: string;
  open_date: string;
  prev_close: number;
  open: number;
  gap_bps: number;
  loss_pct: number;
  n_closed_days: number;
  window_hours: number;
  window_start_utc: string;
  window_end_utc: string;
  ex_dividend_open: boolean;
};

const SOURCE = "sim/replay_events.json";

export function EventsTable({ events }: { events: readonly ReplayEvent[] }) {
  const id = useId();
  const [asset, setAsset] = useState("ALL");
  const assets = useMemo(() => ["ALL", ...Array.from(new Set(events.map((e) => e.asset))).sort()], [events]);
  const rows = useMemo(() => events.filter((e) => asset === "ALL" || e.asset === asset), [events, asset]);
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 text-sm">
        <label htmlFor={id} className="font-medium">
          Asset
        </label>
        <select
          id={id}
          value={asset}
          onChange={(e) => setAsset(e.target.value)}
          className="min-h-11 rounded-md border border-border bg-background px-2 sm:min-h-9"
        >
          {assets.map((a) => (
            <option key={a} value={a}>
              {a === "ALL" ? "All assets" : a}
            </option>
          ))}
        </select>
        <span className="text-muted-foreground" aria-live="polite">
          {rows.length} events
        </span>
      </div>
      <Table aria-label="Most severe real weekend and holiday gaps">
        <TableCaption>
          Real historical gaps (previous regular close to next regular open), most severe first. Prices are
          split-adjusted at retrieval, not as traded; use the ratios. Window times are UTC under the D1 rule
          (20:00 ET close of the last open day to 20:00 ET the evening before the next open day).
        </TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>Asset</TableHead>
            <TableHead>Class</TableHead>
            <TableHead>Window (UTC)</TableHead>
            <TableHead>Prev close</TableHead>
            <TableHead>Open</TableHead>
            <TableHead>Gap</TableHead>
            <TableHead>On-chain replay tx</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((e) => (
            <TableRow key={`${e.asset}-${e.open_date}`} data-src={SOURCE}>
              <TableCell className="font-medium">{e.asset}</TableCell>
              <TableCell>
                {e.class} ({e.window_hours} h)
              </TableCell>
              <TableCell className="whitespace-nowrap">
                {e.window_start_utc.slice(0, 16).replace("T", " ")} to {e.window_end_utc.slice(0, 16).replace("T", " ")}
              </TableCell>
              <TableCell>{usd(e.prev_close)}</TableCell>
              <TableCell>{usd(e.open)}</TableCell>
              <TableCell className="whitespace-nowrap">
                {fmt(-e.loss_pct, 2)}% ({fmt(e.gap_bps, 0)} bps)
              </TableCell>
              <TableCell className="text-muted-foreground">Not deployed yet</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
