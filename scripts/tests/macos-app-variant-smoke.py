#!/usr/bin/env python3
"""Build real native variants in temporary folders; --signed verifies Developer ID dev build.
No application is installed or launched and no macOS grants are changed.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--signed', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
base = {k: v for k, v in os.environ.items() if k not in (
    'ULTRATERM_COMPUTER_USE_APP_VARIANT', 'ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE',
    'ULTRATERM_COMPUTER_USE_APP_OUTPUT_DIR', 'ULTRATERM_COMPUTER_USE_CODESIGN_MODE')}
with tempfile.TemporaryDirectory(prefix='ocu-app-variant-') as temporary:
    root = Path(temporary)
    for configuration, override in [('release', 'dev'), ('debug', None), ('release', None)]:
        output = root / f'{configuration}-{override or "default"}'
        sentinels = [output / name / 'keep' for name in ('UltraTerm Computer Use.app', 'UltraTermComputerUse.app')]
        if override:
            for marker in sentinels:
                marker.parent.mkdir(parents=True)
                marker.write_text('neighbor')
        env = {**base, 'ULTRATERM_COMPUTER_USE_APP_OUTPUT_DIR': str(output),
               'ULTRATERM_COMPUTER_USE_CODESIGN_MODE': 'auto' if args.signed and override else 'none'}
        if override:
            env['ULTRATERM_COMPUTER_USE_APP_VARIANT'] = override
            # Leave INCLUDE_LOCKED_USE unset to exercise automatic dev exclusion.
        else:
            env['ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE'] = '0'
        subprocess.run(['bash', 'scripts/build-ultraterm-computer-use-app.sh', configuration], cwd=repo, env=env, check=True)
        dev = override == 'dev' or configuration == 'debug'
        app = output / ('UltraTerm Computer Use (Dev).app' if dev else 'UltraTerm Computer Use.app')
        with (app / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        assert info['CFBundleIdentifier'] == 'com.example.ultraterm-computer-use' + ('.dev' if dev else '')
        assert info['UltraTermComputerUseAppVariant'] == ('dev' if dev else 'release')
        assert not (app / 'Contents/Resources/LockedUse').exists()
        if override:
            assert all(marker.read_text() == 'neighbor' for marker in sentinels)
            if args.signed:
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
                signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], text=True, capture_output=True, check=True).stderr
                assert 'Identifier=com.example.ultraterm-computer-use.dev' in signature
                assert 'Authority=Developer ID Application:' in signature
        print(f'PASS {configuration}/{override or "default"}: identity, resources, preservation and requested signing', flush=True)
