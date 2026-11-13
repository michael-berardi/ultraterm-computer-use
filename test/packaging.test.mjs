import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  assertNoPlaceholders,
  findPlaceholders,
  placeholderSlug,
  requireSlug,
  resolveReleaseSlug,
  slugFromRemoteUrl,
  stagedAppHasLockedUse,
  stampStagedPackage,
} from "../scripts/npm/build-packages.mjs";

test("slugFromRemoteUrl parses https and ssh forms with or without .git", () => {
  for (const url of [
    "https://github.com/acme/tool.git",
    "https://github.com/acme/tool",
    "git@github.com:acme/tool.git",
    "git@github.com:acme/tool",
    "ssh://git@github.com/acme/tool.git",
    "https://github.com/acme/tool/",
  ]) {
    assert.equal(slugFromRemoteUrl(url), "acme/tool", url);
  }
  assert.equal(slugFromRemoteUrl("https://example.com/acme/tool.git"), "");
  assert.equal(slugFromRemoteUrl(""), "");
});

test("resolveReleaseSlug prefers the env override over the remote", () => {
  const remoteUrl = "https://github.com/acme/tool.git";
  assert.equal(resolveReleaseSlug({ env: { ULTRATERM_COMPUTER_USE_RELEASE_REPO: "own/repo" }, remoteUrl }), "own/repo");
  assert.equal(resolveReleaseSlug({ env: {}, remoteUrl }), "acme/tool");
  assert.equal(resolveReleaseSlug({ env: { ULTRATERM_COMPUTER_USE_RELEASE_REPO: "bad slug" }, remoteUrl }), "");
});

test("requireSlug fails release builds with a named error and lets debug builds pass", () => {
  assert.throws(() => requireSlug({ configuration: "release", env: {}, remoteUrl: "" }), /ULTRATERM_COMPUTER_USE_RELEASE_REPO/);
  assert.throws(
    () => requireSlug({ configuration: "release", env: { ULTRATERM_COMPUTER_USE_RELEASE_REPO: placeholderSlug } }),
    /still the placeholder/,
  );
  assert.equal(requireSlug({ configuration: "debug", env: {}, remoteUrl: "" }), "");
  assert.equal(requireSlug({ configuration: "release", env: {}, remoteUrl: "git@github.com:acme/tool.git" }), "acme/tool");
});

test("stampStagedPackage replaces the placeholder in text files and skips binaries", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "packaging-test-"));
  try {
    mkdirSync(path.join(root, "skills"), { recursive: true });
    mkdirSync(path.join(root, "dist"), { recursive: true });
    writeFileSync(path.join(root, "package.json"), `{"homepage":"https://github.com/${placeholderSlug}"}`);
    writeFileSync(path.join(root, "skills", "a.md"), `npx skills add ${placeholderSlug}`);
    writeFileSync(path.join(root, "dist", "bin"), Buffer.concat([Buffer.from([0]), Buffer.from(placeholderSlug)]));
    assert.deepEqual(findPlaceholders(root).sort(), ["package.json", path.join("skills", "a.md")]);
    assert.throws(() => assertNoPlaceholders(root), /survived/);
    assert.equal(stampStagedPackage(root, "acme/tool"), 2);
    assert.equal(readFileSync(path.join(root, "package.json"), "utf-8"), '{"homepage":"https://github.com/acme/tool"}');
    assert.doesNotThrow(() => assertNoPlaceholders(root));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("stagedAppHasLockedUse is true only when Contents/Resources/LockedUse exists", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "packaging-test-"));
  try {
    assert.equal(stagedAppHasLockedUse(root), false);
    mkdirSync(path.join(root, "Contents", "Resources", "LockedUse"), { recursive: true });
    assert.equal(stagedAppHasLockedUse(root), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the package build runs when its script is reached through a symlinked folder", () => {
  // macOS temp folders sit behind /var -> /private/var; a URL string comparison skipped the build there.
  const join = path.join, tmpdir = os.tmpdir, root = fileURLToPath(new URL("..", import.meta.url));
  const real = mkdtempSync(join(tmpdir(), "packaging-real-"));
  const linkParent = mkdtempSync(join(tmpdir(), "packaging-link-"));
  try {
    mkdirSync(join(real, "scripts/npm"), { recursive: true });
    cpSync(join(root, "scripts/npm/build-packages.mjs"), join(real, "scripts/npm/build-packages.mjs"));
    const link = join(linkParent, "repo");
    symlinkSync(real, link);
    const run = spawnSync(process.execPath, [join(link, "scripts/npm/build-packages.mjs"), "--no-such-option"], { encoding: "utf8" });
    assert.notEqual(run.status, 0, "an unknown option must be reported, which proves main() ran");
    assert.match(run.stderr + run.stdout, /no-such-option|Unknown|Usage/i);
  } finally {
    rmSync(real, { recursive: true, force: true });
    rmSync(linkParent, { recursive: true, force: true });
  }
});
