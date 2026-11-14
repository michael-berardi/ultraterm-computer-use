import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(root, 'packages/LockedUseNative/PublisherIdentity.c');
const include = path.join(root, 'packages/LockedUseNative/include');
const identity = path.join(root, 'scripts/publisher-identity.sh');

// The stamped identifier is one C value every binary links. Compile it as the build does.
function stamped(flags) {
  const dir = mkdtempSync(path.join(tmpdir(), 'publisher-identity-'));
  try {
    const main = path.join(dir, 'main.c');
    writeFileSync(main, '#include <stdio.h>\n#include "LockedUseNative.h"\nint main(void){puts(ocu_publisher_bundle_identifier());return 0;}\n');
    const out = path.join(dir, 'probe');
    execFileSync('clang', [...flags, `-I${include}`, source, main, '-o', out]);
    return execFileSync(out, { encoding: 'utf8' }).trim();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function buildFlags(env) {
  const script = `source "${identity}" && printf '%s\\n' "\${publisher_build_flags[@]-}"`;
  return execFileSync('bash', ['-c', script], { encoding: 'utf8', env: { PATH: process.env.PATH, ...env } })
    .split('\n').filter(Boolean);
}

test('an unstamped build keeps the source placeholder', { skip: process.platform !== 'darwin' }, () => {
  assert.equal(stamped([]), 'com.example.ultraterm-computer-use');
});

test('the build flags stamp the publisher identifier, including one ending in .dev', { skip: process.platform !== 'darwin' }, () => {
  for (const id of ['org.acme.computer-use', 'org.acme.tool.dev']) {
    const flags = buildFlags({ ULTRATERM_COMPUTER_USE_BUNDLE_ID: id });
    assert.deepEqual(flags, ['-Xcc', `-DOCU_PUBLISHER_BUNDLE_ID="${id}"`]);
    assert.equal(stamped([flags[1]]), id);
  }
});

test('an unset identifier adds no flag and an invalid one stops the build', () => {
  assert.deepEqual(buildFlags({}), []);
  assert.throws(() => buildFlags({ ULTRATERM_COMPUTER_USE_BUNDLE_ID: 'a"; rm -rf x' }), /Command failed/);
});
