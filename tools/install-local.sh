#!/usr/bin/env bash
# Install the built app for the current user: copies the release bundle to
# ~/.local/opt/weektodo and adds an application-menu entry and icon.
#
#   tools/dev flutter build linux --release   # build first
#   tools/install-local.sh                    # install, or update
#   tools/install-local.sh --uninstall        # remove (keeps your planner data)
#
# Nothing here needs root. Planner data lives separately in
# ~/.local/share/io.github.yourj4m.weektodo and is never touched by this
# script; neither are the passwords in the keyring. An update therefore keeps
# the planner, the sync connection and the subscribed calendars.
#
# Each install goes into a folder of its own under ~/.local/opt/weektodo.d,
# and ~/.local/opt/weektodo is a link that is switched to it in one step. A
# running app keeps reading its own folder, so updating never disturbs it;
# the new version starts the next time the app is opened. Folders no app is
# running from are cleaned up by the following install.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="io.github.yourj4m.weektodo"
prefix="$HOME/.local"
target="$prefix/opt/weektodo"
versions="$prefix/opt/weektodo.d"
desktop="$prefix/share/applications/$app_id.desktop"
icons="$prefix/share/icons/hicolor"

refresh() {
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -q -t "$icons" >/dev/null 2>&1 || true
}

# Whether a running process was started from the folder $1.
in_use() {
  local exe
  for exe in /proc/[0-9]*/exe; do
    case "$(readlink "$exe" 2>/dev/null)" in "$1"/*) return 0 ;; esac
  done
  return 1
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$target" "$versions"
  rm -f "$desktop"
  for size in 48 64 128 256 512; do
    rm -f "$icons/${size}x${size}/apps/$app_id.png"
  done
  refresh
  echo "Removed the app. Your planner data in $prefix/share/$app_id was left in place."
  exit 0
fi

bundle="$root/build/linux/x64/release/bundle"
if [ ! -x "$bundle/weektodo" ]; then
  echo "No release build found. Run: tools/dev flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$versions" "$(dirname "$desktop")"

# An install from before the link: a plain folder. An app running from it
# would find the new version's files under its own paths, so wait for it to
# be closed this one time; later updates need no such care.
if [ -d "$target" ] && [ ! -L "$target" ]; then
  if in_use "$target"; then
    echo "WeekToDo is running from an older kind of install. Close it and run this again." >&2
    exit 3
  fi
  rm -rf "$target"
fi

# Old versions nobody runs any more.
current=""
[ -L "$target" ] && current="$(readlink -f "$target")"
for old in "$versions"/*/; do
  old="${old%/}"
  [ -d "$old" ] || continue
  [ "$old" = "$current" ] && continue
  in_use "$old" || rm -rf "$old"
done

# The new version, complete before anything points at it; then the link is
# switched in a single rename.
new="$versions/$(date +%Y%m%d-%H%M%S)-$$"
cp -r "$bundle" "$new.part"
mv "$new.part" "$new"
ln -s "$new" "$target.link"
mv -T "$target.link" "$target"
if [ -n "$current" ] && [ "$current" != "$new" ] && ! in_use "$current"; then
  rm -rf "$current"
fi

for size in 48 64 128 256 512; do
  mkdir -p "$icons/${size}x${size}/apps"
  cp "$root/assets/icon/weektodo-$size.png" "$icons/${size}x${size}/apps/$app_id.png"
done

cat > "$desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=WeekToDo
GenericName=Weekly Planner
Comment=A minimal weekly planner
Exec=$target/weektodo
Icon=$app_id
Terminal=false
Categories=Office;Calendar;ProjectManagement;
Keywords=planner;todo;tasks;week;calendar;
StartupWMClass=weektodo
StartupNotify=true
DESKTOP

refresh
echo "Installed to $target"
if pgrep -x weektodo >/dev/null 2>&1; then
  echo "WeekToDo is open and keeps running the previous version; close and reopen it to use the new one."
else
  echo "Start it from the application menu (WeekToDo) or run: $target/weektodo"
fi
