#!/usr/bin/env node
// vibez installer — one command to install the Vibez plugin into every
// supported agent CLI. Thin wrapper around the official plugin commands;
// the plugins in ClaudePlugin/ and CodexPlugin/ are the source of truth.
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const VERSION = createRequire(import.meta.url)("./package.json").version;
const REPO = "Peter-Zhao-751/Vibez";
const APP_STORE = "https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780";

// Each target lists its CLI's own plugin-manager invocations:
// setup (register + refresh the marketplace), install, and — when the
// plugin is already present — update. Codex has no separate update verb;
// its `plugin add` reinstalls from the freshly upgraded snapshot.
const TARGETS = [
  {
    flag: "--claude",
    name: "Claude Code",
    bin: "claude",
    setup: [
      ["plugin", "marketplace", "add", REPO],
      ["plugin", "marketplace", "update", "plugin"],
    ],
    install: ["plugin", "install", "vibez@plugin"],
    update: ["plugin", "update", "vibez@plugin"],
    installHint: "https://code.claude.com/docs — npm install -g @anthropic-ai/claude-code",
  },
  {
    flag: "--codex",
    name: "Codex",
    bin: "codex",
    setup: [
      ["plugin", "marketplace", "add", REPO],
      ["plugin", "marketplace", "upgrade", "vibez"],
    ],
    install: ["plugin", "add", "vibez@vibez"],
    update: null,
    installHint: "https://developers.openai.com/codex — npm install -g @openai/codex",
  },
  {
    flag: "--cursor",
    name: "Cursor",
    bin: "cursor",
    // Cursor has no plugin-manager CLI; the vibez-cursor npm package owns
    // the real install (copies hook scripts into ~/.cursor/vibez, merges
    // ~/.cursor/hooks.json). Re-running it is the update path. Detection
    // accepts the IDE's config dir too — many Cursor installs never add
    // the `cursor` shell command to PATH. Hooks are bash, so no Windows.
    detect: () =>
      process.platform !== "win32" &&
      (onPath("cursor") || existsSync(join(homedir(), ".cursor"))),
    commands: [["npx", "-y", "vibez-cursor@latest", "--yes"]],
    installHint: "https://cursor.com",
  },
];

const HELP = `vibez ${VERSION} — install the Vibez plugin for your agent CLIs

Usage: npx getvibez [options]

Detects Claude Code, Codex, and Cursor on this machine and installs the
Vibez notification plugin into each. Re-run it anytime to update
already-installed plugins to the latest version.

Options:
  --claude        Install for Claude Code only (skips the prompt)
  --codex         Install for Codex only (skips the prompt)
  --cursor        Install for Cursor only (skips the prompt)
  -y, --yes       Install for every detected CLI without prompting
  --dry-run       Print the commands that would run, run nothing
  -v, --version   Print version
  -h, --help      Show this help

Pairing: get the Vibez iOS app (${APP_STORE}),
then open a new agent session — it prints your 4-word Vibez ID to enter in the app.`;

function onPath(bin) {
  const probe = process.platform === "win32" ? "where" : "which";
  return spawnSync(probe, [bin], { stdio: "ignore" }).status === 0;
}

function detectTarget(target) {
  return target.detect ? target.detect() : onPath(target.bin);
}

function commandsFor(target) {
  if (target.commands) return target.commands;
  return [...target.setup, target.install].map((args) => [target.bin, ...args]);
}

function run(bin, args) {
  const r = spawnSync(bin, args, { encoding: "utf8" });
  const out = (r.stdout ?? "") + (r.stderr ?? "");
  return {
    ok: r.status === 0,
    already: /already/i.test(out),
    detail: out.trim() || `${bin} ${args.join(" ")} exited ${r.status}`,
  };
}

// Register + refresh the marketplace, then install — or update when the
// plugin is already present. "Already added/installed" counts as success
// per step, so re-running is both harmless and how users pull updates.
function install(target) {
  // Delegated targets (Cursor): one self-contained command owns the whole
  // install. Surface its output on success too — vibez-cursor prints the
  // user's Vibez ID and pairing steps, which getvibez must not swallow.
  if (target.commands) {
    let output = "";
    for (const [bin, ...args] of target.commands) {
      const r = run(bin, args);
      if (!r.ok) return { ok: false, detail: r.detail };
      output += (output ? "\n" : "") + r.detail;
    }
    return { ok: true, output };
  }
  for (const args of target.setup) {
    const r = run(target.bin, args);
    if (!r.ok && !r.already) return { ok: false, detail: r.detail };
  }
  const installed = run(target.bin, target.install);
  if (installed.already && target.update) {
    const updated = run(target.bin, target.update);
    return updated.ok || updated.already
      ? { ok: true, updated: true }
      : { ok: false, detail: updated.detail };
  }
  if (!installed.ok && !installed.already) return { ok: false, detail: installed.detail };
  return { ok: true };
}

// Race the question against readline closing: piped stdin hitting EOF
// leaves question() pending forever, which would end the process silently.
async function confirm(rl, closed, question) {
  const answer = await Promise.race([rl.question(`${question} (Y/n) `), closed]);
  if (answer === null) return null;
  const a = answer.trim().toLowerCase();
  return a === "" || a === "y" || a === "yes";
}

async function main() {
  const args = process.argv.slice(2);
  for (const a of args) {
    if (!["--claude", "--codex", "--cursor", "-y", "--yes", "--dry-run", "-v", "--version", "-h", "--help"].includes(a)) {
      console.error(`unknown option: ${a}\n\n${HELP}`);
      process.exit(2);
    }
  }
  if (args.includes("-h") || args.includes("--help")) return console.log(HELP);
  if (args.includes("-v") || args.includes("--version")) return console.log(VERSION);

  const dryRun = args.includes("--dry-run");
  const yes = args.includes("-y") || args.includes("--yes");
  const narrowed = TARGETS.filter((t) => args.includes(t.flag));

  const detected = TARGETS.filter(detectTarget);
  const missing = TARGETS.filter((t) => !detectTarget(t));

  for (const t of narrowed.filter((t) => !detectTarget(t))) {
    console.error(`${t.name}: not found on this machine.\n  Install it first: ${t.installHint}`);
    process.exit(1);
  }
  if (detected.length === 0) {
    console.error("No supported agent CLIs found on PATH.\n");
    for (const t of TARGETS) console.error(`  ${t.name}: ${t.installHint}`);
    process.exit(1);
  }

  for (const prereq of ["jq", "curl"]) {
    if (!onPath(prereq)) {
      console.warn(`warning: \`${prereq}\` not found — the Vibez hooks need it to send pushes (brew install ${prereq})`);
    }
  }

  console.log(`Detected: ${detected.map((t) => t.name).join(", ")}`);
  for (const t of missing) console.log(`Skipping ${t.name} (not found on this machine)`);
  console.log();

  let selected;
  if (narrowed.length > 0) {
    selected = narrowed;
  } else if (yes || dryRun) {
    selected = detected;
  } else {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.on("SIGINT", () => {
      rl.close();
      console.log("\naborted — nothing was installed");
      process.exit(130);
    });
    const closed = new Promise((resolve) => rl.once("close", () => resolve(null)));
    selected = [];
    for (const t of detected) {
      const wanted = await confirm(rl, closed, `Install Vibez for ${t.name}?`);
      if (wanted === null) break;
      if (wanted) selected.push(t);
    }
    rl.close();
    if (selected.length === 0) return console.log("Nothing selected — nothing to do.");
  }

  if (dryRun) {
    console.log("dry-run — would run:");
    for (const t of selected) {
      for (const cmd of commandsFor(t)) console.log(`  ${cmd.join(" ")}`);
    }
    return;
  }

  let failed = false;
  for (const t of selected) {
    process.stdout.write(`Installing for ${t.name}... `);
    const result = install(t);
    if (result.ok) {
      console.log(result.updated ? "updated to latest ✓" : "done ✓");
      if (result.output) console.log(result.output.replace(/^/gm, "  "));
    } else {
      failed = true;
      console.log("failed ✗");
      console.error(result.detail);
    }
  }

  console.log(`
Next steps:
  1. Get the Vibez iOS app: ${APP_STORE}
  2. Open a new agent session — it prints your private 4-word Vibez ID.
     (In Claude Code, /vibez:setup shows it again; the Cursor install
     prints the ID right above.)
  3. Enter the ID in the app's Setup card. One ID covers all your agents.`);
  if (selected.some((t) => t.bin === "codex")) {
    console.log(`
Note: on first launch, Codex will ask you to review and trust the Vibez
hooks — that's expected (Codex requires a one-time review of any plugin's
hooks, and again if an update changes them).`);
  }
  if (failed) process.exit(1);
}

main();
