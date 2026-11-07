#!/usr/bin/env bash
set -euo pipefail

repo="your-org/ultraterm-computer-use"
install_root="${HOME}/.local/bin"
local_pkg=""
payload_root=""

usage() {
  cat <<'EOF'
Usage: scripts/install-ultraterm-computer-use.sh [--local path/to/UltraTerm-Computer-Use.pkg]

Downloads the latest stable signed/notarized package, verifies its checksum and
Apple signature, then installs /Applications/UltraTerm Computer Use.app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) local_pkg="${2:-}"; [[ -n "$local_pkg" ]] || { echo "--local requires a package path" >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v pkgutil >/dev/null || { echo "macOS pkgutil is required" >&2; exit 1; }
command -v installer >/dev/null || { echo "macOS installer is required" >&2; exit 1; }
command -v spctl >/dev/null || { echo "macOS spctl is required" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/ultraterm-computer-use-install.XXXXXX")"
cleanup() { rm -rf "$work"; [[ -z "$payload_root" ]] || rm -rf "$payload_root"; }
trap cleanup EXIT

pkg="$work/UltraTerm-Computer-Use.pkg"
if [[ -n "$local_pkg" ]]; then
  cp "$local_pkg" "$pkg"
else
  command -v curl >/dev/null || { echo "curl is required for a remote install" >&2; exit 1; }
  api="https://api.github.com/repos/${repo}/releases/latest"
  release_json="$work/release.json"
  curl --fail --silent --show-error --location --retry 3 "$api" -o "$release_json"
  pkg_url="$(python3 - "$release_json" <<'PY'
import json, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest GitHub release is not stable")
for asset in release.get("assets", []):
    if asset.get("name") == "UltraTerm-Computer-Use.pkg":
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit("stable release has no UltraTerm-Computer-Use.pkg")
PY
)"
  # Asset names come from the same release as the package, not a derived URL.
  for asset in SHA256SUMS release-manifest.json; do
    url="$(python3 - "$release_json" "$asset" <<'PYASSET'
import json, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
urls = [a["browser_download_url"] for a in release.get("assets", []) if a.get("name") == sys.argv[2]]
if len(urls) != 1: raise SystemExit("release identity error: missing or duplicate " + sys.argv[2])
print(urls[0])
PYASSET
)"
    curl --fail --silent --show-error --location --retry 3 "$url" -o "$work/$asset"
  done
  curl --fail --silent --show-error --location --retry 3 "$pkg_url" -o "$pkg"
  python3 - "$work" <<'PYCHECK'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
lines = (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
for name in ("UltraTerm-Computer-Use.pkg", "release-manifest.json"):
    entries = [m.group(1).lower() for line in lines if (m := re.fullmatch(r"([a-fA-F0-9]{64}) [ *](.+)", line)) and m.group(2) == name]
    if len(entries) != 1 or hashlib.sha256((root / name).read_bytes()).hexdigest() != entries[0]:
        raise SystemExit("release identity error: checksum missing or mismatched for " + name)
PYCHECK
fi

bundle_id="${ULTRATERM_COMPUTER_USE_BUNDLE_ID:-}"
team="${ULTRATERM_COMPUTER_USE_TEAM_ID:-}"
if [[ -z "$local_pkg" ]]; then
  # Environment values, when supplied, pin the expected identity independently.
  manifest_identity="$(python3 - "$work/release-manifest.json" <<'PYIDENTITY'
import json, sys
try:
    manifest = json.load(open(sys.argv[1], encoding="utf-8"))
    bundle, team = manifest["bundleIdentifier"], manifest["teamIdentifier"]
    if not isinstance(bundle, str) or not isinstance(team, str) or "\n" in bundle + team:
        raise ValueError("invalid identity")
    print(bundle)
    print(team)
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit("release identity error: invalid manifest identity")
PYIDENTITY
)" || exit 1
  manifest_bundle="${manifest_identity%%$'\n'*}"
  manifest_team="${manifest_identity#*$'\n'}"
  bundle_id="${bundle_id:-$manifest_bundle}"
  team="${team:-$manifest_team}"
fi
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && "$bundle_id" != com.example.* ]] || { echo "release identity error: ULTRATERM_COMPUTER_USE_BUNDLE_ID or valid manifest bundleIdentifier required" >&2; exit 1; }
[[ "$team" =~ ^[A-Za-z0-9]{10}$ ]] || { echo "release identity error: ULTRATERM_COMPUTER_USE_TEAM_ID or valid manifest teamIdentifier required" >&2; exit 1; }

signature="$(pkgutil --check-signature "$pkg" 2>&1)" || { echo "package signature verification failed" >&2; echo "$signature" >&2; exit 1; }
[[ "$signature" == *"Developer ID Installer"* && "$signature" == *"($team)"* ]] || { echo "package is not signed by the expected Developer ID Installer team" >&2; exit 1; }
spctl -a -vv -t install "$pkg" >/dev/null
payload_root="$(mktemp -d "${TMPDIR:-/tmp}/ultraterm-computer-use-pkg.XXXXXX")"
rmdir "$payload_root"
pkgutil --expand-full "$pkg" "$payload_root" >/dev/null
candidate_app="$(find "$payload_root" -type d -name 'UltraTerm Computer Use.app' -print -quit)"
[[ -n "$candidate_app" && -d "$candidate_app" ]] || { echo "package payload does not contain UltraTerm Computer Use.app" >&2; exit 1; }

verify_app_identity() {
  local target="$1" signature requirement
  signature="$(codesign -dv --verbose=4 "$target" 2>&1)" || { echo "app signature is invalid" >&2; return 1; }
  printf '%s\n' "$signature" | grep -Fx "Identifier=$bundle_id" >/dev/null &&
    printf '%s\n' "$signature" | grep -Fx "TeamIdentifier=$team" >/dev/null || { echo "app has the wrong bundle identifier or Developer ID team" >&2; return 1; }
  requirement="$(codesign -dr - "$target" 2>&1)" || { echo "app designated requirement is unavailable" >&2; return 1; }
  [[ "$requirement" == *"identifier \"$bundle_id\""* &&
     ( "$requirement" == *"certificate leaf[subject.OU] = $team"* ||
       "$requirement" == *"certificate leaf[subject.OU] = \"$team\""* ) ]] || { echo "app has an unstable designated requirement" >&2; return 1; }
  spctl -a -vv -t exec "$target" >/dev/null
}
verify_app_identity "$candidate_app"
app="/Applications/UltraTerm Computer Use.app"
sudo installer -pkg "$pkg" -target /
verify_app_identity "$app"


mkdir -p "$install_root"

write_shim() {
  local destination="$1"
  cat >"$destination" <<'SH'
#!/usr/bin/env bash
# ULTRATERM_COMPUTER_USE_MANAGED_SHIM
set -euo pipefail
app="/Applications/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse"
app_bundle="/Applications/UltraTerm Computer Use.app"
if [[ ! -x "$app" ]]; then
  echo "UltraTerm Computer Use is not installed at /Applications" >&2
  exit 1
fi
[[ -n "${1:-}" ]] || { echo "Usage: ultraterm-computer-use <command>" >&2; exit 2; }
case "${1:-}" in
  update)
    open -a "$app_bundle"
    ;;
  uninstall)
    sudo rm -rf "$app_bundle"
    managed_shim="$HOME/.local/bin/ultraterm-computer-use"
    if grep -q 'ULTRATERM_COMPUTER_USE_MANAGED_SHIM' "$managed_shim" 2>/dev/null; then
      rm -f "$managed_shim"
    fi
    echo "Removed UltraTerm Computer Use."
    ;;
  diagnostics)
    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    codesign -dr - "$app_bundle" 2>&1 || true
    "$app" doctor --status-only --json
    ;;
  *)
    exec "$app" "$@"
    ;;
esac
SH
  chmod 755 "$destination"
}

standalone_shim="$install_root/ultraterm-computer-use"
if [[ -e "$standalone_shim" && ! -f "$standalone_shim" ]]; then
  echo "$standalone_shim exists and is not a regular file" >&2
  exit 1
fi
if [[ -f "$standalone_shim" ]] && ! grep -q 'ULTRATERM_COMPUTER_USE_MANAGED_SHIM' "$standalone_shim"; then
  echo "refusing to replace existing command at $standalone_shim" >&2
  exit 1
fi
write_shim "$standalone_shim"


echo "Installed UltraTerm Computer Use. Ensure ${install_root} is on PATH, then run: ultraterm-computer-use doctor"
