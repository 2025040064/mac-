#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache dist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"

# Swift Build can record the deployment target as the linked SDK version,
# which makes macOS use the pre-Liquid Glass appearance. The native backend
# records the actual SDK version while keeping macOS 14 as the minimum.
build_args=(--configuration release --arch arm64 --manifest-cache local --scratch-path .build/app --build-system native)
swift build "${build_args[@]}" "$@"
bin_path="$(swift build "${build_args[@]}" "$@" --show-bin-path)"

app="$PWD/dist/Astrspire Serial.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_path/AstrspireSerial" "$app/Contents/MacOS/AstrspireSerial"
cp Scripts/Info.plist "$app/Contents/Info.plist"
cp Vendor/ORSSerialPort/LICENSE "$app/Contents/Resources/ORSSerialPort-LICENSE.txt"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
