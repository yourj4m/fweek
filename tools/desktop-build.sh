#!/usr/bin/env bash
# Build the desktop app (Linux, release) into build/linux/x64/release/bundle.
#
#   tools/desktop-build.sh        build
#   tools/install-local.sh        ... then install it for the current user
#
# A release build cuts the icon font down to the icons the code uses. The
# cut font is kept between builds, and it was not made again when the code
# came to use more icons: those then drew as blanks in the installed app
# while every test (which uses the whole font) passed. So what is kept from
# earlier builds is thrown away first; the build takes a little longer.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rm -rf "$root/.dart_tool/flutter_build" "$root/build/flutter_assets" \
  "$root/build/linux/x64/release/bundle/data/flutter_assets"
"$root/tools/dev" flutter build linux --release
