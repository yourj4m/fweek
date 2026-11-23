#!/usr/bin/env bash
# One-time setup of the build environment on Fedora, without root and without
# installing development packages on the host:
#
#   - a toolbox container "fweek-dev" with the compiler toolchain, GTK
#     headers and a headless Wayland compositor for the smoke test
#   - the pinned Flutter SDK under .tools/sdk-<version> (git-ignored)
#
# Afterwards run everything through tools/dev, for example:
#   tools/dev flutter test
#   tools/desktop-build.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="${FWEEK_CONTAINER:-fweek-dev}"

command -v toolbox >/dev/null || { echo "toolbox is required (dnf install toolbox)"; exit 1; }

if ! toolbox list --containers 2>/dev/null | grep -qw "$container"; then
  toolbox create --assumeyes "$container"
fi
toolbox run -c "$container" sudo dnf install -y --setopt=install_weak_deps=False \
  clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel \
  git curl unzip xz zip which file procps-ng binutils \
  mesa-dri-drivers mesa-libGL mesa-libEGL google-noto-emoji-color-fonts \
  sway grim ImageMagick python3-pywayland libxkbcommon-utils \
  libsecret-devel libsecret gnome-keyring dbus-daemon

# The Flutter release is pinned; see "Flutter version" in the README.
version="$(cat "$root/tools/flutter-version")"
sdk="$root/.tools/sdk-$version"
if [ ! -x "$sdk/flutter/bin/flutter" ]; then
  mkdir -p "$root/.tools/dl" "$sdk"
  cd "$root/.tools/dl"
  curl -fsSL -o releases_linux.json \
    https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
  read -r url sha < <(python3 - "$version" <<'PY'
import json, sys
d = json.load(open("releases_linux.json"))
r = next(x for x in d["releases"] if x["channel"] == "stable" and x["version"] == sys.argv[1])
print(d["base_url"] + "/" + r["archive"], r["sha256"])
PY
)
  curl -fSL --retry 3 -o flutter.tar.xz "$url"
  echo "$sha  flutter.tar.xz" | sha256sum -c -
  tar -xJf flutter.tar.xz -C "$sdk"
  rm -f flutter.tar.xz
fi

"$root/tools/dev" flutter --disable-analytics
"$root/tools/dev" dart --disable-analytics
"$root/tools/dev" flutter config --no-cli-animations --enable-linux-desktop
"$root/tools/dev" flutter pub get
"$root/tools/dev" flutter doctor
