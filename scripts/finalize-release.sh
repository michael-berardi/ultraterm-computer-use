#!/usr/bin/env bash
# Final release step: make ONE complete release folder, dist/release/ultraterm-computer-use/<version>/, holding
# the signed .pkg and .zip (from build-ultraterm-computer-use-release.sh), the npm .tgz (from release-package.sh),
# both stamped installers, ONE combined SHA256SUMS and release-manifest.json. Safe to run in either order and more
# than once: it only copies the .tgz in, stamps the installers, and rewrites SHA256SUMS and the manifest.
# Usage: finalize-release.sh <version> [--require-all]   (--require-all fails unless pkg, zip and tgz are present)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?usage: finalize-release.sh <version> [--require-all]}"
require_all=0
[[ "${2:-}" == "--require-all" ]] && require_all=1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "finalize-release: bad version $version" >&2; exit 1; }

folder="$repo_root/dist/release/ultraterm-computer-use/$version"
tgz_name="ultraterm-computer-use-$version.tgz"
mkdir -p "$folder"
if [[ -f "$repo_root/dist/release/npm/$tgz_name" ]]; then
  cp "$repo_root/dist/release/npm/$tgz_name" "$folder/$tgz_name"
fi

"$repo_root/scripts/stamp-installers.sh" "$folder"

python3 - "$folder" "$version" "$require_all" <<'PY'
import hashlib, json, pathlib, subprocess, sys

folder = pathlib.Path(sys.argv[1])
version = sys.argv[2]
require_all = sys.argv[3] == "1"
tgz = f"ultraterm-computer-use-{version}.tgz"
primary = ["UltraTerm-Computer-Use.pkg", "UltraTerm-Computer-Use.zip", tgz, "install.sh", "install.ps1", "install-ultraterm-computer-use.sh"]
missing = [n for n in primary if not (folder / n).is_file()]
if missing:
    print("finalize-release: missing " + ", ".join(missing), file=sys.stderr)
    if require_all:
        sys.exit(1)

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

manifest_path = folder / "release-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {
    "product": "UltraTerm Computer Use", "app": "ultraterm-computer-use"}
manifest["version"] = version
artifacts = {}
for p in sorted(folder.iterdir()):
    if p.name in {"release-manifest.json", "SHA256SUMS"} or not p.is_file():
        continue
    artifacts[p.name] = {"sha256": digest(p), "bytes": p.stat().st_size}
manifest["artifacts"] = artifacts
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

listed = [n for n in primary if (folder / n).is_file()] + ["release-manifest.json"]
(folder / "SHA256SUMS").write_text(
    "".join(f"{digest(folder / n)}  {n}\n" for n in listed), encoding="utf-8")
print("Release folder:", folder)
for n in listed + ["SHA256SUMS"]:
    print("  " + n)
PY
