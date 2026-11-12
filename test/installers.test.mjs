// Tests for the one-step installers and the release finalize step (scripts/install.sh, install.ps1,
// stamp-installers.sh, finalize-release.sh). The PowerShell helper tests run when `pwsh` is on PATH;
// scripts/test-install.sh --pwsh-container runs them (and a full install) in the pinned image otherwise.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const read = (p) => readFileSync(join(root, p), "utf8");
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: "utf8", ...opts });
const cleanEnv = () => {
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (k.startsWith("ULTRATERM_COMPUTER_USE_") || k.startsWith("UTCU_")) delete env[k];
  return env;
};
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");

// A scratch repo holding copies of the release scripts, so remotes and dist/ can be set freely.
function scratchRepo(remote) {
  const dir = mkdtempSync(join(tmpdir(), "utcu-inst-"));
  mkdirSync(join(dir, "scripts"));
  for (const f of ["stamp-installers.sh", "finalize-release.sh", "install.sh", "install.ps1", "install-ultraterm-computer-use.sh"]) {
    copyFileSync(join(root, "scripts", f), join(dir, "scripts", f));
  }
  sh("git", ["init", "-q", dir]);
  if (remote) sh("git", ["-C", dir, "remote", "add", "origin", remote]);
  return dir;
}

test("stamping handles https, ssh and .git remotes and leaves no placeholder", () => {
  for (const [remote, slug] of [
    ["https://github.com/acme/tool.git", "acme/tool"],
    ["https://github.com/acme/tool", "acme/tool"],
    ["git@github.com:acme/tool.git", "acme/tool"],
    ["ssh://git@github.com/acme/tool.git", "acme/tool"],
  ]) {
    const dir = scratchRepo(remote);
    const out = join(dir, "out");
    const r = sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env: cleanEnv() });
    assert.equal(r.status, 0, `${remote}: ${r.stderr}`);
    for (const f of ["install.sh", "install.ps1", "install-ultraterm-computer-use.sh"]) {
      const text = readFileSync(join(out, f), "utf8");
      assert.ok(!text.includes("your-org/ultraterm-computer-use"), `${f} kept the placeholder`);
      assert.ok(text.includes(`${slug}`), `${f} lacks ${slug}`);
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

test("stamping fails without a GitHub owner/repo, and honours the override", () => {
  const dir = scratchRepo("/some/local/path");
  const out = join(dir, "out");
  let r = sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env: cleanEnv() });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /cannot tell the GitHub owner\/repo/);
  r = sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env: { ...cleanEnv(), ULTRATERM_COMPUTER_USE_RELEASE_REPO: "your-org/ultraterm-computer-use" } });
  assert.notEqual(r.status, 0, "the placeholder itself must be refused");
  r = sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env: { ...cleanEnv(), ULTRATERM_COMPUTER_USE_RELEASE_REPO: "o/r" } });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(join(out, "install.ps1"), "utf8"), /'o\/r'/);
  rmSync(dir, { recursive: true, force: true });
});

test("the stamped installers still run (the stamp cannot break an in-script guard)", () => {
  const dir = scratchRepo("https://github.com/acme/tool.git");
  const out = join(dir, "out");
  assert.equal(sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env: cleanEnv() }).status, 0);
  const r = sh("sh", [join(out, "install.sh"), "--help"], { env: cleanEnv() });
  assert.equal(r.status, 0, r.stderr);
  rmSync(dir, { recursive: true, force: true });
});

test("an unstamped source copy refuses to download; the stamp cannot rewrite the guard", () => {
  const env = cleanEnv();
  let r = sh("sh", [join(root, "scripts/install.sh"), "--npm"], { env });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /source template, not a release asset/);
  r = sh("bash", [join(root, "scripts/install-ultraterm-computer-use.sh")], { env });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /source template, not a release asset/);
  for (const f of ["install.sh", "install.ps1", "install-ultraterm-computer-use.sh"]) {
    assert.match(read(`scripts/${f}`), /your-org\/\*/, `${f} has the owner-wildcard guard`);
  }
  // A stamped copy keeps the guard text and works; the test base override is still honoured on the template.
  const dir = scratchRepo("https://github.com/acme/tool.git");
  const out = join(dir, "out");
  assert.equal(sh("bash", [join(dir, "scripts/stamp-installers.sh"), out], { env }).status, 0);
  for (const f of ["install.sh", "install.ps1", "install-ultraterm-computer-use.sh"]) {
    assert.match(readFileSync(join(out, f), "utf8"), /your-org\/\*/, `${f}: stamp rewrote the guard`);
  }
  r = sh("sh", [join(out, "install.sh"), "--npm"], { env: { ...env, UTCU_RELEASE_BASE: "file:///nonexistent" } });
  assert.doesNotMatch(r.stderr, /source template/);
  r = sh("sh", [join(out, "install.sh"), "--npm"], { env: { ...env, HOME: dir, UTCU_RELEASE_BASE: "" } });
  assert.doesNotMatch(r.stderr, /source template/, "stamped copy passes the guard");
  rmSync(dir, { recursive: true, force: true });
});

test("install.sh never nests a release inside an existing folder and prints the piped npm route", () => {
  const text = read("scripts/install.sh");
  assert.ok(!/release-\$VERSION-\$\$/.test(text), "no $$ release folder name");
  assert.match(text, /mktemp -d "\$APP\/release-/);
  assert.match(text, /sh -s -- --npm/);
});

test("the signed release build finalizes with --require-all once the tgz exists", () => {
  const text = read("scripts/build-ultraterm-computer-use-release.sh");
  assert.match(text, /finalize-release\.sh" "\$version" --require-all/);
});

test("finalize writes ONE combined SHA256SUMS in either build order", () => {
  for (const order of ["npm-first", "pkg-first"]) {
    const dir = scratchRepo("https://github.com/acme/tool.git");
    const v = "1.2.3";
    const folder = join(dir, "dist/release/ultraterm-computer-use", v);
    const npmDir = join(dir, "dist/release/npm");
    const addPkg = () => {
      mkdirSync(folder, { recursive: true });
      writeFileSync(join(folder, "UltraTerm-Computer-Use.pkg"), "pkg");
      writeFileSync(join(folder, "UltraTerm-Computer-Use.zip"), "zip");
      writeFileSync(join(folder, "release-manifest.json"), JSON.stringify({ product: "UltraTerm Computer Use", teamIdentifier: "ABC1234567", artifacts: {} }));
    };
    const addNpm = () => { mkdirSync(npmDir, { recursive: true }); writeFileSync(join(npmDir, `ultraterm-computer-use-${v}.tgz`), "tgz"); };
    const finalize = (...a) => sh("bash", [join(dir, "scripts/finalize-release.sh"), v, ...a], { env: cleanEnv() });
    if (order === "npm-first") { addNpm(); assert.equal(finalize().status, 0); addPkg(); } else { addPkg(); assert.equal(finalize().status, 0); addNpm(); }
    const r = finalize("--require-all");
    assert.equal(r.status, 0, r.stderr);
    const lines = readFileSync(join(folder, "SHA256SUMS"), "utf8").trim().split("\n");
    const names = lines.map((l) => l.split(/\s+/)[1]).sort();
    assert.deepEqual(names, [`ultraterm-computer-use-${v}.tgz`, "UltraTerm-Computer-Use.pkg", "UltraTerm-Computer-Use.zip", "install-ultraterm-computer-use.sh", "install.ps1", "install.sh", "release-manifest.json"].sort(), order);
    for (const l of lines) { const [h, n] = l.split(/\s+/); assert.equal(h, sha(join(folder, n)), `${order}: hash of ${n}`); }
    const manifest = JSON.parse(readFileSync(join(folder, "release-manifest.json"), "utf8"));
    assert.equal(manifest.teamIdentifier, "ABC1234567", "pkg manifest fields are kept");
    assert.equal(manifest.version, v);
    assert.ok(manifest.artifacts[`ultraterm-computer-use-${v}.tgz`]);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("finalize --require-all fails while the pkg or tgz is missing", () => {
  const dir = scratchRepo("https://github.com/acme/tool.git");
  const r = sh("bash", [join(dir, "scripts/finalize-release.sh"), "1.2.3", "--require-all"], { env: cleanEnv() });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /missing .*UltraTerm-Computer-Use\.pkg/);
  rmSync(dir, { recursive: true, force: true });
});

test("neither build script deletes the other's output or writes its own SHA256SUMS", () => {
  const pkgScript = read("scripts/release-package.sh");
  assert.ok(!/rm -rf "\$\{release_dir\}"/.test(pkgScript), "release-package.sh must not wipe dist/release");
  assert.match(pkgScript, /finalize-release\.sh/);
  const mac = read("scripts/build-ultraterm-computer-use-release.sh");
  assert.ok(!/> SHA256SUMS/.test(mac) && !/SHA256SUMS"\)\.write_text/.test(pkgScript), "only finalize-release.sh writes SHA256SUMS");
  assert.match(mac, /finalize-release\.sh/);
});

// ---- install.sh against a fake package served from file:// ----
function fakeRelease(version = "9.9.9") {
  const dir = mkdtempSync(join(tmpdir(), "utcu-rel-"));
  const pkg = join(dir, "pkgsrc/package");
  mkdirSync(join(pkg, "bin"), { recursive: true });
  writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "ultraterm-computer-use", version, bin: { "ultraterm-computer-use": "bin/ultraterm-computer-use" } }, null, 2));
  writeFileSync(join(pkg, "bin/ultraterm-computer-use"), `#!/usr/bin/env node\nif (process.argv[2] === "doctor") console.log("doctor ok"); else console.log("${version}");\n`);
  chmodSync(join(pkg, "bin/ultraterm-computer-use"), 0o755);
  const rel = join(dir, "rel"); mkdirSync(rel);
  const name = `ultraterm-computer-use-${version}.tgz`;
  assert.equal(sh("tar", ["-czf", join(rel, name), "-C", join(dir, "pkgsrc"), "package"]).status, 0);
  writeFileSync(join(rel, "SHA256SUMS"), `${sha(join(rel, name))}  ${name}\n`);
  return { dir, rel, version };
}
const runInstall = (f, home, extra = [], env = {}) =>
  sh("sh", [join(root, "scripts/install.sh"), ...(process.platform === "darwin" ? ["--npm"] : []), ...extra], {
    env: { ...cleanEnv(), HOME: home, UTCU_HOME: join(home, ".utcu"), UTCU_BIN_DIR: join(home, "bin"), UTCU_RELEASE_BASE: `file://${f.rel}`, ...env },
  });

test("install.sh: shim embeds the absolute node, carries the marker, re-run keeps one working release", () => {
  const f = fakeRelease();
  const home = join(f.dir, "home"); mkdirSync(home);
  let r = runInstall(f, home);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const shim = readFileSync(join(home, "bin/ultraterm-computer-use"), "utf8");
  assert.match(shim, /^# UTCU_NPM_SHIM$/m);
  assert.match(shim, /^exec "\/[^"]*node" "/m, "shim must run an absolute node path, not bare node");
  r = runInstall(f, home);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(readdirSync(join(home, ".utcu/app")).filter((n) => n.startsWith("release-")).length, 1);
  assert.equal(sh(join(home, "bin/ultraterm-computer-use"), ["--version"], { env: { ...cleanEnv(), HOME: home } }).stdout.trim(), f.version);
  rmSync(f.dir, { recursive: true, force: true });
});

test("install.sh: a foreign command is refused before any release folder is moved in", () => {
  const f = fakeRelease();
  const home = join(f.dir, "home"); mkdirSync(join(home, "bin"), { recursive: true });
  writeFileSync(join(home, "bin/ultraterm-computer-use"), "#!/bin/sh\necho mine\n", { mode: 0o755 });
  const r = runInstall(f, home);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /refusing to replace existing command/);
  assert.equal(readFileSync(join(home, "bin/ultraterm-computer-use"), "utf8"), "#!/bin/sh\necho mine\n");
  const app = join(home, ".utcu/app");
  assert.ok(!existsSync(app) || readdirSync(app).length === 0, "a release folder was left behind");
  rmSync(f.dir, { recursive: true, force: true });
});

test("install.sh: the macOS route names the versioned release asset and a mktemp file", () => {
  const text = read("scripts/install.sh");
  assert.ok(!/raw\.githubusercontent/.test(text), "must not point at a main-branch script");
  assert.ok(!/\/tmp\/install-ultraterm/.test(text), "must not use a fixed /tmp path");
  const home = mkdtempSync(join(tmpdir(), "utcu-mac-"));
  const r = sh("sh", [join(root, "scripts/install.sh")], { env: { ...cleanEnv(), HOME: home, UTCU_HOME: join(home, "h"), UTCU_VERSION: "1.2.3", UTCU_RELEASE_BASE: "https://github.com/acme/tool/releases/download/v1.2.3" } });
  if (process.platform === "darwin") {
    assert.match(r.stdout, /mktemp/);
    assert.match(r.stdout, /releases\/download\/v1\.2\.3\/install-ultraterm-computer-use\.sh/);
  }
  rmSync(home, { recursive: true, force: true });
});

// ---- install.ps1: static guards for Windows-only code, plus helper tests under PowerShell 7 ----
test("install.ps1 static guards: bad Windows patterns must not return", () => {
  const ps = read("scripts/install.ps1");
  const code = ps.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
  assert.ok(!/-Encoding Ascii/i.test(code), ".cmd shims must not be written with -Encoding Ascii");
  assert.match(code, /OEMCodePage/);
  assert.match(code, /%~dp0/);
  assert.ok(!/Set-Content[^\n]*\$shim/.test(code), "shims are written with WriteAllText, not Set-Content");
  assert.match(code, /npm\.cmd/);
  assert.ok(!/\$npmBin\s*=\s*'npm'/.test(code) && !/Get-Command npm\b/.test(code), "never resolve a bare npm (npm.ps1 is blocked by Restricted)");
  assert.match(code, /Tls12/);
  assert.match(code, /\$ProgressPreference = 'SilentlyContinue'/);
  assert.match(code, /GetUnresolvedProviderPathFromPSPath\(\$homeDir\)/);
  assert.match(code, /GetUnresolvedProviderPathFromPSPath\(\$binDir\)/);
  assert.ok(!/^\s*exit\b/m.test(code), "never exit the user's shell");
  const natives = code.split("\n").filter((l) => /2>&1/.test(l));
  assert.ok(natives.every((l) => /ForEach-Object/.test(l)), "captured native calls go through Invoke-Native only");
  assert.match(code, /\$ErrorActionPreference = 'Continue'/);
  assert.ok(!/Move-Item[^\n]*\$inner/.test(code.replace(/Move-Item -Path \$inner\.FullName -Destination \$nodeTmp/, "")), "no other move from the unpack folder");
  assert.match(code, /\$nodeTmp = Join-Path \$runtimeDir/, "Node is unpacked under the tool home, not %TEMP%");
  assert.match(code, /Join-Path \$appDir \("release-\$version-"/, "each install gets its own release folder");
  assert.ok(!/Remove-Item[^\n]*\$rel\b(?!\w)/.test(code.replace(/-ne \$rel\)[^\n]*/, "")), "never delete the release just installed");
  assert.match(code, /UTCU_NPM_SHIM/);
  assert.match(code, /Assert-ShimOurs -Shim \$shim/);
  assert.match(code, /-not \$env:UTCU_RELEASE_BASE -and \$repo -like 'your-org\/\*'/, "source-template guard");
  assert.ok(!/your-org/.test(ps.split("\n").filter((l) => /\$repo\s*=/.test(l)).join("").replace("your-org/ultraterm-computer-use", "")), "placeholder only as the whole owner/repo");
  assert.ok(code.trimEnd().endsWith("Install-UltraTermComputerUse"), "the file ends with the single call");
});

const pwsh = sh("pwsh", ["-NoProfile", "-c", "$PSVersionTable.PSVersion.Major"]);
test("install.ps1 helpers under PowerShell 7", { skip: pwsh.status !== 0 && "pwsh not on PATH (test-install.sh --pwsh-container runs this)" }, () => {
  const r = sh("pwsh", ["-NoProfile", "-File", join(root, "test/installer-units.ps1"), join(root, "scripts/install.ps1")]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("install.ps1 writes the user Path through the registry, never the expanding .NET accessors", () => {
  const ps = read("scripts/install.ps1");
  assert.ok(!/SetEnvironmentVariable\(\s*'Path'/i.test(ps), "must not call SetEnvironmentVariable('Path'");
  assert.ok(!/GetEnvironmentVariable\(\s*'Path'/i.test(ps), "must not call GetEnvironmentVariable('Path'");
  assert.match(ps, /DoNotExpandEnvironmentNames/);
  assert.match(ps, /OpenSubKey\('Environment', \$true\)/);
  assert.match(ps, /GetValueKind\('Path'\)/);
});
