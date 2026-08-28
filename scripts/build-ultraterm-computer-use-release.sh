#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team="${ULTRATERM_COMPUTER_USE_TEAM_ID:-}"
app_identity="${ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY:-}"
installer_identity="${ULTRATERM_COMPUTER_USE_INSTALLER_IDENTITY:-}"
notary_profile="${ULTRATERM_COMPUTER_USE_NOTARYTOOL_PROFILE:-}"
version="${ULTRATERM_COMPUTER_USE_RELEASE_VERSION:-}"

fail() { echo "release error: $*" >&2; exit 1; }
[[ -n "$team" ]] || fail "ULTRATERM_COMPUTER_USE_TEAM_ID is required"
[[ -n "$app_identity" ]] || fail "ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY is required"
[[ -n "$installer_identity" ]] || fail "ULTRATERM_COMPUTER_USE_INSTALLER_IDENTITY is required"
[[ -n "$notary_profile" ]] || fail "ULTRATERM_COMPUTER_USE_NOTARYTOOL_PROFILE is required"
[[ "$app_identity" == "Developer ID Application:"* && "$app_identity" == *"($team)" ]] || fail "app identity must be Developer ID Application for team $team"
[[ "$installer_identity" == "Developer ID Installer:"* && "$installer_identity" == *"($team)" ]] || fail "installer identity must be Developer ID Installer for team $team"
command -v pkgbuild >/dev/null || fail "pkgbuild is required"
command -v xcrun >/dev/null || fail "Xcode command line tools are required"
command -v shasum >/dev/null || fail "shasum is required"

if [[ -z "$version" ]]; then
  version="$(python3 - "$repo_root/plugins/ultraterm-computer-use/.codex-plugin/plugin.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)"
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "release version must be a stable semver"
output="$repo_root/dist/release/ultraterm-computer-use/$version"
release_root="$repo_root/dist/release/ultraterm-computer-use"
case "$(python3 - "$output" "$release_root" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).resolve().is_relative_to(pathlib.Path(sys.argv[2]).resolve()))
PY
)" in
  True) ;;
  *) fail "release output escapes the release root" ;;
esac
rm -rf "$output"
mkdir -p "$output"

ULTRATERM_COMPUTER_USE_CODESIGN_MODE=identity \
ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY="$app_identity" \
ULTRATERM_COMPUTER_USE_NOTARYTOOL_PROFILE="$notary_profile" \
ULTRATERM_COMPUTER_USE_BUNDLE_VERSION="$version" \
  "$repo_root/scripts/build-ultraterm-computer-use-app.sh" release --arch universal

app="$repo_root/dist/UltraTerm Computer Use.app"
pkg="$output/UltraTerm-Computer-Use.pkg"
zip="$output/UltraTerm-Computer-Use.zip"
[[ -d "$app" ]] || fail "release app was not produced"
app_notary_zip="$output/UltraTerm-Computer-Use-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$app_notary_zip"
xcrun notarytool submit "$app_notary_zip" --keychain-profile "$notary_profile" --wait
rm -f "$app_notary_zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

component_plist="$output/component.plist"
package_root="$output/package-root"
mkdir -p "$package_root"
ditto "$app" "$package_root/UltraTerm Computer Use.app"
cat >"$component_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <true/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>UltraTerm Computer Use.app</string>
  </dict>
</array>
</plist>
PLIST
pkgbuild --root "$package_root" --component-plist "$component_plist" \
  --install-location /Applications --sign "$installer_identity" "$pkg"
rm -rf "$package_root"
rm -f "$component_plist"
xcrun notarytool submit "$pkg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$pkg"
xcrun stapler validate "$pkg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun stapler validate "$app"

(cd "$output" && shasum -a 256 "$(basename "$pkg")" "$(basename "$zip")" > SHA256SUMS)
(cd "$output" && shasum -a 256 "$(basename "$pkg")" > "$(basename "$pkg").sha256")
(cd "$output" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
python3 - "$output" "$version" "$team" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
version, team = sys.argv[2:]
artifacts = {}
for path in sorted(root.iterdir()):
    if path.name in {"release-manifest.json", "SHA256SUMS"} or not path.is_file(): continue
    artifacts[path.name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}
manifest = {
    "product": "UltraTerm Computer Use",
    "app": "ultraterm-computer-use",
    "version": version,
    "bundleIdentifier": "com.libertydesignstudio.ultraterm-computer-use",
    "teamIdentifier": team,
    "designatedRequirement": f'identifier "com.libertydesignstudio.ultraterm-computer-use" and anchor apple generic and certificate leaf[subject.OU] = "{team}"',
    "artifacts": artifacts,
}
(root / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

echo "Built signed and notarized UltraTerm Computer Use release at $output"
