#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"
release_dir="${dist_dir}/release"
staging_dir="${release_dir}/npm-staging"
tarball_dir="${release_dir}/npm"

rm -rf "${release_dir}"
mkdir -p "${tarball_dir}"

node "${repo_root}/scripts/npm/build-packages.mjs" \
  --configuration release \
  --arch universal \
  --out-dir "${staging_dir}"

while IFS= read -r package_dir; do
  npm pack "${package_dir}" --pack-destination "${tarball_dir}" >/dev/null
done < <(find "${staging_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

python3 - "${release_dir}/release-manifest.json" "${repo_root}" "${tarball_dir}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
tarball_dir = Path(sys.argv[3])

artifacts = []
for tarball in sorted(tarball_dir.glob("*.tgz")):
    artifacts.append({
        "name": tarball.name,
        "size_bytes": tarball.stat().st_size,
    })

manifest = {
    "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
    "git_sha": os.environ.get("GITHUB_SHA") or __import__("subprocess").check_output(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
        text=True,
    ).strip(),
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifacts": artifacts,
    "distribution": {
        "type": "npm",
        "package_count": len(artifacts),
        "staging_dir": str(tarball_dir.relative_to(repo_root)),
    },
}

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

# One-step installers ship as release assets too, covered by SHA256SUMS.
cp "${repo_root}/scripts/install.sh" "${release_dir}/install.sh"
cp "${repo_root}/scripts/install.ps1" "${release_dir}/install.ps1"
chmod 755 "${release_dir}/install.sh"

python3 - "${release_dir}" "${tarball_dir}" <<'PY'
import hashlib
import pathlib
import sys

release_dir = pathlib.Path(sys.argv[1])
tarball_dir = pathlib.Path(sys.argv[2])

files = sorted(tarball_dir.glob("*.tgz")) + [
    release_dir / name for name in ("release-manifest.json", "install.sh", "install.ps1")
]
lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}" for path in files]
(release_dir / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")

print("Release assets:")
for path in files + [release_dir / "SHA256SUMS"]:
    print(f"  {path.name}")
PY

echo "${release_dir}"
