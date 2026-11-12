#!/bin/sh
# UltraTerm Computer Use installer:  curl -fsSL https://github.com/your-org/ultraterm-computer-use/releases/latest/download/install.sh | sh
# Linux: downloads the release npm tarball (native Go runtimes for linux-x64 and linux-arm64), checks its SHA-256,
# installs it under one folder in your home, and puts `ultraterm-computer-use` on your PATH.
# macOS: the signed UltraTerm-Computer-Use.pkg is the supported route; this script points at it and installs nothing,
# unless you pass --npm to install the npm package into your home folder instead (never touches /Applications).
# Uses the Node 18+ already on this machine, or fetches the official Node 22 LTS into the tool's own folder.
# Environment: UTCU_HOME (default ~/.ultraterm-computer-use), UTCU_BIN_DIR (default ~/.local/bin),
# UTCU_VERSION (pin a version, e.g. 0.7.0), UTCU_RELEASE_BASE (override the download base URL, used by tests).
set -eu

REPO="your-org/ultraterm-computer-use"
NODE_MIN_MAJOR=18
HOME_DIR="${UTCU_HOME:-$HOME/.ultraterm-computer-use}"
case "$HOME_DIR" in /*) ;; *) HOME_DIR="$(pwd)/$HOME_DIR" ;; esac
APP="$HOME_DIR/app"
RUNTIME="$HOME_DIR/runtime"
BIN_DIR="${UTCU_BIN_DIR:-$HOME/.local/bin}"
case "$BIN_DIR" in /*) ;; *) BIN_DIR="$(pwd)/$BIN_DIR" ;; esac
if [ -n "${UTCU_RELEASE_BASE:-}" ]; then BASE="$UTCU_RELEASE_BASE"
elif [ -n "${UTCU_VERSION:-}" ]; then BASE="https://github.com/$REPO/releases/download/v${UTCU_VERSION#v}"
else BASE="https://github.com/$REPO/releases/latest/download"; fi

say() { printf '%s\n' "$*"; }
die() { printf 'ultraterm-computer-use install: %s\n' "$*" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then fetch() { curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"; }
elif command -v wget >/dev/null 2>&1; then fetch() { wget -q -O "$2" "$1" || die "download failed: $1"; }
else die "needs curl or wget; install one with your package manager (for example: apt-get install curl)"; fi
command -v tar >/dev/null 2>&1 || die "needs tar; install it with your package manager (for example: apt-get install tar)"

if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "needs sha256sum or shasum"; fi

main() {
NPM_ROUTE=0
for arg in "$@"; do
  case "$arg" in
    --npm) NPM_ROUTE=1 ;;
    -h|--help)
      say "Usage: install.sh [--npm]"
      say "Linux: installs the release npm package under $HOME_DIR."
      say "macOS: prints the signed .pkg installer route; --npm installs the npm package under $HOME_DIR instead."
      exit 0 ;;
    *) die "unknown option: $arg (supported: --npm, --help)" ;;
  esac
done

if [ "$(uname -s)" = "Darwin" ] && [ "$NPM_ROUTE" -eq 0 ]; then
  say "On macOS, UltraTerm Computer Use ships as a signed and notarized installer package."
  say "Install it with the signed route (verifies checksum, signature, and notarization):"
  say "  f=\$(mktemp) && curl -fsSLo \"\$f\" $BASE/install-ultraterm-computer-use.sh && bash \"\$f\"; rm -f \"\$f\""
  say "Or re-run this script with --npm to install the npm package under $HOME_DIR instead."
  say "Nothing was installed."
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/utcu-install.XXXXXX") || die "cannot create a temporary folder"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# expect <file> <name> <sums-file>: the file's SHA-256 must equal the line for <name> in the sums file.
expect() {
  want=$(awk -v n="$2" '{ f=$2; sub(/^\*/, "", f); if (f == n) print $1 }' "$3")
  [ -n "$want" ] || die "no checksum for $2 in $(basename "$3")"
  [ "$(sha256 "$1")" = "$want" ] || die "checksum mismatch for $2; nothing was installed"
}

node_ok() { # node_ok <node-binary>
  v=$("$1" -p 'process.versions.node' 2>/dev/null) || return 1
  major=${v%%.*}
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

say "Downloading UltraTerm Computer Use release info..."
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
if [ -n "${UTCU_VERSION:-}" ]; then
  TARBALL="ultraterm-computer-use-${UTCU_VERSION#v}.tgz"
else
  TARBALL=$(awk '{ f=$2; sub(/^\*/, "", f); if (f ~ /^ultraterm-computer-use-[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?\.tgz$/) print f }' "$TMP/SHA256SUMS")
  count=$(printf '%s\n' "$TARBALL" | grep -c . || true)
  [ "$count" -eq 1 ] || die "SHA256SUMS lists $count release tarballs; set UTCU_VERSION to pick one"
fi
fetch "$BASE/$TARBALL" "$TMP/$TARBALL"
expect "$TMP/$TARBALL" "$TARBALL" "$TMP/SHA256SUMS"

tar -xzf "$TMP/$TARBALL" -C "$TMP" package/package.json || die "cannot unpack the download"
[ -f "$TMP/package/package.json" ] || die "the download is not an UltraTerm Computer Use release"
VERSION=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/package/package.json" | head -n 1)
[ -n "$VERSION" ] || die "cannot read the release version"
[ "$TARBALL" = "ultraterm-computer-use-$VERSION.tgz" ] || die "release name $TARBALL does not match its version $VERSION"

# Node: the one on PATH when it is new enough, else the official build, kept inside the tool's own folder.
NODE_BIN=""
if command -v node >/dev/null 2>&1 && node_ok "$(command -v node)"; then
  NODE_BIN=$(command -v node)
else
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) die "unsupported system $(uname -s); on Windows use install.ps1" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) die "unsupported CPU $(uname -m)" ;; esac
  for d in "$RUNTIME"/node-*-"$os"-"$arch"; do
    if [ -x "$d/bin/node" ] && node_ok "$d/bin/node"; then NODE_BIN="$d/bin/node"; break; fi
  done
  if [ -z "$NODE_BIN" ]; then
    ls /lib/ld-musl-* >/dev/null 2>&1 && die "this system uses musl (Alpine): install Node 18+ with its package manager (apk add nodejs npm), then run this again"
    say "Node $NODE_MIN_MAJOR or newer not found; fetching the official Node 22 LTS for $os-$arch..."
    nbase="https://nodejs.org/dist/latest-v22.x"
    fetch "$nbase/SHASUMS256.txt" "$TMP/NODESUMS"
    nname=$(awk -v s="-$os-$arch.tar.gz" 'index($2, s) { print $2 }' "$TMP/NODESUMS" | head -n 1)
    [ -n "$nname" ] || die "no official Node build for $os-$arch"
    fetch "$nbase/$nname" "$TMP/$nname"
    expect "$TMP/$nname" "$nname" "$TMP/NODESUMS"
    nver=${nname#node-}; nver=${nver%%-*}
    mkdir -p "$RUNTIME"
    NODE_DIR="$RUNTIME/node-$nver-$os-$arch"
    rm -rf "$NODE_DIR.tmp"; mkdir "$NODE_DIR.tmp"
    tar -xzf "$TMP/$nname" -C "$NODE_DIR.tmp" --strip-components=1 || die "cannot unpack Node"
    rm -rf "$NODE_DIR"; mv "$NODE_DIR.tmp" "$NODE_DIR"
    NODE_BIN="$NODE_DIR/bin/node"
    node_ok "$NODE_BIN" || die "the downloaded Node does not run on this machine"
  fi
fi
NODE_DIRNAME=$(dirname "$NODE_BIN")
PATH="$NODE_DIRNAME:$PATH"; export PATH
npm_ok() { # npm_ok <npm-path>: a working npm prints a version like 10.2.3
  v=$("$1" --version 2>/dev/null) || return 1
  case "$v" in [0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac
}
NPM="$NODE_DIRNAME/npm"
if ! npm_ok "$NPM"; then
  NPM=""
  if command -v npm >/dev/null 2>&1; then
    cand=$(command -v npm)
    npm_ok "$cand" && NPM="$cand"
  fi
  [ -n "$NPM" ] || die "no working npm found next to Node ($NODE_DIRNAME) or on PATH; install Node 18+ with npm"
fi

# Never overwrite a command this installer did not write (checked before anything is moved into place).
SHIM="$BIN_DIR/ultraterm-computer-use"
if [ -e "$SHIM" ] || [ -L "$SHIM" ]; then
  if ! grep -q 'UTCU_NPM_SHIM' "$SHIM" 2>/dev/null; then
    if grep -q 'ULTRATERM_COMPUTER_USE_MANAGED_SHIM' "$SHIM" 2>/dev/null; then
      die "the signed macOS installer already manages $SHIM; remove that shim first or set UTCU_BIN_DIR to another folder"
    fi
    die "refusing to replace existing command at $SHIM (not written by this installer); remove it first or set UTCU_BIN_DIR to another folder"
  fi
fi

say "Installing UltraTerm Computer Use $VERSION..."
STAGE="$TMP/stage"
mkdir -p "$STAGE"
( cd "$STAGE" && npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false \
    "$NPM" install --prefix "$STAGE" --no-audit --no-fund --loglevel=error "$TMP/$TARBALL" </dev/null ) \
  || die "npm install failed; nothing was changed"
LAUNCHER="$STAGE/node_modules/ultraterm-computer-use/bin/ultraterm-computer-use"
[ -f "$LAUNCHER" ] || die "the package did not install its launcher; nothing was changed"
got=$("$NODE_BIN" "$LAUNCHER" --version 2>&1 </dev/null) || die "the new copy does not start: $got"
case "$got" in "$VERSION") ;; *) die "the new copy reports '$got', not $VERSION; nothing was changed" ;; esac

mkdir -p "$APP" "$BIN_DIR"
# Each install gets its own folder, so re-running the same version never removes the live release.
REL="$APP/release-$VERSION-$$"
mv "$STAGE" "$REL"
LAUNCHER="$REL/node_modules/ultraterm-computer-use/bin/ultraterm-computer-use"

# Always the absolute node: MCP hosts started from a GUI often have no node on PATH.
case "$NODE_BIN" in /*) ;; *) NODE_BIN="$(pwd)/$NODE_BIN" ;; esac
SHIM_NODE="\"$NODE_BIN\""
cat > "$SHIM.tmp.$$" <<SHIM
#!/bin/sh
# UTCU_NPM_SHIM
exec $SHIM_NODE "$LAUNCHER" "\$@"
SHIM
chmod 755 "$SHIM.tmp.$$"
mv -f "$SHIM.tmp.$$" "$SHIM"

# Keep only the release that the shim points at.
for d in "$APP"/release-*; do
  [ -d "$d" ] || continue
  [ "$d" = "$REL" ] || rm -rf "$d" || true
done

got=$("$SHIM" --version 2>&1 </dev/null) || die "the installed command does not run: $got"
case "$got" in "$VERSION") ;; *) die "the installed command reports '$got', not $VERSION" ;; esac
say "UltraTerm Computer Use $got installed ($SHIM)."
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Add $BIN_DIR to your PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
if [ "$(uname -s)" = "Linux" ]; then
  health=$("$SHIM" doctor 2>&1 </dev/null) || die "the health check (doctor) failed: $health"
  say "$health"
  say "Next: ultraterm-computer-use list-apps"
else
  # macOS doctor opens the permission onboarding, so the installer leaves it to the user.
  say "Next: ultraterm-computer-use doctor   (grants Accessibility and Screen Recording on macOS)"
fi
}

main "$@"