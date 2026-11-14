#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/publisher-identity.sh"
configuration="debug"
arch_mode="native"
codesign_mode="${ULTRATERM_COMPUTER_USE_CODESIGN_MODE:-auto}"
codesign_identity="${ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY:-}"
codesign_keychain="${ULTRATERM_COMPUTER_USE_CODESIGN_KEYCHAIN:-}"
app_variant_override="${ULTRATERM_COMPUTER_USE_APP_VARIANT:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/build-ultraterm-computer-use-app.sh [debug|release] [--configuration debug|release] [--arch native|arm64|x86_64|universal]

Examples:
  ./scripts/build-ultraterm-computer-use-app.sh debug
  ./scripts/build-ultraterm-computer-use-app.sh --configuration release --arch universal

Environment:
  ULTRATERM_COMPUTER_USE_BUNDLE_ID=<reverse-DNS bundle identifier>
  ULTRATERM_COMPUTER_USE_APP_VARIANT=dev  # Keep development identity with release optimization.
  ULTRATERM_COMPUTER_USE_APP_OUTPUT_DIR=/path/to/isolated/output
  ULTRATERM_COMPUTER_USE_CODESIGN_MODE=auto|identity|adhoc|none
  ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)"
  ULTRATERM_COMPUTER_USE_CODESIGN_KEYCHAIN=/path/to/signing.keychain-db
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release)
      configuration="$1"
      shift
      ;;
    --configuration)
      configuration="${2:-}"
      if [[ -z "${configuration}" ]]; then
        echo "--configuration requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --arch)
      arch_mode="${2:-}"
      if [[ -z "${arch_mode}" ]]; then
        echo "--arch requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "${app_variant_override}" && "${app_variant_override}" != "dev" ]]; then
  echo "Unsupported ULTRATERM_COMPUTER_USE_APP_VARIANT: ${app_variant_override}; use dev or leave unset" >&2
  exit 1
fi
# Locked Use components follow the build configuration, so a release-optimized dev app
# cannot embed them consistently. Refuse instead of packaging a mismatched bundle.
if [[ "${app_variant_override}" == "dev" && "${configuration}" == "release" && "${ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE:-auto}" == "1" ]]; then
  echo "ULTRATERM_COMPUTER_USE_APP_VARIANT=dev does not package Locked Use; leave ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE unset or set it to 0" >&2
  exit 1
fi

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  echo "Unsupported configuration: ${configuration}" >&2
  exit 1
fi

if [[ "${arch_mode}" != "native" && "${arch_mode}" != "arm64" && "${arch_mode}" != "x86_64" && "${arch_mode}" != "universal" ]]; then
  echo "Unsupported arch mode: ${arch_mode}" >&2
  exit 1
fi

if [[ "${codesign_mode}" != "auto" && "${codesign_mode}" != "identity" && "${codesign_mode}" != "adhoc" && "${codesign_mode}" != "none" ]]; then
  echo "Unsupported ULTRATERM_COMPUTER_USE_CODESIGN_MODE: ${codesign_mode}" >&2
  exit 1
fi

read_package_version() {
  python3 - "${repo_root}/plugins/ultraterm-computer-use/.codex-plugin/plugin.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

print(manifest["version"])
PY
}

build_binary() {
  local triple="${1:-}"
  local scratch_path="${2:-}"
  local -a args=(-c "${configuration}")

  if [[ -n "${triple}" ]]; then
    args+=(--triple "${triple}")
  fi

  if [[ -n "${scratch_path}" ]]; then
    args+=(--scratch-path "${scratch_path}")
  fi

  local binary_dir
  binary_dir="$(swift build "${args[@]}" ${publisher_build_flags[@]+"${publisher_build_flags[@]}"} --show-bin-path)"
  swift build "${args[@]}" ${publisher_build_flags[@]+"${publisher_build_flags[@]}"} --product UltraTermComputerUse >&2
  printf '%s/UltraTermComputerUse\n' "${binary_dir}"
}

find_codesign_identity() {
  local prefix="${1:-}"
  local -a args=(find-identity -v -p codesigning)

  if [[ -n "${codesign_keychain}" ]]; then
    args+=("${codesign_keychain}")
  fi

  security "${args[@]}" 2>/dev/null \
    | sed -n "s/.*\"\\(${prefix}: .*\\)\"/\1/p" \
    | head -n 1
}

list_user_keychains() {
  security list-keychains -d user \
    | sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p'
}

run_with_codesign_keychain() {
  local keychain_path="${1:-}"
  shift

  if [[ -z "${keychain_path}" ]]; then
    "$@"
    return
  fi

  local -a existing_keychains=()
  while IFS= read -r keychain; do
    if [[ -n "${keychain}" ]]; then
      existing_keychains+=("${keychain}")
    fi
  done < <(list_user_keychains)

  local -a desired_keychains=("${keychain_path}")
  local existing=""
  for existing in ${existing_keychains[@]+"${existing_keychains[@]}"}; do
    if [[ "${existing}" != "${keychain_path}" ]]; then
      desired_keychains+=("${existing}")
    fi
  done

  security list-keychains -d user -s "${desired_keychains[@]}" >/dev/null

  local status=0
  "$@" || status=$?

  if [[ ${#existing_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${existing_keychains[@]}" >/dev/null
  else
    security list-keychains -d user -s >/dev/null
  fi

  return "${status}"
}

resolve_codesign_identity() {
  case "${codesign_mode}" in
    none)
      return 1
      ;;
    adhoc)
      printf '%s\n' "-"
      return 0
      ;;
    identity)
      if [[ -z "${codesign_identity}" ]]; then
        echo "ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY is required when ULTRATERM_COMPUTER_USE_CODESIGN_MODE=identity" >&2
        exit 1
      fi
      printf '%s\n' "${codesign_identity}"
      return 0
      ;;
    auto)
      if [[ -n "${codesign_identity}" ]]; then
        printf '%s\n' "${codesign_identity}"
        return 0
      fi

      local discovered_identity
      discovered_identity="$(find_codesign_identity "Developer ID Application")"
      if [[ -n "${discovered_identity}" ]]; then
        printf '%s\n' "${discovered_identity}"
        return 0
      fi

      discovered_identity="$(find_codesign_identity "Apple Development")"
      if [[ -n "${discovered_identity}" ]]; then
        printf '%s\n' "${discovered_identity}"
        return 0
      fi

      printf '%s\n' "-"
      return 0
      ;;
  esac
}

codesign_app_bundle() {
  local app_path="${1:-}"
  local identity=""

  if ! identity="$(resolve_codesign_identity)"; then
    echo "Skipping codesign for ${app_path} (ULTRATERM_COMPUTER_USE_CODESIGN_MODE=none)" >&2
    return
  fi

  local -a args=(--force --sign "${identity}")

  if [[ -n "${codesign_keychain}" && "${identity}" != "-" ]]; then
    args+=(--keychain "${codesign_keychain}")
  fi

  if [[ "${identity}" != "-" ]]; then
    args+=(--options runtime,library)
  fi
  if [[ -n "${ULTRATERM_COMPUTER_USE_PROVISIONING_PROFILE:-}" ]]; then
    if [[ "${identity}" == "-" ]]; then
      echo 'Keychain provisioning requires an Apple signing identity.' >&2
      exit 1
    fi
    profile_entitlements="${icon_work_dir}/keychain-entitlements.plist"
    python3 "${repo_root}/scripts/prepare-macos-keychain-profile.py" "${ULTRATERM_COMPUTER_USE_PROVISIONING_PROFILE}" "${bundle_identifier}" "${profile_entitlements}"
    cp "${ULTRATERM_COMPUTER_USE_PROVISIONING_PROFILE}" "${contents_dir}/embedded.provisionprofile"
    args+=(--entitlements "${profile_entitlements}")
  fi

  run_with_codesign_keychain "${codesign_keychain}" \
    codesign "${args[@]}" "${app_path}" >/dev/null

  if [[ "${identity}" == "-" ]]; then
    echo "Signed ${app_path} with ad-hoc identity; macOS TCC may still treat separately built copies as different app identities until a stable Apple signing identity is configured." >&2
  else
    echo "Signed ${app_path} with ${identity}" >&2
  fi
}

cd "${repo_root}"

package_version="$(read_package_version)"
bundle_version="${ULTRATERM_COMPUTER_USE_BUNDLE_VERSION:-$(git -C "${repo_root}" rev-list --count HEAD 2>/dev/null || echo 1)}"
release_app_bundle_name="UltraTerm Computer Use.app"
development_app_bundle_name="UltraTerm Computer Use (Dev).app"
legacy_app_bundle_name="UltraTermComputerUse.app"
bundle_icon_name="UltraTermComputerUse.icns"
icon_master_png="${repo_root}/assets/app-icons/ultraterm-computer-use-1024.png"
iconset_build_script="${repo_root}/scripts/build-apple-iconset.sh"

bundle_display_name="UltraTerm Computer Use"
bundle_identifier="${ULTRATERM_COMPUTER_USE_BUNDLE_ID:-com.example.ultraterm-computer-use}"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Invalid ULTRATERM_COMPUTER_USE_BUNDLE_ID" >&2; exit 1; }
app_variant="release"
app_bundle_name="${release_app_bundle_name}"

if [[ "${configuration}" != "release" || "${app_variant_override}" == "dev" ]]; then
  bundle_display_name="UltraTerm Computer Use (Dev)"
  bundle_identifier="${bundle_identifier}.dev"
  app_variant="dev"
  app_bundle_name="${development_app_bundle_name}"
fi

app_output_dir="${ULTRATERM_COMPUTER_USE_APP_OUTPUT_DIR:-${repo_root}/dist}"
app_root="${app_output_dir}/${app_bundle_name}"
release_app_root="${app_output_dir}/${release_app_bundle_name}"
development_app_root="${app_output_dir}/${development_app_bundle_name}"
legacy_app_root="${app_output_dir}/${legacy_app_bundle_name}"
contents_dir="${app_root}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

rm -rf "${app_root}"
# An explicit dev build must not remove a neighboring release or legacy bundle.
if [[ "${app_variant_override}" != "dev" ]]; then
  rm -rf "${legacy_app_root}"
  if [[ "${app_variant}" == "release" ]]; then
    rm -rf "${development_app_root}"
  else
    rm -rf "${release_app_root}"
  fi
fi
mkdir -p "${macos_dir}" "${resources_dir}"

case "${arch_mode}" in
  native)
    cp "$(build_binary "" "")" "${macos_dir}/UltraTermComputerUse"
    ;;
  arm64)
    cp "$(build_binary "arm64-apple-macosx14.0" ".build/arm64-${configuration}")" "${macos_dir}/UltraTermComputerUse"
    ;;
  x86_64)
    cp "$(build_binary "x86_64-apple-macosx14.0" ".build/x86_64-${configuration}")" "${macos_dir}/UltraTermComputerUse"
    ;;
  universal)
    arm_binary="$(build_binary "arm64-apple-macosx14.0" ".build/arm64-${configuration}")"
    x86_binary="$(build_binary "x86_64-apple-macosx14.0" ".build/x86_64-${configuration}")"
    lipo -create -output "${macos_dir}/UltraTermComputerUse" "${arm_binary}" "${x86_binary}"
    ;;
esac

chmod +x "${macos_dir}/UltraTermComputerUse"

if [[ ! -f "${icon_master_png}" ]]; then
  echo "Missing icon master PNG: ${icon_master_png}" >&2
  exit 1
fi

if [[ ! -f "${iconset_build_script}" ]]; then
  echo "Missing iconset build script: ${iconset_build_script}" >&2
  exit 1
fi


icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ultraterm-computer-use-icon.XXXXXX")"
cleanup() {
  if [[ -n "${icon_work_dir:-}" ]]; then
    rm -rf "${icon_work_dir}"
  fi
}
trap cleanup EXIT
iconset_dir="${icon_work_dir}/UltraTermComputerUse.iconset"
mkdir -p "${iconset_dir}"
"${iconset_build_script}" "${icon_master_png}" "${iconset_dir}"
iconutil -c icns "${iconset_dir}" -o "${resources_dir}/${bundle_icon_name}"

bundle_build_identifier="$(uuidgen)"
cat > "${contents_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>UltraTermComputerUse</string>
  <key>CFBundleIconFile</key>
  <string>${bundle_icon_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_identifier}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${bundle_display_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${bundle_display_name}</string>
  <key>UltraTermComputerUseBuildIdentifier</key>
  <string>${bundle_build_identifier}</string>
  <key>UltraTermComputerUseAppVariant</key>
  <string>${app_variant}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${package_version}</string>
  <key>CFBundleVersion</key>
  <string>${bundle_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>UltraTerm Computer Use reads on-screen pixels only while a screenshot, preview, or recording is running.</string>
</dict>
</plist>
PLIST

locked_use_requested="${ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE:-auto}"
locked_use_identity="$(resolve_codesign_identity || true)"
# Locked Use installs a root service and a login authorization plug-in, so it is bundled only
# when a build asks for it with ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE=1.
if [[ "$locked_use_requested" == auto ]]; then
  locked_use_requested=0
fi
if [[ "$locked_use_requested" == 1 ]]; then
  if [[ -z "$locked_use_identity" || "$locked_use_identity" == - ]]; then
    echo 'Locked Use requires an Apple signing identity; refusing an incomplete release.' >&2
    exit 1
  fi
  scripts/build-locked-use-components.sh --configuration "$configuration" --arch "$arch_mode" --identity "$locked_use_identity"
  locked_use_components="${repo_root}/.build/locked-use/components"
  guardian_component="OCU Guardian (Dev).app"
  if [[ "${app_variant}" == release ]]; then
    locked_use_components="${repo_root}/.build/locked-use/components-release"
    guardian_component="OCU Guardian.app"
  fi
  if [[ "$arch_mode" != native ]]; then locked_use_components="$locked_use_components-$arch_mode"; fi
  mkdir -p "${resources_dir}/LockedUse"
  for component in OCULockService OCULockInstaller OCULockAuth.bundle; do
    ditto "${locked_use_components}/${component}" "${resources_dir}/LockedUse/${component}"
  done
  ditto "${locked_use_components}/${guardian_component}" "${resources_dir}/LockedUse/OCU Guardian.app"
fi

plutil -lint "${contents_dir}/Info.plist" >/dev/null
codesign_app_bundle "${app_root}"
if [[ "$locked_use_requested" == 1 ]]; then
  scripts/verify-locked-use-bundle.sh "$app_root"
fi

echo "Built ${app_root} (${arch_mode}, ${configuration})"
