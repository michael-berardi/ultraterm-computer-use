#!/usr/bin/env bash
# Copy install.sh, install.ps1 and install-ultraterm-computer-use.sh (the macOS .pkg route) into <outdir> with the real GitHub owner/repo in place of the shipped
# placeholder. The owner/repo comes from ULTRATERM_COMPUTER_USE_RELEASE_REPO or the origin remote
# (https and ssh forms, with or without .git). Fails if a placeholder survives.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:?usage: stamp-installers.sh <outdir>}"
placeholder="your-org/ultraterm-computer-use"

slug="${ULTRATERM_COMPUTER_USE_RELEASE_REPO:-}"
if [[ -z "$slug" ]]; then
  slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null |
    sed -E -n 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$#\2/\3#p' |
    sed 's#\.git$##')" || true
fi
printf '%s\n' "$slug" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ||
  { echo "stamp-installers: cannot tell the GitHub owner/repo; set ULTRATERM_COMPUTER_USE_RELEASE_REPO=owner/repo (or add a GitHub origin remote)" >&2; exit 1; }
[[ "$slug" != "$placeholder" ]] || { echo "stamp-installers: the owner/repo is still the placeholder" >&2; exit 1; }

mkdir -p "$out"
for f in install.sh install.ps1 install-ultraterm-computer-use.sh; do
  sed "s#$placeholder#$slug#g" "$repo_root/scripts/$f" > "$out/$f"
  if grep -q "$placeholder" "$out/$f"; then echo "stamp-installers: $f still has the placeholder owner" >&2; exit 1; fi
  if ! grep -q "$slug" "$out/$f"; then echo "stamp-installers: $f was not stamped with $slug" >&2; exit 1; fi
done
chmod 755 "$out/install.sh" "$out/install-ultraterm-computer-use.sh"
echo "stamp-installers: release URLs point at github.com/$slug"
