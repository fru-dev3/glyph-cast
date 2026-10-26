#!/usr/bin/env bash
# Builds "build/Glyph Cast.app", signed with the Apple Development identity so macOS keeps
# the Screen Recording and Microphone permissions across rebuilds (the bundle id stays
# dev.fru.capture and the data stays in ~/Movies/Capture, from when the app was called Capture).
# --install copies it to /Applications; --run launches it.
# SIGN_IDENTITY=<identity> signs with that instead (scripts/release.sh passes Developer ID).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=0.1.2
BUILD=3

swift build -c release

APP="build/Glyph Cast.app"
rm -rf build/Capture.app "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Capture "$APP/Contents/MacOS/Capture"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R assets/wallpapers "$APP/Contents/Resources/wallpapers"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glyph Cast</string>
  <key>CFBundleDisplayName</key><string>Glyph Cast</string>
  <key>CFBundleIdentifier</key><string>dev.fru.capture</string>
  <key>CFBundleExecutable</key><string>Capture</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Inspired Nation, LLC. MIT License.</string>
  <key>NSMicrophoneUsageDescription</key><string>Glyph Cast records your voice with the screen.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Glyph Cast records your screen.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -v REVOKED | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}
if [[ $IDENTITY == "Developer ID Application"* ]]; then
  # hardened runtime + timestamp for notarization; the mic needs its entitlement under the runtime
  codesign --force --options runtime --timestamp --entitlements scripts/Cast.entitlements --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
fi
echo "Built $APP $VERSION (signed: ${IDENTITY:-ad-hoc})"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Capture 2>/dev/null || true
      rm -rf "$HOME/Applications/Capture.app" "/Applications/Capture.app"   # the app's old name
      rm -rf "/Applications/Glyph Cast.app"
      cp -R "$APP" "/Applications/"
      APP="/Applications/Glyph Cast.app"
      echo "Installed $APP"
      ;;
    --run)
      pkill -x Capture 2>/dev/null || true
      open "$APP"
      echo "Launched $APP"
      ;;
  esac
done
