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
# The Google sign-in client for Google Drive sync, if one is set up: the
# JSON file Google Cloud offers for a "Desktop app" client, saved as
# ~/.config/fweek/google-oauth.json (outside the repository). Without it
# the build offers Nextcloud only.
google_defines=()
google_file="${FWEEK_GOOGLE_OAUTH:-$HOME/.config/fweek/google-oauth.json}"
if [ -f "$google_file" ]; then
  read -r google_id google_secret < <(python3 - "$google_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
client = data.get("installed") or data.get("web") or data
print(client.get("client_id", ""), client.get("client_secret", ""))
PY
)
  if [ -n "$google_id" ] && [ -n "$google_secret" ]; then
    google_defines=(--dart-define="FWEEK_GOOGLE_CLIENT_ID=$google_id"
                    --dart-define="FWEEK_GOOGLE_CLIENT_SECRET=$google_secret")
    echo "Google Drive sync: client from $google_file"
  fi
fi
"$root/tools/dev" flutter build linux --release "${google_defines[@]}"
