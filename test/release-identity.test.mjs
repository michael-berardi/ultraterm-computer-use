import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const release = join(root, 'scripts/build-ultraterm-computer-use-release.sh');
const install = join(root, 'scripts/install-ultraterm-computer-use.sh');
const bundle = 'org.examplecompany.computer-use';
const team = 'ABC1234567';
const cleanEnv = () => {
  const env = { ...process.env };
  for (const key of Object.keys(env)) if (key.startsWith('ULTRATERM_COMPUTER_USE_')) delete env[key];
  return env;
};
const run = (script, args, env) => spawnSync('bash', [script, ...args], { encoding: 'utf8', env });

test('release rejects unset and placeholder identities before building', () => {
  for (const [id, t, message] of [
    ['', '', 'ULTRATERM_COMPUTER_USE_BUNDLE_ID'],
    ['com.example.ultraterm-computer-use', team, 'ULTRATERM_COMPUTER_USE_BUNDLE_ID'],
    [bundle, '', 'ULTRATERM_COMPUTER_USE_TEAM_ID'],
    [bundle, 'YOUR_TEAM_ID', 'ULTRATERM_COMPUTER_USE_TEAM_ID'],
  ]) {
    const r = run(release, [], { ...cleanEnv(), ULTRATERM_COMPUTER_USE_BUNDLE_ID: id, ULTRATERM_COMPUTER_USE_TEAM_ID: t });
    assert.notEqual(r.status, 0); assert.match(r.stderr, new RegExp(message));
  }
});

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'identity-test-'));
  const bin = join(dir, 'bin'); mkdirSync(bin);
  const cmd = (name, body) => writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  cmd('pkgutil', `if [[ "$1" == --check-signature ]]; then echo 'Developer ID Installer: Synthetic (${team})'; else mkdir -p "$3/UltraTerm Computer Use.app"; fi`);
  cmd('spctl', 'exit 0'); cmd('installer', 'exit 0');
  cmd('codesign', `if [[ "$1" == -dv ]]; then printf 'Identifier=${bundle}\\nTeamIdentifier=${team}\\n'; else echo 'designated => identifier "${bundle}" and certificate leaf[subject.OU] = "${team}"'; fi`);
  cmd('sudo', 'echo REACHED_INSTALL >&2; exit 42');
  cmd('curl', 'while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; https:*) url="$1"; shift;; *) shift;; esac; done\ncp "$FIXTURE/${url##*/}" "$out"');
  const pkg = 'synthetic package';
  const manifest = JSON.stringify({ bundleIdentifier: bundle, teamIdentifier: team });
  writeFileSync(join(dir, 'UltraTerm-Computer-Use.pkg'), pkg);
  writeFileSync(join(dir, 'release-manifest.json'), manifest);
  const hash = s => createHash('sha256').update(s).digest('hex');
  writeFileSync(join(dir, 'SHA256SUMS'), `${hash(pkg)}  UltraTerm-Computer-Use.pkg\n${hash(manifest)}  release-manifest.json\n`);
  writeFileSync(join(dir, 'latest'), JSON.stringify({ assets: ['UltraTerm-Computer-Use.pkg', 'release-manifest.json', 'SHA256SUMS'].map(name => ({ name, browser_download_url: `https://fixture/${name}` })) }));
  const env = { ...cleanEnv(), PATH: `${bin}:${process.env.PATH}`, FIXTURE: dir };
  return { dir, env };
}

test('installer verifies manifest and uses its identity for candidate signature', () => {
  const { dir, env } = fixture();
  try {
    let r = run(install, [], env);
    assert.equal(r.status, 42, r.stderr); assert.match(r.stderr, /REACHED_INSTALL/);
    r = run(install, [], { ...env, ULTRATERM_COMPUTER_USE_BUNDLE_ID: 'org.other.app' });
    assert.notEqual(r.status, 42); assert.match(r.stderr, /wrong bundle identifier/);
    writeFileSync(join(dir, 'release-manifest.json'), '{}');
    r = run(install, [], env);
    assert.notEqual(r.status, 42); assert.match(r.stderr, /checksum missing or mismatched/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('local installer fails closed without identity and accepts explicit identity', () => {
  const { dir, env } = fixture();
  try {
    const args = ['--local', join(dir, 'UltraTerm-Computer-Use.pkg')];
    let r = run(install, args, env);
    assert.notEqual(r.status, 0); assert.match(r.stderr, /release identity error/);
    r = run(install, args, { ...env, ULTRATERM_COMPUTER_USE_BUNDLE_ID: bundle, ULTRATERM_COMPUTER_USE_TEAM_ID: team });
    assert.equal(r.status, 42, r.stderr); assert.match(r.stderr, /REACHED_INSTALL/);
    r = run(install, args, { ...env, ULTRATERM_COMPUTER_USE_BUNDLE_ID: bundle, ULTRATERM_COMPUTER_USE_TEAM_ID: 'XYZ1234567' });
    assert.notEqual(r.status, 42); assert.match(r.stderr, /expected Developer ID Installer team/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
