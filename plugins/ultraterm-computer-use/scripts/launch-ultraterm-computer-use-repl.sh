#!/usr/bin/env bash

set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${plugin_root}/../.." && pwd)"
adapter_candidates=(
  "${plugin_root}/scripts/ultraterm-computer-use-repl.mjs"
  "${repo_root}/scripts/node-repl/ultraterm-computer-use-repl.mjs"
)
native_candidates=(
  "${plugin_root}/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse"
  "${plugin_root}/UltraTerm Computer Use (Dev).app/Contents/MacOS/UltraTermComputerUse"
  "${plugin_root}/UltraTermComputerUse.app/Contents/MacOS/UltraTermComputerUse"
  "${plugin_root}/ultraterm-computer-use"
  "${plugin_root}/ultraterm-computer-use.exe"
  # install-codex-plugin.sh stores the plugin source and runtime payload as
  # siblings beneath the versioned cache directory.
  "${repo_root}/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/UltraTerm Computer Use (Dev).app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/UltraTermComputerUse.app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/ultraterm-computer-use"
  "${repo_root}/ultraterm-computer-use.exe"
  "${repo_root}/dist/UltraTerm Computer Use (Dev).app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/dist/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/dist/UltraTermComputerUse.app/Contents/MacOS/UltraTermComputerUse"
  "${repo_root}/dist/linux/arm64/ultraterm-computer-use"
  "${repo_root}/dist/linux/amd64/ultraterm-computer-use"
  "${repo_root}/dist/windows/arm64/ultraterm-computer-use.exe"
  "${repo_root}/dist/windows/amd64/ultraterm-computer-use.exe"
)

adapter=""
for candidate in "${adapter_candidates[@]}"; do
  if [[ -f "${candidate}" ]]; then adapter="${candidate}"; break; fi
done

if [[ -z "${adapter}" ]]; then
  echo "ultraterm-computer-use could not find its Node REPL adapter." >&2
  exit 1
fi

for native in "${native_candidates[@]}"; do
  if [[ -x "${native}" ]]; then
    exec node "${adapter}" -- "${native}" mcp
  fi
done

if command -v ultraterm-computer-use >/dev/null 2>&1; then
  exec node "${adapter}" -- "$(command -v ultraterm-computer-use)" mcp
fi

echo "ultraterm-computer-use could not find a runnable native runtime for the JS REPL adapter." >&2
exit 1
