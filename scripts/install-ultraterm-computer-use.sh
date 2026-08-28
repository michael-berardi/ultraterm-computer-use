#!/usr/bin/env bash
set -euo pipefail

repo="michael-berardi/ultraterm-computer-use"
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
  sums_url="${pkg_url}.sha256"
  curl --fail --silent --show-error --location --retry 3 "$pkg_url" -o "$pkg"
  curl --fail --silent --show-error --location --retry 3 "$sums_url" -o "$work/UltraTerm-Computer-Use.pkg.sha256"
  expected="$(python3 - "$work/UltraTerm-Computer-Use.pkg.sha256" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"\b[a-fA-F0-9]{64}\b", text)
if not match: raise SystemExit("checksum manifest does not contain SHA-256")
print(match.group(0).lower())
PY
)"
  actual="$(shasum -a 256 "$pkg" | cut -d ' ' -f 1)"
  [[ "$actual" == "$expected" ]] || { echo "package checksum mismatch" >&2; exit 1; }
fi

signature="$(pkgutil --check-signature "$pkg" 2>&1)" || { echo "package signature verification failed" >&2; echo "$signature" >&2; exit 1; }
case "$signature" in
  *"Developer ID Installer"*"T63VT9UAY2"*) ;;
  *) echo "package is not signed by Developer ID Installer team T63VT9UAY2" >&2; exit 1 ;;
esac
spctl -a -vv -t install "$pkg" >/dev/null
payload_root="$(mktemp -d "${TMPDIR:-/tmp}/ultraterm-computer-use-pkg.XXXXXX")"
rmdir "$payload_root"
pkgutil --expand-full "$pkg" "$payload_root" >/dev/null
candidate_app="$(find "$payload_root" -type d -name 'UltraTerm Computer Use.app' -print -quit)"
[[ -n "$candidate_app" && -d "$candidate_app" ]] || { echo "package payload does not contain UltraTerm Computer Use.app" >&2; exit 1; }
candidate_signature="$(codesign -dv --verbose=4 "$candidate_app" 2>&1)" || { echo "candidate app signature is invalid" >&2; exit 1; }
case "$candidate_signature" in
  *"Identifier=com.libertydesignstudio.ultraterm-computer-use"*"TeamIdentifier=T63VT9UAY2"*) ;;
  *) echo "candidate app has the wrong bundle identifier or Developer ID team" >&2; exit 1 ;;
esac
candidate_requirement="$(codesign -dr - "$candidate_app" 2>&1 || true)"
[[ "$candidate_requirement" == *'identifier "com.libertydesignstudio.ultraterm-computer-use"'* &&
   ( "$candidate_requirement" == *'certificate leaf[subject.OU] = T63VT9UAY2'* ||
     "$candidate_requirement" == *'certificate leaf[subject.OU] = "T63VT9UAY2"'* ) ]] || { echo "candidate app has an unstable designated requirement" >&2; exit 1; }
spctl -a -vv -t exec "$candidate_app" >/dev/null
app="/Applications/UltraTerm Computer Use.app"
sudo installer -pkg "$pkg" -target /
app_signature="$(codesign -dv --verbose=4 "$app" 2>&1)" || { echo "installed app signature is invalid" >&2; exit 1; }
case "$app_signature" in
  *"Identifier=com.libertydesignstudio.ultraterm-computer-use"*"TeamIdentifier=T63VT9UAY2"*) ;;
  *) echo "installed app has the wrong bundle identifier or Developer ID team" >&2; exit 1 ;;
esac
app_requirement="$(codesign -dr - "$app" 2>&1 || true)"
if [[ "$app_requirement" != *'identifier "com.libertydesignstudio.ultraterm-computer-use"'* ||
      ( "$app_requirement" != *'certificate leaf[subject.OU] = T63VT9UAY2'* &&
        "$app_requirement" != *'certificate leaf[subject.OU] = "T63VT9UAY2"'* ) ]]; then
  echo "installed app has an unstable designated requirement" >&2
  exit 1
fi
spctl -a -vv -t exec "$app" >/dev/null

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
