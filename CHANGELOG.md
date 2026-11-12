# Changelog

## 0.7.2

Fixed: README: real owner in install, badge and clone links; neutrality test allows the repo's own URL.

## 0.7.1

Fixed: an `install.sh`, `install.ps1` or `install-ultraterm-computer-use.sh` fetched from the main branch (an unstamped source copy) downloaded its tarball and checksums from a placeholder GitHub account that anyone could register. These scripts now refuse to run unless they are the stamped copies attached to a GitHub release (`UTCU_RELEASE_BASE` still works for tests); the stamp cannot rewrite the guard. Also fixed: `install.sh` could nest a new release inside an existing release folder with the same name (it now creates a unique folder), and under `curl | sh` the macOS message now prints the correct `sh -s -- --npm` command. The signed release build now finishes with `finalize-release.sh --require-all` once the npm tarball exists, so a partial `SHA256SUMS` cannot be uploaded. The Windows installer was tested under PowerShell 7 on Linux and not yet on a Windows machine.

## 0.7.0

Added one-step release installers: `scripts/install.sh` for Linux (on macOS it points at the signed .pkg and offers the npm route with `--npm`) and `scripts/install.ps1` for Windows. Both verify the release tarball's SHA-256, use Node 18+ from the system or fetch the official Node 22 LTS into the tool's own folder, install under one home folder, write a command shim, and finish with the CLI version check. Release packaging now ships `install.sh` and `install.ps1` as assets covered by `SHA256SUMS`. Added `scripts/test-install.sh` covering local, Linux container, and PowerShell 7 runs.

The release scripts stamp the real GitHub owner/repo into the installers (`scripts/stamp-installers.sh`) and one final step (`scripts/finalize-release.sh`) writes a single combined `SHA256SUMS` and manifest covering the .pkg, .zip, .tgz and installers, in either build order. The Windows installer runs `npm.cmd` (not the policy-blocked `npm.ps1`), uses a `%~dp0`-relative or OEM-encoded `.cmd` shim, never overwrites a command it did not write, keeps the live release when re-run, and both installers always run the absolute `node`. The Windows installer was tested under PowerShell 7 on Linux and not yet on a Windows machine.

## 0.6.1

The published 0.6.0 release had no assets. This release restores signed assets using the existing shipped app identity, preserving macOS permissions and update compatibility. Release identity is supplied through environment configuration rather than embedded in shipped files.
