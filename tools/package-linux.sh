#!/usr/bin/env bash
# Packs the built Linux app (tools/desktop-build.sh) into the download
# offered on the release page:
#
#   tools/package-linux.sh <version> [out-dir]   ->  fweek-<version>-linux-x64.tar.gz
#
# The archive holds the app (bundle/), its icons, and tools/install-local.sh
# as install.sh, which puts it in ~/.local/opt/fweek with a menu entry.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?version}"
out="${2:-$root/dist}"
bundle="$root/build/linux/x64/release/bundle"
[ -x "$bundle/fweek" ] || { echo "No release build; run tools/desktop-build.sh" >&2; exit 1; }
name="fweek-$version-linux-x64"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name/icons" "$out"
cp -r "$bundle" "$stage/$name/bundle"
cp "$root"/assets/icon/fweek-{48,64,128,256,512}.png "$stage/$name/icons/"
cp "$root/tools/install-local.sh" "$stage/$name/install.sh"
cp "$root/LICENSE" "$stage/$name/"
cat > "$stage/$name/README.txt" <<TEXT
fweek $version for Linux (x86-64)

Install for your user (no root needed), or update an earlier install:

    ./install.sh

fweek then appears in the application menu. Remove it with
./install.sh --uninstall; your planner stays in
~/.local/share/io.github.yourj4m.weektodo.

Or run it from here without installing: bundle/fweek

Needs GTK 3 and, to keep sync passwords, a keyring (GNOME Keyring,
KWallet or another Secret Service), as most desktops have.
TEXT
tar -C "$stage" -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
