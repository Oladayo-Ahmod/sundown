/** Minimal read of the production window cache (WindowCache.peek) for the hero: one eth_call, nothing else. */
import { windowCacheAbi } from "@/abi/windowCacheAbi";
import { addr, readClient } from "@/lib/chain";
import { WINDOW_CLASS } from "@/lib/chain";
import type { LiveWindow } from "@/lib/sky/week";

export async function readLiveWindow(signal?: { aborted: boolean }): Promise<LiveWindow & { blockTimestamp: number }> {
  const c = readClient();
  const [w, block] = await Promise.all([
    c.readContract({ address: addr("WindowCache"), abi: windowCacheAbi, functionName: "peek" }),
    c.getBlock(),
  ]);
  if (signal?.aborted) throw new Error("aborted");
  return {
    blind: w.blind,
    start: Number(w.start),
    end: Number(w.end),
    lastEnd: Number(w.lastEnd),
    cls: WINDOW_CLASS[w.cls] ?? String(w.cls),
    blockTimestamp: Number(block.timestamp),
  };
}
