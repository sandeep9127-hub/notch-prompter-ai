#!/usr/bin/env bash
# Builds a universal NotchCoach.app (Apple silicon + Intel) and zips it into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP=build/NotchCoach.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchCoach" "$APP/Contents/MacOS/NotchCoach"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

# Ad-hoc signature: not notarised, so macOS asks you to approve it on first launch.
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/NotchCoach.zip
echo "Built $(pwd)/build/NotchCoach.zip"
