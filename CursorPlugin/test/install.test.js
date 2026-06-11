// Installer tests — every case runs install.js in a subprocess against a
// throwaway HOME, so nothing touches the real ~/.cursor or ~/.config/vibez.
import { test } from "node:test";
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import {
  accessSync, constants, existsSync, mkdirSync, mkdtempSync,
  readdirSync, readFileSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const cli = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "install.js");

const EVENTS = ["sessionStart", "beforeSubmitPrompt", "afterAgentResponse", "stop", "sessionEnd"];

function freshHome() {
  return mkdtempSync(join(tmpdir(), "vibez-cursor-test-"));
}

function run(home, ...args) {
  const r = spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
    env: { ...process.env, HOME: home },
  });
  return { out: r.stdout + r.stderr, status: r.status };
}

function readHooks(home) {
  return JSON.parse(readFileSync(join(home, ".cursor", "hooks.json"), "utf8"));
}

test("fresh install registers all events and copies executable scripts", () => {
  const home = freshHome();
  const { out, status } = run(home, "--yes");
  assert.equal(status, 0, out);

  const config = readHooks(home);
  assert.equal(config.version, 1);
  const notifyPath = join(home, ".cursor", "vibez", "notify.sh");
  for (const event of EVENTS) {
    assert.deepEqual(config.hooks[event], [{ command: notifyPath, timeout: 30 }], `event ${event}`);
  }
  for (const script of ["notify.sh", "setup.sh"]) {
    accessSync(join(home, ".cursor", "vibez", script), constants.X_OK);
  }
  // setup.sh ran against the sandbox HOME: a fresh Vibez ID was minted.
  assert.match(out, /Your Vibez ID:/);
  assert.match(readFileSync(join(home, ".config", "vibez", "vibez-id"), "utf8"),
    /^[a-z]{3,5}(-[a-z]{3,5}){3}\n$/);
});

test("reinstall is idempotent: no duplicate entries, same content", () => {
  const home = freshHome();
  assert.equal(run(home, "--yes").status, 0);
  const first = readFileSync(join(home, ".cursor", "hooks.json"), "utf8");
  const { out, status } = run(home, "--yes");
  assert.equal(status, 0, out);
  assert.match(out, /already registered/);
  assert.equal(readFileSync(join(home, ".cursor", "hooks.json"), "utf8"), first);
  for (const event of EVENTS) assert.equal(readHooks(home).hooks[event].length, 1);
});

test("merge preserves foreign hooks and backs the file up", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  const preexisting = {
    version: 1,
    hooks: {
      stop: [{ command: "/somewhere/else.sh" }],
      beforeShellExecution: [{ command: ".cursor/hooks/guard.sh", matcher: "rm" }],
    },
  };
  writeFileSync(join(home, ".cursor", "hooks.json"), JSON.stringify(preexisting, null, 2) + "\n");

  const { out, status } = run(home, "--yes");
  assert.equal(status, 0, out);

  const config = readHooks(home);
  assert.equal(config.hooks.stop.length, 2);
  assert.equal(config.hooks.stop[0].command, "/somewhere/else.sh");
  assert.deepEqual(config.hooks.beforeShellExecution, preexisting.hooks.beforeShellExecution);
  const backups = readdirSync(join(home, ".cursor"))
    .filter((f) => f.startsWith("hooks.json.vibez-backup"));
  assert.equal(backups.length, 1);
  assert.equal(
    readFileSync(join(home, ".cursor", backups[0]), "utf8"),
    JSON.stringify(preexisting, null, 2) + "\n",
  );
});

test("user entries that wrap our script are preserved on install and uninstall", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  const wrapper = {
    command: `bash -c '${join(home, ".cursor", "vibez", "notify.sh")} && touch /tmp/ran'`,
  };
  writeFileSync(join(home, ".cursor", "hooks.json"),
    JSON.stringify({ version: 1, hooks: { stop: [wrapper] } }));

  assert.equal(run(home, "--yes").status, 0);
  const stop = readHooks(home).hooks.stop;
  assert.equal(stop.length, 2);
  assert.equal(stop[0].command, wrapper.command);

  assert.equal(run(home, "--uninstall", "--yes").status, 0);
  assert.deepEqual(readHooks(home).hooks.stop, [wrapper]);
});

test("stale vibez entries are replaced, not duplicated", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  writeFileSync(join(home, ".cursor", "hooks.json"), JSON.stringify({
    version: 1,
    hooks: { stop: [{ command: "/old/home/.cursor/vibez/notify.sh" }] },
  }));
  assert.equal(run(home, "--yes").status, 0);
  const stop = readHooks(home).hooks.stop;
  assert.equal(stop.length, 1);
  assert.equal(stop[0].command, join(home, ".cursor", "vibez", "notify.sh"));
});

test("corrupt hooks.json aborts without touching the file", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  writeFileSync(join(home, ".cursor", "hooks.json"), "{ not json");
  const { out, status } = run(home, "--yes");
  assert.notEqual(status, 0);
  assert.match(out, /not valid hooks JSON/);
  assert.equal(readFileSync(join(home, ".cursor", "hooks.json"), "utf8"), "{ not json");
  // "Nothing was changed" must be literally true — no scripts copied either.
  assert.ok(!existsSync(join(home, ".cursor", "vibez")));
});

test("non-array event value aborts without touching the file", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  const raw = JSON.stringify({ version: 1, hooks: { stop: { command: "x" } } });
  writeFileSync(join(home, ".cursor", "hooks.json"), raw);
  const { out, status } = run(home, "--yes");
  assert.notEqual(status, 0);
  assert.match(out, /is not an array/);
  assert.equal(readFileSync(join(home, ".cursor", "hooks.json"), "utf8"), raw);
});

test("uninstall removes ours, keeps foreign, deletes scripts, keeps the ID", () => {
  const home = freshHome();
  mkdirSync(join(home, ".cursor"), { recursive: true });
  writeFileSync(join(home, ".cursor", "hooks.json"), JSON.stringify({
    version: 1,
    hooks: { stop: [{ command: "/somewhere/else.sh" }] },
  }));
  assert.equal(run(home, "--yes").status, 0);
  const { out, status } = run(home, "--uninstall", "--yes");
  assert.equal(status, 0, out);

  const config = readHooks(home);
  assert.deepEqual(config.hooks.stop, [{ command: "/somewhere/else.sh" }]);
  for (const event of EVENTS.filter((e) => e !== "stop")) {
    assert.equal(config.hooks[event], undefined, `event ${event} should be gone`);
  }
  assert.ok(!existsSync(join(home, ".cursor", "vibez")));
  assert.ok(existsSync(join(home, ".config", "vibez", "vibez-id")));
});

test("dry-run changes nothing", () => {
  const home = freshHome();
  const { out, status } = run(home, "--dry-run");
  assert.equal(status, 0, out);
  assert.match(out, /dry-run/);
  assert.ok(!existsSync(join(home, ".cursor")));
});

test("--id prints a Vibez ID without installing hooks", () => {
  const home = freshHome();
  const { out, status } = run(home, "--id");
  assert.equal(status, 0, out);
  assert.match(out, /Your Vibez ID:/);
  assert.ok(!existsSync(join(home, ".cursor", "hooks.json")));
});

test("--help and --version work; unknown flags fail loudly", () => {
  const home = freshHome();
  assert.match(run(home, "--help").out, /npx vibez-cursor/);
  assert.match(run(home, "--version").out, /^\d+\.\d+\.\d+/m);
  const bogus = run(home, "--bogus");
  assert.notEqual(bogus.status, 0);
  assert.match(bogus.out, /--bogus/);
});
