// Dry-run assertions for the vibez installer CLI.
// Requires `claude` and `codex` on PATH (both are dev-machine prerequisites).
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const cli = join(dirname(fileURLToPath(import.meta.url)), "cli.mjs");

function run(...args) {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
  return { out: r.stdout + r.stderr, status: r.status };
}

// --help and --version
{
  const { out, status } = run("--help");
  assert.equal(status, 0);
  assert.match(out, /npx getvibez/);
  assert.match(out, /--dry-run/);
}
{
  const { out, status } = run("--version");
  assert.equal(status, 0);
  assert.match(out, /^\d+\.\d+\.\d+/m);
}

// dry-run with no flags: all detected CLIs, full command sets, nothing executed
{
  const { out, status } = run("--dry-run");
  assert.equal(status, 0);
  assert.match(out, /claude plugin marketplace add Peter-Zhao-751\/Vibez/);
  assert.match(out, /claude plugin marketplace update plugin/);
  assert.match(out, /claude plugin install vibez@plugin/);
  assert.match(out, /codex plugin marketplace add Peter-Zhao-751\/Vibez/);
  assert.match(out, /codex plugin marketplace upgrade vibez/);
  assert.match(out, /codex plugin add vibez@vibez/);
  assert.match(out, /dry-run/i);
}

// dry-run narrowed to one CLI
{
  const { out, status } = run("--dry-run", "--claude");
  assert.equal(status, 0);
  assert.match(out, /claude plugin install vibez@plugin/);
  assert.doesNotMatch(out, /codex plugin/);
}
{
  const { out, status } = run("--dry-run", "--codex");
  assert.equal(status, 0);
  assert.match(out, /codex plugin add vibez@vibez/);
  assert.doesNotMatch(out, /claude plugin/);
}

// unknown flag fails loudly
{
  const { out, status } = run("--bogus");
  assert.notEqual(status, 0);
  assert.match(out, /--bogus/);
}

console.log("all installer tests passed");
