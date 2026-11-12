#!/usr/bin/env bash
set -euo pipefail

# Tests for scripts/install.sh and scripts/install.ps1 against a local release fixture.
#
# Usage:
#   UTCU_TEST_TARBALL=/path/to/ultraterm-computer-use-X.Y.Z.tgz scripts/test-install.sh [--linux-container] [--pwsh-container]
#
# The tarball must be a real published release tarball (download it from the repository's GitHub release).
# The fixture is served with a short-lived python3 http.server on UTCU_TEST_PORT (default 18791).
# Container phases use Docker Desktop's host.docker.internal to reach that server, one container at a time.
# UTCU_TEST_PWSH_IMAGE / UTCU_TEST_PWSH_PLATFORM override the PowerShell image (for example
# mcr.microsoft.com/powershell:amd64 with --platform linux/amd64 when no native arm64 image is present).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tarball="${UTCU_TEST_TARBALL:-}"
port="${UTCU_TEST_PORT:-18791}"
run_linux=0
run_pwsh=0
for arg in "$@"; do
  case "$arg" in
    --linux-container) run_linux=1 ;;
    --pwsh-container) run_pwsh=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ -n "$tarball" && -f "$tarball" ]] || { echo "set UTCU_TEST_TARBALL to a published release tarball" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required to serve the fixture" >&2; exit 1; }

name="$(basename "$tarball")"
version="${name#ultraterm-computer-use-}"; version="${version%.tgz}"
# The work dir lives under the repo's gitignored dist/ so Docker Desktop can mount it (shared path).
mkdir -p "$repo_root/dist"
work="$(mktemp -d "$repo_root/dist/test-install.XXXXXX")"
fixture="$work/rel"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 15); do
      if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$port))==0 else 1)"; then
        sleep 1
      else
        break
      fi
    done
    if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$port))==0 else 1)"; then
      echo "warning: port $port still accepts connections" >&2
    else
      echo "fixture server stopped; port $port released"
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$fixture"
cp "$tarball" "$fixture/$name"
cp "$repo_root/scripts/install.sh" "$repo_root/scripts/install.ps1" "$fixture/"
(cd "$fixture" && shasum -a 256 "$name" > SHA256SUMS)

python3 -m http.server "$port" --bind 0.0.0.0 --directory "$fixture" >"$work/server.log" 2>&1 &
server_pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 1 30); do
  curl -fsS "$base/SHA256SUMS" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$base/SHA256SUMS" >/dev/null || { echo "fixture server did not start on port $port" >&2; exit 1; }
echo "fixture served at $base (version $version)"

npm_flag=()
[[ "$(uname -s)" == "Darwin" ]] && npm_flag=(--npm)

install_local() { # install_local <home>
  local h="$1"
  mkdir -p "$h"
  HOME="$h" UTCU_HOME="$h/.utcu" UTCU_BIN_DIR="$h/bin" UTCU_RELEASE_BASE="$base" \
    sh "$repo_root/scripts/install.sh" ${npm_flag[@]+"${npm_flag[@]}"}
}

expect_version() { # expect_version <home>
  local h="$1" got
  got="$(HOME="$h" "$h/bin/ultraterm-computer-use" --version)"
  [[ "$got" == "$version" ]] || { echo "expected version $version, got '$got'" >&2; exit 1; }
}

corrupt_fixture() { printf 'corruption' >> "$fixture/$name"; }
restore_fixture() { cp "$tarball" "$fixture/$name"; }

echo "== local: install, version, upgrade re-run =="
h1="$work/home1"
install_local "$h1"
expect_version "$h1"
install_local "$h1"
expect_version "$h1"
echo "local install and upgrade OK"

echo "== local: corrupted archive refused =="
corrupt_fixture
h2="$work/home2"
if out="$(install_local "$h2" 2>&1)"; then
  echo "corrupted archive was accepted" >&2; exit 1
fi
grep -q "checksum mismatch" <<<"$out" || { echo "wrong error: $out" >&2; exit 1; }
[[ ! -e "$h2/.utcu" ]] || { echo "corrupted run left an install behind" >&2; exit 1; }
restore_fixture
echo "corrupted archive refused with checksum error; nothing installed"

echo "== local: missing prerequisite named =="
mkdir -p "$work/emptybin"
if out="$(HOME="$work/home3" PATH="$work/emptybin" /bin/sh "$repo_root/scripts/install.sh" 2>&1)"; then
  echo "missing prerequisite was not detected" >&2; exit 1
fi
grep -q "needs curl or wget" <<<"$out" || { echo "wrong error: $out" >&2; exit 1; }
echo "missing prerequisite named: $out"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== macOS: default branch points at the signed pkg =="
  h4="$work/home4"; mkdir -p "$h4"
  out="$(HOME="$h4" UTCU_HOME="$h4/.utcu" UTCU_BIN_DIR="$h4/bin" UTCU_RELEASE_BASE="$base" \
    sh "$repo_root/scripts/install.sh")"
  if ! { grep -q "signed" <<<"$out" && grep -q -- "--npm" <<<"$out" && grep -q "Nothing was installed" <<<"$out"; }; then
    echo "macOS branch message wrong: $out" >&2; exit 1
  fi
  [[ ! -e "$h4/.utcu" && ! -e "$h4/bin" ]] || { echo "macOS default branch installed something" >&2; exit 1; }
  echo "macOS default branch OK (message only, nothing installed)"
fi

container_base="http://host.docker.internal:$port"
pwsh_image="${UTCU_TEST_PWSH_IMAGE:-mcr.microsoft.com/powershell}"
pwsh_platform_args=()
[[ -n "${UTCU_TEST_PWSH_PLATFORM:-}" ]] && pwsh_platform_args=(--platform "$UTCU_TEST_PWSH_PLATFORM")

if [[ "$run_linux" -eq 1 ]]; then
  echo "== Linux container: fetch-Node install, upgrade, system-Node install =="
  docker run --rm --name ultraterm-computer-use-test-linux \
    -e UTCU_TEST_BASE="$container_base" -v "$fixture:/rel:ro" ubuntu:24.04 bash -eu -c '
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends curl tar ca-certificates >/dev/null
    echo "-- no system Node: installer must fetch the official Node --"
    UTCU_RELEASE_BASE="$UTCU_TEST_BASE" sh /rel/install.sh
    test "$(~/.local/bin/ultraterm-computer-use --version)" = "'"$version"'"
    UTCU_RELEASE_BASE="$UTCU_TEST_BASE" sh /rel/install.sh
    test "$(~/.local/bin/ultraterm-computer-use --version)" = "'"$version"'"
    echo "-- system Node from apt --"
    apt-get install -y -qq --no-install-recommends nodejs npm >/dev/null
    UTCU_HOME=/root/.utcu-system UTCU_BIN_DIR=/root/bin2 UTCU_RELEASE_BASE="$UTCU_TEST_BASE" sh /rel/install.sh
    test "$(/root/bin2/ultraterm-computer-use --version)" = "'"$version"'"
    grep -q "^exec \"/.*node\" " /root/bin2/ultraterm-computer-use || { echo "system-Node shim must embed the absolute node"; exit 1; }
    test "$(ls /root/.utcu-system/app | grep -c "^release-")" = 1
    echo "foreign command is refused and left alone"
    printf "#!/bin/sh\necho mine\n" > /root/bin3file; mkdir -p /root/bin3; cp /root/bin3file /root/bin3/ultraterm-computer-use
    if UTCU_HOME=/root/.utcu-foreign UTCU_BIN_DIR=/root/bin3 UTCU_RELEASE_BASE="$UTCU_TEST_BASE" sh /rel/install.sh; then echo "foreign command was replaced"; exit 1; fi
    test "$(cat /root/bin3/ultraterm-computer-use)" = "#!/bin/sh
echo mine"
    test ! -e /root/.utcu-foreign/app || test -z "$(ls /root/.utcu-foreign/app)"
    echo "Linux container install, upgrade, and system-Node paths OK"
  '
  echo "== Linux container: corrupted archive refused =="
  corrupt_fixture
  if out="$(docker run --rm --name ultraterm-computer-use-test-linux-corrupt \
      -e UTCU_RELEASE_BASE="$container_base" -v "$fixture:/rel:ro" ubuntu:24.04 \
      bash -eu -c 'apt-get update -qq >/dev/null; apt-get install -y -qq --no-install-recommends curl tar ca-certificates >/dev/null; sh /rel/install.sh' 2>&1)"; then
    echo "corrupted archive was accepted in the Linux container" >&2; exit 1
  fi
  grep -q "checksum mismatch" <<<"$out" || { echo "wrong error: $out" >&2; exit 1; }
  restore_fixture
  echo "Linux container corrupted archive refused"
fi

if [[ "$run_pwsh" -eq 1 ]]; then
  echo "== pwsh container: install (fetch Node), version, upgrade =="
  docker run --rm --name ultraterm-computer-use-test-pwsh \
    ${pwsh_platform_args[@]+"${pwsh_platform_args[@]}"} \
    -e UTCU_RELEASE_BASE="$container_base" -v "$fixture:/rel:ro" "$pwsh_image" \
    pwsh -NoProfile -c '
      $ErrorActionPreference = "Stop"
      & /rel/install.ps1
      $v = (& "$HOME/.local/bin/ultraterm-computer-use" --version | Out-String).Trim()
      if ($v -ne "'"$version"'") { throw "version mismatch: $v" }
      & /rel/install.ps1
      $v = (& "$HOME/.local/bin/ultraterm-computer-use" --version | Out-String).Trim()
      if ($v -ne "'"$version"'") { throw "version mismatch after upgrade: $v" }
      Write-Host "pwsh install and upgrade OK"
    '
  echo "== pwsh container: helper unit tests =="
  docker run --rm --name ultraterm-computer-use-test-pwsh-units \
    ${pwsh_platform_args[@]+"${pwsh_platform_args[@]}"} \
    -v "$repo_root/test:/t:ro" -v "$fixture:/rel:ro" "$pwsh_image" \
    pwsh -NoProfile -File /t/installer-units.ps1 /rel/install.ps1
  echo "== pwsh container: relative HOME/BIN overrides, same-version re-run, foreign shim =="
  docker run --rm --name ultraterm-computer-use-test-pwsh-rel \
    ${pwsh_platform_args[@]+"${pwsh_platform_args[@]}"} \
    -e UTCU_RELEASE_BASE="$container_base" -v "$fixture:/rel:ro" "$pwsh_image" \
    pwsh -NoProfile -c '
      $ErrorActionPreference = "Stop"
      Set-Location /tmp
      $env:UTCU_HOME = "./relhome/../relhome"; $env:UTCU_BIN_DIR = "relbin"
      & /rel/install.ps1
      & /rel/install.ps1
      $rels = @(Get-ChildItem /tmp/relhome/app -Directory -Filter "release-*")
      if ($rels.Count -ne 1) { throw "expected one release folder, found $($rels.Count)" }
      $v = (& /tmp/relbin/ultraterm-computer-use --version | Out-String).Trim()
      if ($v -ne "'"$version"'") { throw "relative-override install broken: $v" }
      if ((Get-Content /tmp/relbin/ultraterm-computer-use -Raw) -notmatch "(?m)^exec .+/node") { throw "shim must embed the absolute node" }
      $env:UTCU_HOME = "/tmp/foreignhome"; $env:UTCU_BIN_DIR = "/tmp/foreignbin"
      New-Item -ItemType Directory /tmp/foreignbin | Out-Null
      Set-Content /tmp/foreignbin/ultraterm-computer-use "#!/bin/sh`necho mine"
      $threw = $false; try { & /rel/install.ps1 } catch { $threw = "$_" -match "refusing" }
      if (-not $threw) { throw "foreign command was not refused" }
      if (Test-Path /tmp/foreignhome/app) { throw "refused run left a release behind" }
      if ($ErrorActionPreference -ne "Stop") { throw "installer must restore the preference" }
      Write-Host "pwsh relative overrides, re-run and refusal OK"
    '
  echo "== pwsh container: corrupted archive refused =="
  corrupt_fixture
  if out="$(docker run --rm --name ultraterm-computer-use-test-pwsh-corrupt \
      ${pwsh_platform_args[@]+"${pwsh_platform_args[@]}"} \
      -e UTCU_RELEASE_BASE="$container_base" -v "$fixture:/rel:ro" "$pwsh_image" \
      pwsh -NoProfile -c '& /rel/install.ps1' 2>&1)"; then
    echo "corrupted archive was accepted under pwsh" >&2; exit 1
  fi
  grep -q "checksum mismatch" <<<"$out" || { echo "wrong error: $out" >&2; exit 1; }
  restore_fixture
  echo "pwsh corrupted archive refused"
fi

echo "All requested installer tests passed."