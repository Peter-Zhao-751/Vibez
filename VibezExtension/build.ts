// Vibez extension bundler (Bun).
//
// Three bundles land in dist/:
//   • popup.js      — ESM, loaded by popup.html as a module script
//   • background.js — ESM, manifest `type: "module"` service worker
//   • content.js    — injected directly as a classic content script (the
//                     bundle has no ESM syntax, so Chrome runs it as-is in
//                     the isolated world — CSP-exempt, unlike a page-context
//                     dynamic import).
//
// splitting:false keeps each bundle self-contained — content.js is loaded
// independently of popup.js, so they can't share a chunk.

import { rm, mkdir, cp } from "node:fs/promises";
import { existsSync } from "node:fs";

const root = import.meta.dir;
const src = `${root}/src`;
const dist = `${root}/dist`;
const watch = process.argv.includes("--watch");

const define = { "process.env.NODE_ENV": JSON.stringify("production") };

async function buildOnce() {
  await rm(dist, { recursive: true, force: true });
  await mkdir(dist, { recursive: true });

  const result = await Bun.build({
    entrypoints: [
      `${src}/popup/popup.tsx`,
      `${src}/background/background.ts`,
      `${src}/content/content.tsx`,
    ],
    outdir: dist,
    target: "browser",
    format: "esm",
    splitting: false,
    minify: true,
    sourcemap: "linked",
    define,
    naming: "[name].js",
  });

  if (!result.success) {
    for (const log of result.logs) console.error(log);
    throw new Error("Bun.build failed");
  }

  // Static assets.
  await cp(`${src}/manifest.json`, `${dist}/manifest.json`);
  await cp(`${src}/popup.html`, `${dist}/popup.html`);
  await cp(`${src}/popup/popup.css`, `${dist}/popup.css`);
  if (existsSync(`${root}/icons`)) {
    await cp(`${root}/icons`, `${dist}/icons`, { recursive: true });
  }

  console.log(`✓ built → dist/  (${new Date().toLocaleTimeString()})`);
}

await buildOnce();

if (watch) {
  const { watch: fsWatch } = await import("node:fs");
  let timer: ReturnType<typeof setTimeout> | null = null;
  fsWatch(src, { recursive: true }, () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => buildOnce().catch(console.error), 80);
  });
  console.log("… watching src/ for changes (Ctrl-C to stop)");
}
