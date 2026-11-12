# Changelog

## Unreleased

Added one-step release installers: `scripts/install.sh` for Linux (on macOS it points at the signed .pkg and offers the npm route with `--npm`) and `scripts/install.ps1` for Windows. Both verify the release tarball's SHA-256, use Node 18+ from the system or fetch the official Node 22 LTS into the tool's own folder, install under one home folder, write a command shim, and finish with the CLI version check. Release packaging now ships `install.sh` and `install.ps1` as assets covered by `SHA256SUMS`. Added `scripts/test-install.sh` covering local, Linux container, and PowerShell 7 runs.

## 0.6.1

The published 0.6.0 release had no assets. This release restores signed assets using the existing shipped app identity, preserving macOS permissions and update compatibility. Release identity is supplied through environment configuration rather than embedded in shipped files.
