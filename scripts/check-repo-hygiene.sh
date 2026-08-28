#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_files=(
  ".gitignore"
  ".gitattributes"
  "README.md"
  "CONTRIBUTING.md"
  "SECURITY.md"
  "LICENSE"
  "plugins/ultraterm-computer-use/.codex-plugin/plugin.json"
  "plugins/ultraterm-computer-use/.mcp.json"
)

failed=0
for path in "${required_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "Missing required repository file: ${path}"
    failed=1
  fi
done

if [[ -d "${repo_root}/.github/workflows" ]]; then
  echo "Remove first-party GitHub Actions workflows"
  failed=1
fi

for path in \
  "${repo_root}/docs/histories" \
  "${repo_root}/docs/exec-plans" \
  "${repo_root}/docs/references" \
  "${repo_root}/docs/generated" \
  "${repo_root}/artifacts"; do
  if [[ -e "${path}" ]]; then
    echo "Generated or internal directory remains: ${path#"${repo_root}/"}"
    failed=1
  fi
done

if find "${repo_root}" -type f \( -name '*.env' -o -name '*.env.*' \) -not -path '*/.git/*' | grep -q .; then
  echo "Environment files must not be committed"
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

echo "Repository hygiene checks passed"
