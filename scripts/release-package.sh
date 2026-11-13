#!/usr/bin/env bash

set -euo pipefail

# These entry points select the release/dev payload by configuration, not variant.
# An inherited dev override could leave an old release bundle selected for delivery.
if [[ -n "${ULTRATERM_COMPUTER_USE_APP_VARIANT:-}" ]]; then
  echo 'ULTRATERM_COMPUTER_USE_APP_VARIANT is only supported by build-ultraterm-computer-use-app.sh; unset it before packaging or installing.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"
release_dir="${dist_dir}/release"
staging_dir="${release_dir}/npm-staging"
tarball_dir="${release_dir}/npm"

# Remove only this script's own output: the signed .pkg folder under dist/release must survive.
rm -rf "${staging_dir}" "${tarball_dir}"
rm -f "${release_dir}/release-manifest.json" "${release_dir}/SHA256SUMS" "${release_dir}/install.sh" "${release_dir}/install.ps1"
mkdir -p "${tarball_dir}"

build_args=(--configuration release --arch universal --out-dir "${staging_dir}")
if [[ $# -eq 1 && "$1" == --skip-build ]]; then
  build_args+=(--skip-build)
elif [[ $# -ne 0 ]]; then
  echo 'Usage: scripts/release-package.sh [--skip-build]' >&2
  exit 64
fi

node "${repo_root}/scripts/npm/build-packages.mjs" "${build_args[@]}"

while IFS= read -r package_dir; do
  npm pack "${package_dir}" --pack-destination "${tarball_dir}" >/dev/null
done < <(find "${staging_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

# Final step (works in either order with the .pkg build): one release folder with the tgz, stamped
# installers, one combined SHA256SUMS and the manifest.
version="$(node -p 'require(process.argv[1]).version' "${repo_root}/package.json")"
"${repo_root}/scripts/finalize-release.sh" "${version}"
