"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export type LiveState<T> =
  | { status: "loading"; data?: T; error?: string }
  | { status: "ok"; data: T; error?: undefined }
  | { status: "error"; data?: T; error: string };

/** Runs a read-only loader on mount and on demand; keeps the last good data if a refresh fails. */
export function useLive<T>(load: () => Promise<T>): [LiveState<T>, () => void] {
  const [state, setState] = useState<LiveState<T>>({ status: "loading" });
  const last = useRef<T | undefined>(undefined);
  const run = useCallback(() => {
    setState((s) => ({ status: "loading", data: s.data }));
    load().then(
      (data) => {
        last.current = data;
        setState({ status: "ok", data });
      },
      (e: unknown) =>
        setState({ status: "error", data: last.current, error: e instanceof Error ? (e.message.split("\n")[0] ?? "unknown error") : String(e) }),
    );
  }, [load]);
  useEffect(run, [run]);
  return [state, run];
}
