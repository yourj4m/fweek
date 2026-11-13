#!/usr/bin/env bash
# One-time setup for building the Android app, on top of tools/setup-dev.sh.
# Nothing is installed on the host; everything lands in the weektodo-dev
# container or under .tools/ (git-ignored):
#
#   - a JDK in the container
#   - the Android SDK (platform, build tools, adb) in .tools/android-sdk
#   - with --emulator: the emulator and a system image, for tools/android-smoke.sh
#
#   tools/setup-android.sh [--emulator]
#
# Installing SDK packages means accepting Google's Android SDK licence terms
# (https://developer.android.com/studio/terms); the script accepts them for
# you.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="${WEEKTODO_CONTAINER:-weektodo-dev}"
sdk="$root/.tools/android-sdk"

# Command-line tools release and its SHA-256, from
# https://developer.android.com/studio#command-line-tools-only
tools_build=15859902
tools_sha=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
# The SDK level the pinned Flutter release compiles against, and the image
# the emulator runs (plain Android without Google services, like LineageOS).
platform=android-36
build_tools=36.0.0
image="system-images;android-36;default;x86_64"

toolbox run -c "$container" sudo dnf install -y --setopt=install_weak_deps=False \
  java-25-openjdk-devel unzip

if [ ! -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$root/.tools/dl" "$sdk/cmdline-tools"
  zip="$root/.tools/dl/cmdline-tools.zip"
  curl -fSL --retry 3 -o "$zip" \
    "https://dl.google.com/android/repository/commandlinetools-linux-${tools_build}_latest.zip"
  echo "$tools_sha  $zip" | sha256sum -c -
  rm -rf "$sdk/cmdline-tools/latest" "$sdk/cmdline-tools/cmdline-tools"
  unzip -q "$zip" -d "$sdk/cmdline-tools"
  mv "$sdk/cmdline-tools/cmdline-tools" "$sdk/cmdline-tools/latest"
  rm -f "$zip"
fi

yes | "$root/tools/dev" sdkmanager --licenses >/dev/null || true
"$root/tools/dev" sdkmanager --install "platform-tools" "platforms;$platform" "build-tools;$build_tools"

if [ "${1:-}" = "--emulator" ]; then
  "$root/tools/dev" sdkmanager --install "emulator" "$image"
  if ! "$root/tools/dev" avdmanager list avd -c | grep -qx weektodo; then
    echo no | "$root/tools/dev" avdmanager create avd --name weektodo \
      --package "$image" --device pixel_6
  fi
fi

"$root/tools/dev" flutter config --enable-android
"$root/tools/dev" flutter doctor
