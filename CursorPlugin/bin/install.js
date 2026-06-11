#!/usr/bin/env node
// vibez-cursor — installs the Vibez hooks into Cursor.
//
// Copies the hook scripts to ~/.cursor/vibez/ (npx caches are ephemeral,
// so scripts must live somewhere stable) and merges the five Vibez hook
// registrations into ~/.cursor/hooks.json, preserving any hooks the user
// already has. Cursor watches hooks.json and reloads it on save — no
// restart needed in current builds.
//
// The hook scripts in scripts/ are the source of truth for behavior;
// this file only installs them.
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { createRequire } from "node:module";
import {
  copyFileSync, chmodSync, existsSync, mkdirSync, readFileSync,
  renameSync, rmSync, writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const VERSION = createRequire(import.meta.url)("../package.json").version;
const APP_STORE = "https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780";

// One argless command for every event — notify.sh dispatches on the
// payload's hook_event_name (see scripts/notify.sh).
const EVENTS = [
  "sessionStart",
  "beforeSubmitPrompt",
  "afterAgentResponse",
  "stop",
  "sessionEnd",
];

const SCRIPTS = ["notify.sh", "setup.sh"];
const pkgScriptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts");

const cursorDir = join(homedir(), ".cursor");
const vibezDir = join(cursorDir, "vibez");
const hooksPath = join(cursorDir, "hooks.json");
const backupPath = join(cursorDir, `hooks.json.vibez-backup.${Date.now()}`);
const notifyPath = join(vibezDir, "notify.sh");

const HELP = `vibez-cursor ${VERSION} — install the Vibez hooks for Cursor

Pairs Cursor with the Vibez iOS app: your phone blocks distracting apps
while the Cursor agent works and unblocks the moment it needs you.

Usage: npx vibez-cursor [options]

Installs hook scripts to ~/.cursor/vibez/ and registers them in
~/.cursor/hooks.json (existing hooks are preserved; re-run to update).

Options:
  -y, --yes       Don't ask for confirmation
  --uninstall     Remove the Vibez hooks and scripts (keeps your Vibez ID)
  --dry-run       Show what would change, change nothing
  --id            Print your Vibez ID (generates one if missing)
  --test          Send a test push to your phone
  -v, --version   Print version
  -h, --help      Show this help

Pairing: get the Vibez iOS app (${APP_STORE}),
then enter the 4-word Vibez ID this installer prints into the app's Setup card.
One ID covers Cursor, Claude Code, and Codex on this machine.`;

// Ours = a bare path to .../vibez/notify.sh (current or from an old HOME).
// endsWith, not includes: a user entry that merely WRAPS our script in a
// larger command line is their customization — never replace or delete it.
const ours = (entry) =>
  typeof entry?.command === "string" && entry.command.trim().endsWith("/vibez/notify.sh");

function onPath(bin) {
  return spawnSync("which", [bin], { stdio: "ignore" }).status === 0;
}

function runSetup(action) {
  // Prefer the installed copy (its path is what hooks run); fall back to
  // the packaged one for --id/--test before any install has happened.
  const installed = join(vibezDir, "setup.sh");
  const script = existsSync(installed) ? installed : join(pkgScriptsDir, "setup.sh");
  const r = spawnSync("bash", [script, action], { encoding: "utf8" });
  return { ok: r.status === 0, out: ((r.stdout ?? "") + (r.stderr ?? "")).trim() };
}

// Read + parse hooks.json. A missing file is a fresh config; a present
// but unparseable file aborts — overwriting a user's hand-edited config
// because it has a stray comma would be worse than failing.
function loadHooksConfig() {
  if (!existsSync(hooksPath)) return { config: { version: 1, hooks: {} }, existed: false };
  let raw;
  try {
    raw = readFileSync(hooksPath, "utf8");
  } catch (e) {
    console.error(`Cannot read ${hooksPath}: ${e.message}`);
    process.exit(1);
  }
  try {
    const config = JSON.parse(raw);
    if (typeof config !== "object" || config === null || Array.isArray(config)) {
      throw new Error("top level is not an object");
    }
    config.version ??= 1;
    config.hooks ??= {};
    if (typeof config.hooks !== "object" || Array.isArray(config.hooks)) {
      throw new Error('"hooks" is not an object');
    }
    return { config, existed: true, raw };
  } catch (e) {
    console.error(
      `${hooksPath} exists but is not valid hooks JSON (${e.message}).\n` +
      "Fix or move it, then re-run npx vibez-cursor. Nothing was changed.",
    );
    process.exit(1);
  }
}

// Merge our registrations in: per event, drop any stale Vibez entries
// (path may have moved), keep everything foreign, append ours.
function mergedConfig(config) {
  const next = { ...config, hooks: { ...config.hooks } };
  for (const event of EVENTS) {
    const current = next.hooks[event] ?? [];
    if (!Array.isArray(current)) {
      console.error(
        `${hooksPath}: "hooks.${event}" is not an array — won't guess at a merge.\n` +
        "Fix or move the file, then re-run npx vibez-cursor. Nothing was changed.",
      );
      process.exit(1);
    }
    // Explicit timeout: the platform default is undocumented and a short
    // one could kill the hook mid-send (notify.sh worst case is ~6s).
    next.hooks[event] = [...current.filter((e) => !ours(e)), { command: notifyPath, timeout: 30 }];
  }
  return next;
}

function removedConfig(config) {
  const next = { ...config, hooks: { ...config.hooks } };
  for (const [event, entries] of Object.entries(next.hooks)) {
    if (!Array.isArray(entries)) continue;
    const kept = entries.filter((e) => !ours(e));
    if (kept.length === 0) delete next.hooks[event];
    else next.hooks[event] = kept;
  }
  return next;
}

function writeHooksConfig(config, { existed, raw }) {
  const serialized = JSON.stringify(config, null, 2) + "\n";
  if (existed && raw === serialized) return false;
  if (existed) writeFileSync(backupPath, raw);
  mkdirSync(cursorDir, { recursive: true });
  // Atomic swap: Cursor live-watches hooks.json and reloads on save — it
  // must never observe a half-written file.
  const tmp = `${hooksPath}.vibez-tmp`;
  writeFileSync(tmp, serialized);
  renameSync(tmp, hooksPath);
  return true;
}

function install(dryRun) {
  if (dryRun) {
    console.log("dry-run — would:");
    console.log(`  copy ${SCRIPTS.join(", ")} -> ${vibezDir}/`);
    console.log(`  register ${EVENTS.join(", ")} in ${hooksPath}`);
    return;
  }

  for (const prereq of ["jq", "curl"]) {
    if (!onPath(prereq)) {
      console.warn(`warning: \`${prereq}\` not found — the Vibez hooks need it to send pushes (brew install ${prereq})`);
    }
  }

  // Load + merge BEFORE copying anything: an unparseable hooks.json must
  // abort with "nothing was changed" actually being true.
  const loaded = loadHooksConfig();
  const merged = mergedConfig(loaded.config);

  mkdirSync(vibezDir, { recursive: true });
  for (const script of SCRIPTS) {
    const dest = join(vibezDir, script);
    copyFileSync(join(pkgScriptsDir, script), dest);
    chmodSync(dest, 0o755);
  }

  const changed = writeHooksConfig(merged, loaded);
  console.log(
    changed
      ? `Vibez hooks registered in ${hooksPath}${loaded.existed ? ` (backup: ${backupPath})` : ""}`
      : `Vibez hooks already registered in ${hooksPath} — scripts refreshed`,
  );
  console.log("Cursor reloads hooks.json automatically; if hooks don't appear under Cursor Settings → Hooks, restart Cursor.");

  const setup = runSetup("show");
  console.log(`\n${setup.out}`);
  console.log(`Vibez iOS app: ${APP_STORE}`);
  if (!setup.ok) process.exitCode = 1;
}

function uninstall(dryRun) {
  if (dryRun) {
    console.log("dry-run — would:");
    console.log(`  remove Vibez entries from ${hooksPath}`);
    console.log(`  remove ${vibezDir}/`);
    return;
  }
  if (existsSync(hooksPath)) {
    const loaded = loadHooksConfig();
    writeHooksConfig(removedConfig(loaded.config), loaded);
  }
  rmSync(vibezDir, { recursive: true, force: true });
  console.log(`Vibez hooks removed from ${hooksPath} and ${vibezDir} deleted.`);
  console.log("Your Vibez ID at ~/.config/vibez/ was kept — the Claude Code and Codex plugins share it.");
}

async function main() {
  const args = process.argv.slice(2);
  const known = ["-y", "--yes", "--uninstall", "--dry-run", "--id", "--test", "-v", "--version", "-h", "--help"];
  for (const a of args) {
    if (!known.includes(a)) {
      console.error(`unknown option: ${a}\n\n${HELP}`);
      process.exit(2);
    }
  }
  if (args.includes("-h") || args.includes("--help")) return console.log(HELP);
  if (args.includes("-v") || args.includes("--version")) return console.log(VERSION);
  if (args.includes("--id") || args.includes("--test")) {
    const r = runSetup(args.includes("--test") ? "test" : "show");
    console.log(r.out);
    if (!r.ok) process.exitCode = 1;
    return;
  }

  if (process.platform === "win32") {
    console.error("vibez-cursor's hooks are bash scripts — macOS and Linux only for now.");
    process.exit(1);
  }

  const dryRun = args.includes("--dry-run");
  const yes = args.includes("-y") || args.includes("--yes");
  const removing = args.includes("--uninstall");

  // Confirm on an interactive terminal; in pipes/CI (and via getvibez,
  // which always passes --yes) proceed without one.
  if (!yes && !dryRun && process.stdin.isTTY) {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const closed = new Promise((resolve) => rl.once("close", () => resolve(null)));
    const question = removing
      ? `Remove the Vibez hooks from ${hooksPath}? (Y/n) `
      : `Install the Vibez hooks into ${hooksPath}? (Y/n) `;
    const answer = await Promise.race([rl.question(question), closed]);
    rl.close();
    const a = (answer ?? "n").trim().toLowerCase();
    if (a !== "" && a !== "y" && a !== "yes") {
      return console.log("aborted — nothing was changed");
    }
  }

  try {
    if (removing) uninstall(dryRun);
    else install(dryRun);
  } catch (e) {
    console.error(`vibez-cursor failed: ${e.message}`);
    process.exit(1);
  }
}

main();
