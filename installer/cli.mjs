#!/usr/bin/env node
// vibez installer — one command to install the Vibez plugin into every
// supported agent CLI. Thin wrapper around the official plugin commands;
// the plugins in ClaudePlugin/ and CodexPlugin/ are the source of truth.
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { createRequire } from "node:module";

const VERSION = createRequire(import.meta.url)("./package.json").version;
const REPO = "Peter-Zhao-751/Vibez";
const APP_STORE = "https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780";

const TARGETS = [
  {
    flag: "--claude",
    name: "Claude Code",
    bin: "claude",
    installVerb: "install",
    spec: "vibez@plugin",
    installHint: "https://code.claude.com/docs — npm install -g @anthropic-ai/claude-code",
  },
  {
    flag: "--codex",
    name: "Codex",
    bin: "codex",
    installVerb: "add",
    spec: "vibez@vibez",
    installHint: "https://developers.openai.com/codex — npm install -g @openai/codex",
  },
];

const HELP = `vibez ${VERSION} — install the Vibez plugin for your agent CLIs

Usage: npx @vibez/cli [options]

Detects Claude Code and Codex on this machine and installs the Vibez
notification plugin into each via its own plugin manager.

Options:
  --claude        Install for Claude Code only (skips the prompt)
  --codex         Install for Codex only (skips the prompt)
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

function commandsFor(target) {
  return [
    [target.bin, "plugin", "marketplace", "add", REPO],
    [target.bin, "plugin", target.installVerb, target.spec],
  ];
}

// Runs both plugin commands for a target. "Already added/installed" counts
// as success so re-runs are harmless.
function install(target) {
  for (const [bin, ...args] of commandsFor(target)) {
    const r = spawnSync(bin, args, { encoding: "utf8" });
    const out = (r.stdout ?? "") + (r.stderr ?? "");
    if (r.status !== 0 && !/already/i.test(out)) {
      return { ok: false, detail: out.trim() || `${bin} ${args.join(" ")} exited ${r.status}` };
    }
    if (/already/i.test(out)) return { ok: true, already: true };
  }
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
    if (!["--claude", "--codex", "-y", "--yes", "--dry-run", "-v", "--version", "-h", "--help"].includes(a)) {
      console.error(`unknown option: ${a}\n\n${HELP}`);
      process.exit(2);
    }
  }
  if (args.includes("-h") || args.includes("--help")) return console.log(HELP);
  if (args.includes("-v") || args.includes("--version")) return console.log(VERSION);

  const dryRun = args.includes("--dry-run");
  const yes = args.includes("-y") || args.includes("--yes");
  const narrowed = TARGETS.filter((t) => args.includes(t.flag));

  const detected = TARGETS.filter((t) => onPath(t.bin));
  const missing = TARGETS.filter((t) => !onPath(t.bin));

  for (const t of narrowed.filter((t) => !onPath(t.bin))) {
    console.error(`${t.name}: \`${t.bin}\` not found on PATH.\n  Install it first: ${t.installHint}`);
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
  for (const t of missing) console.log(`Skipping ${t.name} (\`${t.bin}\` not on PATH)`);
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
      console.log(result.already ? "already installed ✓" : "done ✓");
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
     (In Claude Code, /vibez:setup shows it again.)
  3. Enter the ID in the app's Setup card. One ID covers both agents.`);
  if (failed) process.exit(1);
}

main();
