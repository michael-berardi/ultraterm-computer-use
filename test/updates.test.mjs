// Update contract v1 for the npm launcher (scripts/updates.mjs). No test uses the network: the release
// API and downloads are injected fetchers, and the install path runs the real install.sh against a
// fake release folder served through file:// URLs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";
import {
  CHECK_INTERVAL_MS, MAX_LOG_BYTES, afterCommand, appendLog, checkDue, checkNow, checksAllowed, installKind,
  installUpdate, isNewer, logPath, noticeDue, noticeText, pruneRollback, readState, refresh, releaseSlug, rollback,
  statePath, updateCommand, verifyChecksum, writeState,
} from "../scripts/updates.mjs";
import { main } from "../scripts/node-repl/ultraterm-computer-use-cli.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const NOW = Date.parse("2026-11-26T12:00:00.000Z");
const TOOL = "ultraterm-computer-use";

function scratch(t) {
  const dir = mkdtempSync(path.join(tmpdir(), "utcu-update-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// An installed copy laid out like install.sh leaves it: <home>/app/release-*/node_modules/<pkg>.
function installedPackage(home, version = "0.11.0", folder = `release-${version}-aaaaaa`) {
  const packageRoot = path.join(home, "app", folder, "node_modules", TOOL);
  mkdirSync(packageRoot, { recursive: true });
  writeFileSync(path.join(packageRoot, "package.json"), JSON.stringify({
    name: TOOL, version, repository: { type: "git", url: "git+https://github.com/acme/tool.git" },
  }));
  return packageRoot;
}

function releaseResponse(tag, extra = {}) {
  return async () => ({ ok: true, status: 200, json: async () => ({ tag_name: tag, body: "- One.\n\n- Two.", draft: false, prerelease: false, ...extra }) });
}

// Serves file:// URLs from disk, the way GitHub serves release assets.
const fileFetcher = async url => {
  try {
    const bytes = readFileSync(fileURLToPath(url));
    return { ok: true, status: 200, arrayBuffer: async () => bytes };
  } catch {
    return { ok: false, status: 404 };
  }
};

function env(dir, extra = {}) {
  return { HOME: dir, XDG_CACHE_HOME: path.join(dir, "cache"), XDG_CONFIG_HOME: path.join(dir, "config"), PATH: process.env.PATH, ...extra };
}

test("version comparison: newer, equal, older, garbage and prereleases", () => {
  assert.equal(isNewer("0.12.0", "0.11.0"), true);
  assert.equal(isNewer("v1.0.0", "0.99.99"), true);
  assert.equal(isNewer("0.11.10", "0.11.9"), true);
  assert.equal(isNewer("0.11.0", "0.11.0"), false);
  assert.equal(isNewer("0.10.9", "0.11.0"), false);
  for (const bad of ["0.12.0-beta.1", "0.12.0+build", "latest", "", null, "1.2", "99999999999999999999.0.0"]) {
    assert.equal(isNewer(bad, "0.11.0"), false, String(bad));
  }
});

test("the owner/repo comes from the package metadata and the source placeholder is never contacted", t => {
  const dir = scratch(t);
  assert.equal(releaseSlug(installedPackage(dir)), "acme/tool");
  writeFileSync(path.join(dir, "package.json"), JSON.stringify({ repository: { url: "git+https://github.com/your-org/ultraterm-computer-use.git" } }));
  assert.equal(releaseSlug(dir), "");
  assert.equal(releaseSlug(root), "", "a source checkout keeps the placeholder");
});

test("checks are silent outside a terminal, in CI, under agent hosts and when opted out", t => {
  const dir = scratch(t);
  assert.equal(checksAllowed({ env: env(dir), interactive: true }), true);
  assert.equal(checksAllowed({ env: env(dir), interactive: false }), false);
  for (const [key, value] of [["CI", "true"], ["ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK", "1"], ["CLAUDECODE", "1"], ["CODEX_SANDBOX", "seatbelt"], ["GEMINI_CLI", "1"]]) {
    assert.equal(checksAllowed({ env: env(dir, { [key]: value }), interactive: true }), false, key);
  }
  const configFile = path.join(dir, "config", TOOL, "config.json");
  mkdirSync(path.dirname(configFile), { recursive: true });
  writeFileSync(configFile, JSON.stringify({ updates: { check: false } }));
  assert.equal(checksAllowed({ env: env(dir), interactive: true }), false, "config set updates.check false");
});

test("one anonymous request; the result or the failure cause is recorded in one 0600 file", async t => {
  const dir = scratch(t);
  const file = statePath(env(dir), "linux");
  const requests = [];
  const fetcher = async (url, options) => { requests.push({ url, headers: options.headers }); return releaseResponse("v0.12.0")(); };
  const result = await checkNow({ file, slug: "acme/tool", current: "0.11.0", env: {}, fetcher, now: NOW });
  assert.equal(result.status, "available");
  assert.equal(result.notes, "- One.\n- Two.");
  assert.deepEqual(requests, [{ url: "https://api.github.com/repos/acme/tool/releases/latest", headers: { "User-Agent": `${TOOL}-update-check`, Accept: "application/vnd.github+json" } }]);
  assert.deepEqual(readdirSync(path.dirname(file)), ["update-state.json"], "one cache file, no temp files");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(readState(file).latestVersion, "0.12.0");

  const prerelease = await checkNow({ file, slug: "acme/tool", current: "0.11.0", env: {}, fetcher: releaseResponse("v0.13.0-rc.1", { prerelease: true }), now: NOW });
  assert.equal(prerelease.status, "current");
  const failed = await checkNow({ file, slug: "acme/tool", current: "0.11.0", env: {}, fetcher: async () => { throw new TypeError("fetch failed", { cause: { code: "ENOTFOUND" } }); }, now: NOW });
  assert.equal(failed.status, "failed");
  assert.equal(readState(file).lastError, "check failed: fetch failed (ENOTFOUND)");
  const http = await checkNow({ file, slug: "acme/tool", current: "0.11.0", env: {}, fetcher: async () => ({ ok: false, status: 403 }), now: NOW });
  assert.equal(http.cause, "HTTP 403");
  const noRepo = await checkNow({ file, slug: "", current: "0.11.0", env: {}, fetcher: () => assert.fail("no request"), now: NOW });
  assert.equal(noRepo.cause, "the package metadata names no GitHub repository");
});

test("daily check interval, notice once a day per version, skip until a newer release, auto on/off", () => {
  assert.equal(checkDue({ lastCheckAt: null }, NOW), true);
  assert.equal(checkDue({ lastCheckAt: new Date(NOW - 3600_000).toISOString() }, NOW), false);
  assert.equal(checkDue({ lastCheckAt: new Date(NOW - CHECK_INTERVAL_MS).toISOString() }, NOW), true);
  const state = { latestVersion: "0.12.0", skippedVersion: null, lastShownVersion: null, lastShownAt: null, autoInstall: false, autoFailedVersion: null };
  assert.equal(noticeDue(state, "0.11.0", NOW), true);
  assert.equal(noticeDue(state, "0.12.0", NOW), false);
  const shown = { ...state, lastShownVersion: "0.12.0", lastShownAt: new Date(NOW - 60_000).toISOString() };
  assert.equal(noticeDue(shown, "0.11.0", NOW), false);
  assert.equal(noticeDue(shown, "0.11.0", NOW + CHECK_INTERVAL_MS), true);
  assert.equal(noticeDue({ ...state, skippedVersion: "0.12.0" }, "0.11.0", NOW), false);
  assert.equal(noticeDue({ ...state, skippedVersion: "0.11.5" }, "0.11.0", NOW), true, "a newer release notifies again");
  assert.equal(noticeDue({ ...state, autoInstall: true }, "0.11.0", NOW), false, "the background install handles it");
  assert.equal(noticeDue({ ...state, autoInstall: true, autoFailedVersion: "0.12.0" }, "0.11.0", NOW), true, "a failed automatic install falls back to the notice");
});

test("the notice: stderr only, on a terminal, never with --json or after mcp, and the check runs in the background", t => {
  const dir = scratch(t);
  const packageRoot = installedPackage(path.join(dir, "home"));
  const spawned = [];
  const spawnFn = (...args) => { spawned.push(args); return Object.assign(new EventEmitter(), { unref() {} }); };
  const stderr = [];
  const run = (argv = ["list_apps"], extra = {}) => afterCommand({
    packageRoot, argv, env: env(dir, { NO_COLOR: "1" }), platform: "linux", interactive: true, spawnFn,
    errorOutput: { write: text => stderr.push(text) }, now: NOW, ...extra,
  });
  run();
  assert.equal(spawned.length, 1, "a due check starts one detached process");
  assert.deepEqual(spawned[0][1].slice(-1), ["refresh"]);
  assert.equal(spawned[0][2].detached, true);
  assert.equal(spawned[0][2].stdio, "ignore");
  run();
  assert.equal(spawned.length, 1, "today's check is already claimed");
  assert.deepEqual(stderr, [], "nothing known yet");

  writeState(statePath(env(dir), "linux"), { latestVersion: "0.12.0" });
  run(["get_app_state", "--json"]);
  run(["mcp"]);
  run(["list_apps"], { interactive: false });
  run(["list_apps"], { code: 1 });
  assert.deepEqual(stderr, [], "never with --json, after mcp, outside a terminal or after a failure");
  run();
  assert.deepEqual(stderr, [`${noticeText("0.11.0", "0.12.0", { NO_COLOR: "1" })}\n`]);
  assert.equal(stderr[0], `${TOOL} 0.12.0 available (you have 0.11.0) · run: ${TOOL} update\nturn on automatic updates: ${TOOL} update --auto on · skip: ${TOOL} update --skip\n`);
  run();
  assert.equal(stderr.length, 1, "at most once per 24 hours per version");
  assert.match(noticeText("0.11.0", "0.12.0", {}), /\n\x1b\[2mturn on automatic updates/, "second line is dim");
});

test("launcher: --json output stays clean, mcp prints nothing, update is handled before the native runtime", async t => {
  const dir = scratch(t);
  const packageRoot = installedPackage(path.join(dir, "home"));
  const native = path.join(packageRoot, "dist", "native");
  mkdirSync(path.dirname(native), { recursive: true });
  writeFileSync(native, "#!/bin/sh\n");
  chmodSync(native, 0o755);
  writeState(statePath(env(dir), process.platform), { latestVersion: "0.12.0", lastCheckAt: new Date().toISOString() });
  const nativeCalls = [];
  const spawnFn = (command, args) => {
    nativeCalls.push(args);
    const child = Object.assign(new EventEmitter(), { unref() {}, kill() {} });
    setImmediate(() => child.emit("exit", 0, null));
    return child;
  };
  const tty = () => {
    const stream = new PassThrough();
    let text = "";
    stream.on("data", chunk => { text += chunk; });
    return Object.assign(stream, { isTTY: true, text: () => text });
  };
  const launch = async argv => {
    const output = tty(), errorOutput = tty();
    const code = await main({
      packageRoot, argv, output, errorOutput, env: env(dir), spawnFn,
      platformPackages: { [`${process.platform}-${process.arch}`]: { executablePath: ["dist", "native"] } },
      fetcher: releaseResponse("v0.12.0"),
    });
    return { code, stdout: output.text(), stderr: errorOutput.text() };
  };
  for (const argv of [["get_app_state", "--app", "X", "--json"], ["mcp"]]) {
    const r = await launch(argv);
    assert.deepEqual([r.code, r.stdout, r.stderr], [0, "", ""], argv.join(" "));
  }
  let r = await launch(["list_apps"]);
  assert.equal(r.stdout, "");
  assert.match(r.stderr, /^ultraterm-computer-use 0\.12\.0 available \(you have 0\.11\.0\)/);
  nativeCalls.length = 0;
  r = await launch(["update", "--check"]);
  assert.deepEqual([r.code, r.stdout], [10, `${TOOL} 0.12.0 available (you have 0.11.0)\n`]);
  assert.deepEqual(nativeCalls, [], "update never reaches the native runtime");
  r = await launch(["update", "--bogus"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown update option: --bogus/);
});

test("update: --check exit codes, --skip, --auto persistence, prompts and the one-time auto question", async t => {
  const dir = scratch(t);
  const packageRoot = installedPackage(path.join(dir, "home"));
  const e = env(dir);
  const file = statePath(e, "linux");
  const lines = [];
  const installs = [];
  const run = (argv, { tag = "v0.12.0", answers = [], interactive = false, fetcher = releaseResponse(tag) } = {}) => updateCommand(argv, {
    packageRoot, env: e, platform: "linux", interactive, fetcher, now: NOW,
    output: { write: text => lines.push(text.trimEnd()) }, errorOutput: { write: text => lines.push(text.trimEnd()) },
    ask: question => { lines.push(question.trimEnd()); return answers.shift() ?? ""; },
    install: async options => { installs.push(options.version); },
  });
  assert.equal(await run(["--check"]), 10);
  assert.equal(await run(["--check"], { tag: "v0.11.0" }), 0);
  assert.equal(await run(["--check"], { fetcher: async () => { throw new Error("offline"); } }), 1);
  assert.equal(lines.at(-1), `${TOOL} update: check failed: offline`);

  assert.equal(readState(file).autoInstall, false, "off by default");
  assert.equal(await run(["--auto", "on"]), 0);
  assert.equal(readState(file).autoInstall, true);
  await run(["--auto", "status"]);
  assert.equal(lines.at(-1), "automatic updates: on");
  await run(["--auto", "off"]);
  assert.equal(readState(file).autoInstall, false);

  assert.equal(await run(["--skip"]), 0);
  assert.equal(readState(file).skippedVersion, "0.12.0");
  await assert.rejects(run(["--check", "--skip"]), /one update option at a time/);

  lines.length = 0;
  assert.equal(await run([], { interactive: true, answers: ["n"] }), 0);
  assert.deepEqual(lines, [`${TOOL} 0.11.0 → 0.12.0`, "- One.\n- Two.", "Install 0.12.0 now? [Y/n]"]);
  assert.deepEqual(installs, [], "declined");
  assert.equal(await run([], { interactive: true, answers: ["", "n"] }), 0);
  assert.deepEqual(installs, ["0.12.0"]);
  assert.equal(lines.at(-1), "Install future updates automatically? [y/N]");
  assert.deepEqual([readState(file).autoInstall, readState(file).autoAsked], [false, true]);
  lines.length = 0;
  await run([], { interactive: true, answers: [""] });
  assert.ok(!lines.some(line => line.includes("future updates")), "never asked again after n");
  lines.length = 0;
  await run([]);
  assert.ok(!lines.some(line => line.includes("[Y/n]")), "non-TTY installs without questions");
  assert.equal(installs.length, 3);
});

test("install refuses a checksum mismatch before running anything and removes its temp folder", async t => {
  const dir = scratch(t);
  const packageRoot = installedPackage(path.join(dir, "home"));
  const tmpRoot = path.join(dir, "tmp");
  mkdirSync(tmpRoot);
  const script = Buffer.from("#!/bin/sh\necho installed\n");
  const assets = sums => async url => ({
    ok: true, status: 200,
    arrayBuffer: async () => (url.endsWith("/SHA256SUMS") ? Buffer.from(sums) : script),
  });
  const runs = [];
  const run = async (command, args, options) => { runs.push({ command, args, env: options.env }); };
  for (const sums of [`${"0".repeat(64)}  install.sh\n`, `${sha(script)}  other.sh\n`]) {
    await assert.rejects(
      installUpdate({ version: "0.12.0", packageRoot, env: {}, platform: "linux", fetcher: assets(sums), run, tmpRoot }),
      /checksum mismatch for install\.sh; nothing was installed|SHA256SUMS has no entry for install\.sh/,
    );
  }
  assert.deepEqual(runs, []);
  assert.deepEqual(readdirSync(tmpRoot), [], "temp folder removed on failure");

  await installUpdate({ version: "0.12.0", packageRoot, env: {}, platform: "linux", fetcher: assets(`${sha(script)}  install.sh\n`), run, tmpRoot });
  assert.equal(runs.length, 1);
  assert.equal(runs[0].command, "/bin/sh");
  assert.equal(runs[0].env.UTCU_VERSION, "0.12.0");
  assert.equal(runs[0].env.UTCU_HOME, path.join(dir, "home"));
  assert.equal(runs[0].env.UTCU_RELEASE_BASE, "https://github.com/acme/tool/releases/download/v0.12.0");
  assert.deepEqual(readdirSync(tmpRoot), [], "temp folder removed on success");
  await assert.rejects(
    installUpdate({ version: "0.12.0", packageRoot, env: {}, platform: "linux", fetcher: assets(`${sha(script)}  install.sh\n`), run: async () => { throw new Error("sh exited with 1"); }, tmpRoot }),
    /sh exited with 1/,
  );
  assert.deepEqual(readdirSync(tmpRoot), []);
  assert.throws(() => verifyChecksum(Buffer.from("x"), `${sha(Buffer.from("y"))}  a.tgz`, "a.tgz"), /checksum mismatch/);
});

test("npm installs: the verified tarball goes to npm; a source checkout never installs", async t => {
  const dir = scratch(t);
  const npmRoot = path.join(dir, "lib", "node_modules", TOOL);
  mkdirSync(npmRoot, { recursive: true });
  writeFileSync(path.join(npmRoot, "package.json"), JSON.stringify({ version: "0.11.0", repository: { url: "https://github.com/acme/tool" } }));
  assert.equal(installKind(npmRoot).kind, "npm");
  assert.equal(installKind(root).kind, "source");
  const tgz = Buffer.from("tarball");
  const runs = [];
  await installUpdate({
    version: "0.12.0", packageRoot: npmRoot, env: {}, platform: "linux", tmpRoot: dir,
    fetcher: async url => ({ ok: true, status: 200, arrayBuffer: async () => (url.endsWith("SHA256SUMS") ? Buffer.from(`${sha(tgz)}  ${TOOL}-0.12.0.tgz\n`) : tgz) }),
    run: async (command, args, options) => { runs.push([command, args, readFileSync(path.join(options.cwd, args[2]))]); },
  });
  assert.deepEqual(runs, [["npm", ["install", "--global", `./${TOOL}-0.12.0.tgz`], tgz]]);
  await assert.rejects(installUpdate({ version: "0.12.0", packageRoot: root, env: {} }), /source checkout; update it with git pull/);
  assert.throws(() => rollback(npmRoot), /not available for npm installs/);
});

test("automatic install: background, low priority, logged; a failure records the cause and is not retried", async t => {
  const dir = scratch(t);
  const packageRoot = installedPackage(path.join(dir, "home"));
  const e = env(dir);
  const file = statePath(e, "linux");
  writeState(file, { autoInstall: true });
  const installs = [];
  let fail = true;
  const install = async options => {
    installs.push(options.version);
    assert.ok(Array.isArray(options.stdio), "installer output goes to the log");
    if (fail) throw new Error("sh exited with 1");
  };
  await refresh({ packageRoot, env: e, platform: "linux", fetcher: releaseResponse("v0.12.0"), install, now: NOW });
  assert.deepEqual(installs, ["0.12.0"]);
  let state = readState(file);
  assert.equal(state.autoFailedVersion, "0.12.0");
  assert.equal(state.lastError, "automatic install of 0.12.0 failed: sh exited with 1");
  assert.equal(noticeDue(state, "0.11.0", NOW), true, "falls back to the notice");
  assert.match(readFileSync(logPath(e, "linux"), "utf8"), /install of 0\.12\.0 failed: sh exited with 1/);
  await refresh({ packageRoot, env: e, platform: "linux", fetcher: releaseResponse("v0.12.0"), install, now: NOW });
  assert.equal(installs.length, 1, "no retry loop for the failed version");
  fail = false;
  await refresh({ packageRoot, env: e, platform: "linux", fetcher: releaseResponse("v0.12.1"), install, now: NOW });
  assert.deepEqual(installs, ["0.12.0", "0.12.1"]);
  state = readState(file);
  assert.equal(state.autoFailedVersion, null);
  writeState(file, { autoInstall: false });
  await refresh({ packageRoot, env: e, platform: "linux", fetcher: releaseResponse("v0.13.0"), install, now: NOW });
  assert.equal(installs.length, 2, "auto off: check only");
});

test("the background log stays one file of at most 256 KB", t => {
  const dir = scratch(t);
  const log = path.join(dir, "auto-update.log");
  const line = "x".repeat(1000);
  for (let i = 0; i < 600; i += 1) appendLog(log, line);
  assert.ok(statSync(log).size <= MAX_LOG_BYTES, `${statSync(log).size} bytes`);
  assert.deepEqual(readdirSync(dir), ["auto-update.log"]);
});

test("rollback copy: kept until the new version runs successfully once, or 7 days at most", t => {
  const dir = scratch(t);
  const home = path.join(dir, "home");
  const previous = installedPackage(home, "0.11.0", "release-0.11.0-aaaaaa");
  const current = installedPackage(home, "0.12.0", "release-0.12.0-bbbbbb");
  const releases = () => readdirSync(path.join(home, "app")).sort();
  pruneRollback(current, { succeeded: false, now: Date.now() });
  assert.equal(releases().length, 2, "a failed run keeps it");
  afterCommand({ packageRoot: current, code: 0, env: { UTCU_INSTALL_CHECK: "1" }, platform: "linux" });
  assert.equal(releases().length, 2, "the installer's own checks are not the first run");
  pruneRollback(current, { succeeded: false, now: Date.now() + 8 * CHECK_INTERVAL_MS });
  assert.deepEqual(releases(), ["release-0.12.0-bbbbbb"], "gone after 7 days");
  installedPackage(home, "0.11.0", "release-0.11.0-aaaaaa");
  pruneRollback(current, { succeeded: true });
  assert.deepEqual(releases(), ["release-0.12.0-bbbbbb"], "gone after a successful run");
  pruneRollback(previous);
});

// ---- the real install.sh, driven by `update`, against fake releases served from file:// ----
function fakeRelease(dir, version) {
  const rel = path.join(dir, `rel-${version}`);
  if (existsSync(rel)) return rel;
  const src = path.join(dir, `src-${version}`, "package");
  mkdirSync(path.join(src, "bin"), { recursive: true });
  writeFileSync(path.join(src, "package.json"), JSON.stringify({ name: TOOL, version, bin: { [TOOL]: "bin/ultraterm-computer-use" }, repository: { url: "git+https://github.com/acme/tool.git" } }, null, 2));
  writeFileSync(path.join(src, "bin", TOOL), `#!/usr/bin/env node\nconsole.log(process.argv[2] === "doctor" ? "doctor ok" : "${version}");\n`);
  chmodSync(path.join(src, "bin", TOOL), 0o755);
  mkdirSync(rel);
  const tgz = `${TOOL}-${version}.tgz`;
  assert.equal(spawnSync("tar", ["-czf", path.join(rel, tgz), "-C", path.dirname(src), "package"]).status, 0);
  cpSync(path.join(root, "scripts", "install.sh"), path.join(rel, "install.sh"));
  const sums = [tgz, "install.sh"].map(name => `${sha(readFileSync(path.join(rel, name)))}  ${name}\n`).join("");
  writeFileSync(path.join(rel, "SHA256SUMS"), sums);
  return rel;
}

test("update installs through the verified install.sh, keeps one rollback copy, and --rollback restores it", { skip: process.platform === "win32" }, async t => {
  const dir = scratch(t);
  const home = path.join(dir, "home");
  const bin = path.join(dir, "bin");
  const tmpRoot = path.join(dir, "tmp");
  mkdirSync(tmpRoot);
  const base = { ...env(dir), UTCU_HOME: home, UTCU_BIN_DIR: bin };
  // `update` runs without UTCU_BIN_DIR: the shim it finds on PATH decides where the new shim goes.
  const updateEnv = { ...env(dir), PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  const shim = () => spawnSync(path.join(bin, TOOL), ["--version"], { encoding: "utf8" }).stdout.trim();
  const releases = () => readdirSync(path.join(home, "app")).filter(name => name.startsWith("release-")).sort();
  const first = fakeRelease(dir, "0.11.0");
  const r = spawnSync("sh", [path.join(first, "install.sh"), ...(process.platform === "darwin" ? ["--npm"] : [])], {
    encoding: "utf8", env: { ...base, UTCU_RELEASE_BASE: `file://${first}` },
  });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(shim(), "0.11.0");
  // Node runs the launcher from its real path (macOS: /var is /private/var), not the shim's spelling.
  const installed = name => path.join(realpathSync(home), "app", name, "node_modules", TOOL);
  const live = () => releases().find(name => readFileSync(path.join(bin, TOOL), "utf8").includes(`/${name}/`));
  const update = async (version, from) => installUpdate({
    version, packageRoot: installed(live()), env: { ...updateEnv, UTCU_RELEASE_BASE: `file://${fakeRelease(dir, version)}` },
    fetcher: fileFetcher, tmpRoot, stdio: "ignore",
  });

  await update("0.12.0");
  assert.equal(shim(), "0.12.0");
  assert.equal(releases().length, 2, "the new release and one rollback copy");
  assert.ok(!existsSync(path.join(dir, ".local")), "no second shim in the default folder");
  assert.deepEqual(readdirSync(tmpRoot), [], "download folder removed");

  const updated = live();
  assert.equal(rollback(installed(updated)), "0.11.0");
  assert.equal(shim(), "0.11.0", "the shim runs the previous release again");
  assert.equal(releases().length, 1);
  assert.throws(() => rollback(installed(updated)), /no previous release is kept/);

  await update("0.12.0");
  await update("0.13.0");
  assert.equal(shim(), "0.13.0");
  assert.equal(releases().length, 2, "never more than one rollback copy");
  pruneRollback(installed(live()), { succeeded: true });
  assert.equal(releases().length, 1);

  // A tampered tarball: install.sh refuses it and the live release keeps working.
  const bad = fakeRelease(dir, "0.14.0");
  writeFileSync(path.join(bad, `${TOOL}-0.14.0.tgz`), "tampered");
  await assert.rejects(installUpdate({
    version: "0.14.0", packageRoot: installed(live()), env: { ...updateEnv, UTCU_RELEASE_BASE: `file://${bad}` },
    fetcher: fileFetcher, tmpRoot, stdio: "ignore",
  }), /sh exited with 1/);
  assert.equal(shim(), "0.13.0");
  assert.deepEqual(readdirSync(tmpRoot), []);
});

test("docs carry the contract marker and the macOS uninstall removes the update cache", () => {
  assert.match(readFileSync(path.join(root, "docs", "updates.md"), "utf8"), /^<!-- update-contract: v1 -->$/m);
  const macInstaller = readFileSync(path.join(root, "scripts", "install-ultraterm-computer-use.sh"), "utf8");
  assert.match(macInstaller, /uninstall\)[\s\S]*rm -rf "\$HOME\/Library\/Caches\/ultraterm-computer-use"/);
  assert.doesNotMatch(macInstaller, /^\s*update\)/m, "the shim passes update to the CLI");
  assert.ok(!existsSync(path.join(root, "apps", "UltraTermComputerUse", "Sources", "UltraTermComputerUse", "UpdateUI.swift")));
});
