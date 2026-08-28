#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/scripts/check-docs.sh"
"${repo_root}/scripts/check-repo-hygiene.sh"

while IFS= read -r file; do
  bash -n "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.sh' | sort)

while IFS= read -r file; do
  node --check "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.mjs' | sort)

(
  cd "${repo_root}/apps/UltraTermComputerUseLinux"
  python3 -m unittest -v runtime_test.py
)

if command -v go >/dev/null 2>&1; then
  (
    cd "${repo_root}/apps/UltraTermComputerUseWindows"
    go test ./...
  )
  (
    cd "${repo_root}/apps/UltraTermComputerUseLinux"
    go test ./...
  )
fi

echo "Validation passed"
