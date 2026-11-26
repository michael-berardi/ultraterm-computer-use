// Update check and `update` command for the npm launcher (update contract v1, docs/updates.md).
//
// The check is one anonymous GET of the public latest-release record, at most once a day, run in a
// detached background process so it never delays a command. Installs verify the release SHA256SUMS
// before anything is replaced. State is one small owner-only JSON file in the platform cache folder.
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  appendFileSync,
  closeSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, setPriority, tmpdir } from "node:os";
import path from "node:path";
import readline from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { inspectConfig } from "./node-repl/config.mjs";

export const TOOL = "ultraterm-computer-use";
export const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
export const CHECK_TIMEOUT_MS = 4000;
export const ROLLBACK_MAX_AGE_MS = 7 * CHECK_INTERVAL_MS;
export const MAX_LOG_BYTES = 256 * 1024;
const DOWNLOAD_TIMEOUT_MS = 300_000;
const USER_AGENT = `${TOOL}-update-check`;
// Agent hosts that run shell commands; their output goes to a model, not a person.
const AGENT_ENV = ["CLAUDECODE", "CODEX_SANDBOX", "GEMINI_CLI"];
const ownRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const STATE_DEFAULTS = {
  lastCheckAt: null,
  latestVersion: null,
  lastError: null,
  skippedVersion: null,
  lastShownVersion: null,
  lastShownAt: null,
  autoInstall: false,
  autoAsked: false,
  autoFailedVersion: null,
};

export class UpdateError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

// Only stable x.y.z (optional leading v). Prereleases, build tags and garbage are never newer.
export function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(value ?? "").trim());
  const parts = match?.slice(1).map(Number);
  return parts?.every(Number.isSafeInteger) ? parts : null;
}

export function isNewer(latest, current) {
  const a = parseVersion(latest), b = parseVersion(current);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i += 1) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}

function readPackage(packageRoot) {
  try { return JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8")); } catch { return {}; }
}

export function packageVersion(packageRoot = ownRoot) {
  return String(readPackage(packageRoot).version ?? "");
}

// owner/repo from the package's own repository URL; the source placeholder is never contacted.
export function releaseSlug(packageRoot = ownRoot) {
  const pkg = readPackage(packageRoot);
  const match = /github\.com[/:]([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?$/.exec(String(pkg.repository?.url ?? ""));
  return match && match[1] !== "your-org" ? `${match[1]}/${match[2]}` : "";
}

export function cacheDir(env = process.env, platform = process.platform) {
  const home = env.HOME || homedir();
  if (platform === "darwin") return path.join(home, "Library", "Caches", TOOL);
  if (platform === "win32") return path.join(env.LOCALAPPDATA || path.join(home, "AppData", "Local"), TOOL, "Cache");
  return path.join(env.XDG_CACHE_HOME || path.join(home, ".cache"), TOOL);
}

export const statePath = (env, platform) => path.join(cacheDir(env, platform), "update-state.json");
export const logPath = (env, platform) => path.join(cacheDir(env, platform), "auto-update.log");

export function readState(file) {
  const state = { ...STATE_DEFAULTS };
  let saved;
  try { saved = JSON.parse(readFileSync(file, "utf8")); } catch { return state; }
  if (!saved || typeof saved !== "object") return state;
  for (const [key, fallback] of Object.entries(STATE_DEFAULTS)) {
    if (typeof saved[key] === (typeof fallback === "boolean" ? "boolean" : "string")) state[key] = saved[key];
  }
  return state;
}

// Atomic (temp file + rename in the same folder) and owner-only.
export function writeState(file, changes) {
  const state = { ...readState(file), ...changes };
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(state)}\n`, { mode: 0o600, flag: "wx" });
    renameSync(temporary, file);
  } finally {
    rmSync(temporary, { force: true });
  }
  return state;
}

// The automatic check and notice: off outside a terminal, in CI, under agent hosts and when opted out.
export function checksAllowed({ env = process.env, interactive = false } = {}) {
  if (!interactive || env.CI) return false;
  if (env.ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK && env.ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK !== "0") return false;
  if (AGENT_ENV.some(name => env[name])) return false;
  try { return inspectConfig(env).values["updates.check"] !== false; } catch { return true; }
}

export function checkDue(state, now = Date.now()) {
  const age = now - Date.parse(state.lastCheckAt ?? "");
  return !(age >= 0 && age < CHECK_INTERVAL_MS);
}

export function noticeDue(state, current, now = Date.now()) {
  const latest = state.latestVersion;
  if (!isNewer(latest, current)) return false;
  if (state.skippedVersion && !isNewer(latest, state.skippedVersion)) return false;
  // With automatic installs on, the background install handles it unless it already failed for this version.
  if (state.autoInstall && state.autoFailedVersion !== latest) return false;
  if (state.lastShownVersion === latest && now - Date.parse(state.lastShownAt ?? "") < CHECK_INTERVAL_MS) return false;
  return true;
}

export function noticeText(current, latest, env = process.env) {
  const hint = `turn on automatic updates: ${TOOL} update --auto on · skip: ${TOOL} update --skip`;
  return `${TOOL} ${latest} available (you have ${current}) · run: ${TOOL} update\n${env.NO_COLOR ? hint : `\x1b[2m${hint}\x1b[22m`}`;
}

function describe(error) {
  const cause = error?.cause?.code ?? error?.cause?.message;
  const message = error?.name === "TimeoutError" ? "timed out" : String(error?.message ?? error);
  return cause ? `${message} (${cause})` : message;
}

export async function fetchLatest({ slug, env = process.env, fetcher = globalThis.fetch }) {
  const url = env.ULTRATERM_COMPUTER_USE_UPDATE_API || (slug && `https://api.github.com/repos/${slug}/releases/latest`);
  if (!url) throw new Error("the package metadata names no GitHub repository");
  const response = await fetcher(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "application/vnd.github+json" },
    signal: AbortSignal.timeout(CHECK_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const release = await response.json();
  if (release?.draft || release?.prerelease) return { version: null, notes: "" };
  const version = parseVersion(release?.tag_name)?.join(".") ?? null;
  const notes = String(release?.body ?? "").split(/\r?\n/).filter(line => line.trim()).slice(0, 6).join("\n");
  return { version, notes };
}

// One request; the result or the failure cause is recorded either way.
export async function checkNow({ file, slug, current, env = process.env, fetcher, now = Date.now() }) {
  const lastCheckAt = new Date(now).toISOString();
  try {
    const { version, notes } = await fetchLatest({ slug, env, fetcher });
    const state = writeState(file, { lastCheckAt, latestVersion: version, lastError: null });
    return { status: isNewer(version, current) ? "available" : "current", version, notes, state };
  } catch (error) {
    const cause = describe(error);
    const state = writeState(file, { lastCheckAt, lastError: `check failed: ${cause}` });
    return { status: "failed", cause, state };
  }
}

// Where this copy came from: install.sh/install.ps1 (<home>/app/release-*/node_modules/<pkg>),
// npm (some other node_modules), or a source checkout.
export function installKind(packageRoot) {
  const parent = path.dirname(packageRoot);
  if (path.basename(parent) !== "node_modules") return { kind: "source" };
  const release = path.dirname(parent);
  if (path.basename(release).startsWith("release-") && path.basename(path.dirname(release)) === "app") {
    return { kind: "home", home: path.dirname(path.dirname(release)), release };
  }
  return { kind: "npm" };
}

// Release folders next to the running one, newest first (the rollback copy, if any).
function otherReleases(release) {
  const app = path.dirname(release);
  return readdirSync(app)
    .filter(name => name.startsWith("release-") || name.startsWith(".rollback-"))
    .map(name => path.join(app, name))
    .filter(full => full !== release && statSync(full).isDirectory())
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
}

// The rollback copy goes once the new version has run successfully, or 7 days after the update.
export function pruneRollback(packageRoot, { succeeded = false, now = Date.now() } = {}) {
  const kind = installKind(packageRoot);
  if (kind.kind !== "home") return;
  try {
    const expired = now - statSync(kind.release).mtimeMs > ROLLBACK_MAX_AGE_MS;
    if (!succeeded && !expired) return;
    for (const other of otherReleases(kind.release)) rmSync(other, { recursive: true, force: true });
  } catch { /* tried again on the next run */ }
}

export function rollback(packageRoot) {
  const kind = installKind(packageRoot);
  if (kind.kind !== "home") {
    throw new UpdateError(kind.kind === "npm"
      ? "rollback is not available for npm installs; install the earlier release's .tgz with npm install --global"
      : "rollback is not available for a source checkout");
  }
  const previous = otherReleases(kind.release).find(full => path.basename(full).startsWith("release-"));
  if (!previous) throw new UpdateError("no previous release is kept; it is removed after the new version has run once");
  // The shim points at this folder, so the previous release moves into its place.
  const parked = path.join(path.dirname(kind.release), `.rollback-${randomUUID()}`);
  renameSync(kind.release, parked);
  try {
    renameSync(previous, kind.release);
  } catch (error) {
    renameSync(parked, kind.release);
    throw error;
  }
  rmSync(parked, { recursive: true, force: true });
  return packageVersion(packageRoot);
}

// The folder of the shim that runs this release, so a custom UTCU_BIN_DIR keeps working after `update`.
function shimDir(release, env, platform) {
  const name = platform === "win32" ? `${TOOL}.cmd` : TOOL;
  for (const dir of String(env.PATH ?? "").split(path.delimiter).filter(Boolean)) {
    try {
      const text = readFileSync(path.join(dir, name), "utf8");
      if (text.includes("UTCU_NPM_SHIM") && text.includes(path.basename(release))) return dir;
    } catch { /* not here */ }
  }
  return null;
}

function sha256For(sums, name) {
  for (const line of String(sums).split(/\r?\n/)) {
    const match = /^([0-9a-fA-F]{64}) [ *](.+)$/.exec(line.trim());
    if (match && match[2] === name) return match[1].toLowerCase();
  }
  return null;
}

export function verifyChecksum(bytes, sums, name) {
  const expected = sha256For(sums, name);
  if (!expected) throw new UpdateError(`SHA256SUMS has no entry for ${name}; nothing was installed`);
  if (createHash("sha256").update(bytes).digest("hex") !== expected) {
    throw new UpdateError(`checksum mismatch for ${name}; nothing was installed`);
  }
}

async function download(url, fetcher) {
  const response = await fetcher(url, { headers: { "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS) });
  if (!response.ok) throw new UpdateError(`download failed: ${url} (HTTP ${response.status})`);
  return Buffer.from(await response.arrayBuffer());
}

function runCommand(command, args, { env, cwd, stdio = "inherit", shell = false }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, cwd, stdio, shell, windowsHide: true });
    child.once("error", reject);
    child.once("exit", (code, signal) => (code === 0
      ? resolve()
      : reject(new UpdateError(`${path.basename(command)} exited with ${signal ?? code}`))));
  });
}

// Downloads into a private temp folder that is removed on success and on failure. Each file is checked
// against the release SHA256SUMS before it runs. install.sh / install.ps1 then check the tarball against
// the same SHA256SUMS before they replace anything; npm installs the verified local tarball.
export async function installUpdate({
  version,
  packageRoot = ownRoot,
  env = process.env,
  platform = process.platform,
  slug = releaseSlug(packageRoot),
  fetcher = globalThis.fetch,
  run = runCommand,
  tmpRoot = tmpdir(),
  stdio = "inherit",
}) {
  const kind = installKind(packageRoot);
  if (kind.kind === "source") throw new UpdateError("this copy runs from a source checkout; update it with git pull");
  const base = String(env.UTCU_RELEASE_BASE || (slug ? `https://github.com/${slug}/releases/download/v${version}` : "")).replace(/\/+$/, "");
  if (!base) throw new UpdateError("the package metadata names no GitHub repository");
  const dir = mkdtempSync(path.join(tmpRoot, `${TOOL}-update-`));
  try {
    const sums = (await download(`${base}/SHA256SUMS`, fetcher)).toString("utf8");
    const name = kind.kind === "npm" ? `${TOOL}-${version}.tgz` : (platform === "win32" ? "install.ps1" : "install.sh");
    const bytes = await download(`${base}/${name}`, fetcher);
    verifyChecksum(bytes, sums, name);
    writeFileSync(path.join(dir, name), bytes, { mode: 0o700 });
    if (kind.kind === "npm") {
      const quiet = { ...env, npm_config_update_notifier: "false", npm_config_fund: "false", npm_config_audit: "false" };
      await run("npm", ["install", "--global", `./${name}`], { env: quiet, cwd: dir, stdio, shell: platform === "win32" });
    } else {
      const pinned = { ...env, UTCU_HOME: kind.home, UTCU_VERSION: version, UTCU_RELEASE_BASE: base };
      const bin = env.UTCU_BIN_DIR || shimDir(kind.release, env, platform);
      if (bin) pinned.UTCU_BIN_DIR = bin;
      if (platform === "win32") {
        await run("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(dir, name)], { env: pinned, stdio });
      } else {
        await run("/bin/sh", [path.join(dir, name), ...(platform === "darwin" ? ["--npm"] : [])], { env: pinned, stdio });
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Keeps one log file at most MAX_LOG_BYTES; the older half goes when it is full.
export function appendLog(file, line, limit = MAX_LOG_BYTES) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  appendFileSync(file, `${new Date().toISOString()} ${line}\n`, { mode: 0o600 });
  boundLog(file, limit);
}

export function boundLog(file, limit = MAX_LOG_BYTES) {
  let size;
  try { size = statSync(file).size; } catch { return; }
  if (size > limit) writeFileSync(file, readFileSync(file).subarray(size - Math.floor(limit / 2)), { mode: 0o600 });
}

// The detached background process: check, and install when automatic updates are on.
export async function refresh({
  packageRoot = ownRoot,
  env = process.env,
  platform = process.platform,
  fetcher = globalThis.fetch,
  install = installUpdate,
  now = Date.now(),
} = {}) {
  const file = statePath(env, platform);
  const current = packageVersion(packageRoot);
  const result = await checkNow({ file, slug: releaseSlug(packageRoot), current, env, fetcher, now });
  const { state } = result;
  if (result.status !== "available" || !state.autoInstall || state.autoFailedVersion === result.version) return result;
  if (state.skippedVersion && !isNewer(result.version, state.skippedVersion)) return result;
  if (installKind(packageRoot).kind === "source") return result;
  const log = logPath(env, platform);
  appendLog(log, `installing ${result.version} (you have ${current})`);
  const fd = openSync(log, "a", 0o600);
  try {
    try { setPriority(19); } catch { /* best effort */ }
    await install({ version: result.version, packageRoot, env, platform, fetcher, stdio: ["ignore", fd, fd] });
    closeSync(fd);
    appendLog(log, `installed ${result.version}; it applies the next time ${TOOL} starts`);
    writeState(file, { autoFailedVersion: null });
  } catch (error) {
    closeSync(fd);
    const cause = describe(error);
    appendLog(log, `install of ${result.version} failed: ${cause}`);
    writeState(file, { autoFailedVersion: result.version, lastError: `automatic install of ${result.version} failed: ${cause}` });
  }
  return result;
}

// Called by the launcher after a native command. Never waits on the network: a due check starts a
// detached process, and the notice uses what the last check recorded.
export function afterCommand({
  packageRoot,
  argv = [],
  code = 0,
  env = process.env,
  platform = process.platform,
  interactive = false,
  errorOutput = process.stderr,
  spawnFn = spawn,
  now = Date.now(),
}) {
  if (!env.UTCU_INSTALL_CHECK) pruneRollback(packageRoot, { succeeded: code === 0, now });
  if (code !== 0 || argv[0] === "mcp" || argv.includes("--json") || !checksAllowed({ env, interactive })) return;
  const file = statePath(env, platform);
  const state = readState(file);
  const current = packageVersion(packageRoot);
  if (checkDue(state, now)) {
    // Claim today's check first, so concurrent commands do not start more than one.
    writeState(file, { lastCheckAt: new Date(now).toISOString() });
    try {
      const child = spawnFn(process.execPath, [fileURLToPath(import.meta.url), "refresh"], {
        env, detached: true, stdio: "ignore", windowsHide: true,
      });
      child.on?.("error", () => {});
      child.unref?.();
    } catch (error) {
      writeState(file, { lastError: `check failed: ${describe(error)}` });
    }
  }
  if (!noticeDue(state, current, now)) return;
  errorOutput.write(`${noticeText(current, state.latestVersion, env)}\n`);
  writeState(file, { lastShownVersion: state.latestVersion, lastShownAt: new Date(now).toISOString() });
}

function parseUpdateArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (["--check", "--skip", "--rollback"].includes(arg)) options[arg.slice(2)] = true;
    else if (arg === "--auto" && ["on", "off", "status"].includes(argv[i + 1])) options.auto = argv[++i];
    else if (arg === "-h" || arg === "--help") options.help = true;
    else throw new UpdateError(`unknown update option: ${arg} (see: ${TOOL} help update)`, 2);
  }
  if (Object.keys(options).length > 1) throw new UpdateError("use one update option at a time", 2);
  return options;
}

export async function updateCommand(argv, {
  packageRoot = ownRoot,
  env = process.env,
  platform = process.platform,
  input = process.stdin,
  output = process.stdout,
  errorOutput = process.stderr,
  interactive = Boolean(input.isTTY && output.isTTY),
  fetcher = globalThis.fetch,
  install = installUpdate,
  ask,
  now = Date.now(),
} = {}) {
  // One line reader for both questions, so an answer typed ahead is not lost.
  let lines;
  ask ??= async question => {
    lines ??= readline.createInterface({ input, output, terminal: false });
    return (await lines.question(question)).trim().toLowerCase();
  };
  try {
    return await runUpdate(argv, { packageRoot, env, platform, output, errorOutput, interactive, fetcher, install, ask, now });
  } finally {
    lines?.close();
  }
}

async function runUpdate(argv, { packageRoot, env, platform, output, errorOutput, interactive, fetcher, install, ask, now }) {
  const options = parseUpdateArgs(argv);
  const say = text => output.write(`${text}\n`);
  if (options.help) {
    say(updatesHelp);
    return 0;
  }
  const file = statePath(env, platform);
  const current = packageVersion(packageRoot);
  if (options.auto) {
    if (options.auto !== "status") writeState(file, { autoInstall: options.auto === "on", autoFailedVersion: null });
    say(`automatic updates: ${readState(file).autoInstall ? "on" : "off"}`);
    return 0;
  }
  if (options.rollback) {
    say(`Rolled back to ${TOOL} ${rollback(packageRoot)}.`);
    return 0;
  }
  const result = await checkNow({ file, slug: releaseSlug(packageRoot), current, env, fetcher, now });
  if (result.status === "failed") {
    errorOutput.write(`${TOOL} update: check failed: ${result.cause}\n`);
    return 1;
  }
  if (result.status !== "available") {
    say(`${TOOL} ${current} is current`);
    return 0;
  }
  if (options.check) {
    say(`${TOOL} ${result.version} available (you have ${current})`);
    return 10;
  }
  if (options.skip) {
    writeState(file, { skippedVersion: result.version });
    say(`Skipped ${result.version}. A newer release will notify again.`);
    return 0;
  }
  say(`${TOOL} ${current} → ${result.version}`);
  if (result.notes) say(result.notes);
  if (interactive && !["", "y", "yes"].includes(await ask(`Install ${result.version} now? [Y/n] `))) return 0;
  try {
    await install({ version: result.version, packageRoot, env, platform, fetcher });
  } catch (error) {
    writeState(file, { lastError: `install of ${result.version} failed: ${describe(error)}` });
    throw error;
  }
  say(`Installed ${result.version}. It applies the next time ${TOOL} starts.`);
  const state = readState(file);
  if (interactive && !state.autoInstall && !state.autoAsked) {
    const answer = await ask("Install future updates automatically? [y/N] ");
    writeState(file, { autoInstall: ["y", "yes"].includes(answer), autoAsked: true });
  }
  return 0;
}

export const updatesHelp = `Usage:
  ${TOOL} update                 Show the newer release and install it after verification.
  ${TOOL} update --check         Report only: exit 0 current, 10 update available, 1 check failed.
  ${TOOL} update --skip          Hide this version's notice until a newer one appears.
  ${TOOL} update --auto on|off|status
                                 Install future updates automatically (off by default).
  ${TOOL} update --rollback      Go back to the previous release (install.sh installs only).

Checks are anonymous and at most daily. ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK=1 or
\`${TOOL} config set updates.check false\` turns them off. See docs/updates.md.`;

if (process.argv[2] === "refresh" && process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await refresh().catch(() => {});
}
