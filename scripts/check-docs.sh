#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_files=(
  "README.md"
  "CONTRIBUTING.md"
  "SECURITY.md"
  "LICENSE"
  "THIRD_PARTY_NOTICES.md"
  "docs/ARCHITECTURE.md"
  "docs/RELIABILITY.md"
  "docs/SECURITY.md"
  "package.json"
  "plugins/ultraterm-computer-use/.codex-plugin/plugin.json"
  "plugins/ultraterm-computer-use/.mcp.json"
  "plugins/ultraterm-computer-use/assets/ultraterm-computer-use.svg"
  "plugins/ultraterm-computer-use/assets/ultraterm-computer-use-small.svg"
)

failed=0
for path in "${required_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "Missing required public file: ${path}"
    failed=1
  fi
done

if [[ -d "${repo_root}/.github/workflows" ]]; then
  echo "GitHub Actions workflows are not part of this repository"
  failed=1
fi

if grep -R -n -E '/Users/|/home/|/private/tmp/|~/.codex|T63VT9UAY2|analytics\.libertydesign' \
  "${repo_root}/README.md" "${repo_root}/CONTRIBUTING.md" "${repo_root}/SECURITY.md" "${repo_root}/docs" \
  >/dev/null 2>&1; then
  echo "Public documentation contains a machine-specific path or private release detail"
  failed=1
fi

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "Public documentation checks passed"
