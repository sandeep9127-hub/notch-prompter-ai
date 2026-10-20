#!/usr/bin/env bash
# Builds NotchCoach.app for Apple silicon and zips it into build/.
# xcodebuild (not `swift build`) is required so MLX's Metal shaders get compiled.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=.derived
xcodebuild build \
  -scheme NotchCoach \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  > build.log 2>&1 || { grep -E "error:|fatal" build.log | sort -u | head -80; tail -n 30 build.log; exit 1; }
PRODUCTS="$DERIVED/Build/Products/Release"

APP=build/NotchCoach.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/NotchCoach" "$APP/Contents/MacOS/NotchCoach"
# Resource bundles from dependencies, including MLX's compiled Metal library.
for bundle in "$PRODUCTS"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

echo "Bundled resources:"; ls "$APP/Contents/Resources"
find "$APP" -name '*.metallib' | grep -q . || { echo "error: no Metal library found in the app"; exit 1; }
otool -l "$APP/Contents/MacOS/NotchCoach" | grep -B3 FoundationModels | grep -q LC_LOAD_WEAK_DYLIB \
  || { echo "error: FoundationModels must be weak-linked"; exit 1; }

# Ad-hoc signature: not notarised, so macOS asks you to approve it on first launch.
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" build/NotchCoach.zip

# Disk image with an Applications shortcut for drag-to-install.
DMG_ROOT=build/dmg
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname NotchCoach -srcfolder "$DMG_ROOT" -ov -format UDZO build/NotchCoach.dmg >/dev/null
rm -rf "$DMG_ROOT"
echo "Built build/NotchCoach.zip ($(du -h build/NotchCoach.zip | cut -f1)) and build/NotchCoach.dmg ($(du -h build/NotchCoach.dmg | cut -f1))"
