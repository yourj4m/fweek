#!/usr/bin/env bash
# Install the built app for the current user: copies the release bundle to
# ~/.local/opt/weekleaf and adds an application-menu entry and icon.
#
#   tools/dev flutter build linux --release   # build first
#   tools/install-local.sh                    # install
#   tools/install-local.sh --uninstall        # remove (keeps your planner data)
#
# Nothing here needs root. Planner data lives separately in
# ~/.local/share/org.weekleaf.weekleaf and is never touched by this script.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="org.weekleaf.weekleaf"
prefix="$HOME/.local"
target="$prefix/opt/weekleaf"
desktop="$prefix/share/applications/$app_id.desktop"
icons="$prefix/share/icons/hicolor"

refresh() {
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -q -t "$icons" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$target"
  rm -f "$desktop"
  for size in 48 64 128 256 512; do
    rm -f "$icons/${size}x${size}/apps/$app_id.png"
  done
  refresh
  echo "Removed the app. Your planner data in $prefix/share/$app_id was left in place."
  exit 0
fi

bundle="$root/build/linux/x64/release/bundle"
if [ ! -x "$bundle/weekleaf" ]; then
  echo "No release build found. Run: tools/dev flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$target" "$(dirname "$desktop")"
# Replace the previous install as a whole so no stale files linger.
rm -rf "$target.new"
cp -r "$bundle" "$target.new"
rm -rf "$target"
mv "$target.new" "$target"

for size in 48 64 128 256 512; do
  mkdir -p "$icons/${size}x${size}/apps"
  cp "$root/assets/icon/weekleaf-$size.png" "$icons/${size}x${size}/apps/$app_id.png"
done

cat > "$desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Weekleaf
GenericName=Weekly Planner
Comment=A minimal weekly planner
Exec=$target/weekleaf
Icon=$app_id
Terminal=false
Categories=Office;Calendar;ProjectManagement;
Keywords=planner;todo;tasks;week;calendar;
StartupWMClass=weekleaf
StartupNotify=true
DESKTOP

refresh
echo "Installed to $target"
echo "Start it from the application menu (Weekleaf) or run: $target/weekleaf"
