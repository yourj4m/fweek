#!/usr/bin/env bash
# Build the Android app as a signed release APK.
#
#   tools/android-build.sh              phone build (64-bit ARM)
#   tools/android-build.sh --install    ... and install it on the phone plugged in over USB
#   tools/android-build.sh --emulator   build for the emulator (x86-64) instead
#
# The APK is signed with a key of your own, created on first use and kept
# outside the repository in ~/.config/weektodo/. Android only installs an
# update over an app signed with the same key, so keep that folder: without
# it the app has to be removed (losing unsynced data) before a new build
# installs. Back the folder up if the phone's planner is not synced.
#
# --install needs USB debugging switched on (Settings > System > Developer
# options) and the computer accepted on the phone's prompt.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev="$root/tools/dev"
keys="${XDG_CONFIG_HOME:-$HOME/.config}/weektodo"
store="$keys/android-release.jks"
secret="$keys/android-release.password"

if [ ! -f "$store" ]; then
  mkdir -p "$keys"; chmod 700 "$keys"
  (umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$secret")
  "$dev" keytool -genkeypair -keystore "$store" -storetype PKCS12 \
    -storepass:file "$secret" -alias weektodo -keyalg RSA -keysize 4096 \
    -validity 36500 -dname "CN=WeekToDo personal build"
  chmod 600 "$store"
  echo "Created the signing key in $keys - keep this folder."
fi
# Gradle reads the signing details from here (git-ignored).
(umask 077; cat > "$root/android/key.properties" <<PROPS
storeFile=$store
storePassword=$(cat "$secret")
keyAlias=weektodo
keyPassword=$(cat "$secret")
PROPS
)

platform=android-arm64; abi=arm64-v8a
[ "${1:-}" = "--emulator" ] && { platform=android-x64; abi=x86_64; }
# The build number counts commits, so every build made later is an update
# in Android's eyes and never a downgrade, which it would refuse.
number="$(git -C "$root" rev-list --count HEAD)"
# What earlier builds kept is thrown away first: the icon font cut down to
# the icons in use was not always made again when the code used more (see
# tools/desktop-build.sh).
rm -rf "$root/.dart_tool/flutter_build" "$root/build/flutter_assets"
"$dev" flutter build apk --release --split-per-abi --target-platform "$platform" \
  --build-number "$number"
apk="$root/build/app/outputs/flutter-apk/app-$abi-release.apk"
echo "Built $apk ($(du -h "$apk" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  "$dev" adb install -r "$apk"
  echo "Installed. Find WeekToDo in the phone's app list."
fi
