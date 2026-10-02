#!/usr/bin/env node
// Copies the Session A deployment record and parses the live-evidence tables of docs/SEPOLIA_DEMO.md into JSON the
// pages import (web/src/data/deployment.json, demo_evidence.json). Nothing is edited by hand.
//   node web/scripts/export-chain-data.mjs [--check]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const dest = path.resolve(here, "../src/data");
const check = process.argv.includes("--check");

const deployment = JSON.parse(readFileSync(path.join(root, "deployments/421614.json"), "utf8"));
const md = readFileSync(path.join(root, "docs/SEPOLIA_DEMO.md"), "utf8");

function cells(line) {
  // split a markdown table row on unescaped pipes
  return line
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((c) => c.trim());
}

const sections = [];
let cur = null;
for (const line of md.split("\n")) {
  const h = /^## (\d+)\. (.+)$/.exec(line);
  if (h) {
    cur = { n: Number(h[1]), title: h[2], rows: [] };
    sections.push(cur);
    continue;
  }
  if (!cur || !line.startsWith("|") || /^\|[-| ]+\|$/.test(line) || line.startsWith("| Time")) continue;
  const c = cells(line);
  if (c.length < 5) continue;
  const [t, win, action, result, tx] = c;
  const [utc, et] = t.split("<br>");
  const m = /\((https:\/\/sepolia\.arbiscan\.io\/tx\/(0x[0-9a-fA-F]{64}))\)/.exec(tx);
  cur.rows.push({
    utc: utc.trim(),
    et: (et ?? "").trim(),
    window: win,
    action,
    result,
    tx: m ? { hash: m[2], url: m[1] } : null,
  });
}
const started = /Run started ([0-9: -]+Z)/.exec(md)?.[1] ?? null;
const evidence = {
  source: "docs/SEPOLIA_DEMO.md",
  run_started_utc: started,
  chain_id: 421614,
  sections,
};

const files = {
  "deployment.json": JSON.stringify(deployment, null, 2) + "\n",
  "demo_evidence.json": JSON.stringify(evidence, null, 2) + "\n",
};

if (check) {
  let bad = 0;
  for (const [f, body] of Object.entries(files)) {
    const p = path.join(dest, f);
    if (!existsSync(p) || readFileSync(p, "utf8") !== body) {
      console.error(`stale: src/data/${f}`);
      bad++;
    }
  }
  process.exit(bad ? 1 : 0);
}
for (const [f, body] of Object.entries(files)) writeFileSync(path.join(dest, f), body);
console.log(
  `wrote deployment.json (${Object.keys(deployment.contracts).length} contracts) and demo_evidence.json ` +
    `(${sections.length} sections, ${sections.reduce((a, s) => a + s.rows.length, 0)} rows, ` +
    `${sections.reduce((a, s) => a + s.rows.filter((r) => r.tx).length, 0)} with a tx link)`,
);
