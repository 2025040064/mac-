#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/dist"
mkdir -p "$output"
stage="$(mktemp -d "$output/.goaltracker.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/GoalTracker.app"
mkdir -p "$app/Contents/MacOS"

cp "$root/Config/App.plist" "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
for change in   'Set :CFBundleExecutable GoalTracker'   'Set :CFBundleIdentifier com.goaltracker.local'   'Set :CFBundleName GoalTracker'   'Set :LSMinimumSystemVersion 27.0'   'Delete :GoalTrackerAppGroup'; do
  /usr/libexec/PlistBuddy -c "$change" "$plist"
done

arch="$(uname -m)"
swiftc -swift-version 6 -Osize -D STANDALONE -target "$arch-apple-macosx27.0"   -module-cache-path "$stage/modules"   "$root/Shared/Competition.swift" "$root/App/"*.swift   -o "$app/Contents/MacOS/GoalTracker"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ -e "$output/GoalTracker.app" ]]; then
  mv "$output/GoalTracker.app" "$stage/Previous.app"
fi
mv "$app" "$output/GoalTracker.app"
printf '%s\n' "$output/GoalTracker.app"
