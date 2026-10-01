#!/bin/bash
# Builds AndonCord.app.  Usage: build.sh [debug|release|dmg]
#
# SPM cannot emit an app bundle, so the executable is assembled into one by
# hand. The hook shim ships inside the same bundle as the app: the launcher in
# ~/.andoncord/bin resolves it there, which is what lets the app be moved or
# updated without rewriting anyone's settings.json.
#
# "dmg" does a release build and then packages build/AndonCord.dmg — the app
# plus an /Applications symlink, the classic drag-to-install disk image.
set -euo pipefail

CONFIG="${1:-debug}"
MAKE_DMG=""
if [ "$CONFIG" = "dmg" ]; then
  CONFIG=release
  MAKE_DMG=1
fi
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AndonCord"
BUNDLE_ID="app.andoncord.mac"
VERSION="0.2.0"

cd "$ROOT"

echo "▸ Building ($CONFIG)…"
if [ -n "$MAKE_DMG" ]; then
  # The distributed image is universal — Intel Macs run macOS 14 too.
  swift build -c release --arch arm64 --arch x86_64 --product AndonCordApp
  swift build -c release --arch arm64 --arch x86_64 --product andon-hook
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
elif [ "$CONFIG" = "release" ]; then
  swift build -c release --product AndonCordApp
  swift build -c release --product andon-hook
  BIN="$(swift build -c release --show-bin-path)"
else
  swift build --product AndonCordApp
  swift build --product andon-hook
  BIN="$(swift build --show-bin-path)"
fi

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/AndonCordApp" "$APP/Contents/MacOS/AndonCord"
cp "$BIN/andon-hook"   "$APP/Contents/MacOS/andon-hook"

# The icon is generated from the same palette as the in-app lamps, so it can
# never drift out of sync with the board it represents.
echo "▸ Rendering icon…"
ICONSET="$ROOT/build/AndonCord.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AndonCord.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AndonCord</string>
  <key>CFBundleIconFile</key><string>AndonCord</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>

  <!-- Menu bar app: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>

  <!-- Precise terminal jump drives iTerm2 and Terminal.app via Apple events.
       macOS shows this string in the automation consent prompt. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>AndonCord uses automation to bring the terminal tab running a Claude Code session back to the front when you click it.</string>

  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Developer ID when the keychain has one (that is what makes downloaded
# copies open cleanly), ad-hoc otherwise — local builds don't need more.
IDENTITY="${ANDON_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing ($IDENTITY)…"
  # Nested binary first, then the bundle seals it. The hardened runtime is a
  # notarisation requirement; the entitlement re-allows the Apple events that
  # precise terminal jump sends (the runtime blocks them by default).
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/MacOS/andon-hook"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Tools/AndonCord.entitlements" \
    --sign "$IDENTITY" "$APP"
else
  echo "▸ Signing (ad-hoc)…"
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

echo "▸ Built $APP"

if [ -n "$MAKE_DMG" ]; then
  PROFILE="${ANDON_NOTARY_PROFILE:-andoncord}"
  NOTARIZE=""
  if [ -n "$IDENTITY" ]; then
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
      NOTARIZE=1
    else
      echo "✗ Developer ID found but no notary credentials."
      echo "  One-time setup:  xcrun notarytool store-credentials $PROFILE \\"
      echo "                     --apple-id <apple-id> --team-id <team-id>"
      echo "  (asks for an app-specific password from account.apple.com)"
      exit 1
    fi
  fi

  if [ -n "$NOTARIZE" ]; then
    # Notarise and staple the app itself first, so the copy users drag out of
    # the image passes Gatekeeper even offline; then the image gets its own
    # ticket. Two submissions, but the second one is near-instant.
    echo "▸ Notarising app (takes a minute or two)…"
    ZIP="$ROOT/build/$APP_NAME-notary.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
  fi

  echo "▸ Packaging DMG…"
  STAGING="$ROOT/build/dmg-staging"
  DMG="$ROOT/build/$APP_NAME.dmg"
  rm -rf "$STAGING" "$DMG"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/$APP_NAME.app"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
    -format UDZO -fs HFS+ -ov -quiet "$DMG"
  rm -rf "$STAGING"

  if [ -n "$NOTARIZE" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "▸ Notarising DMG…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  echo "▸ Packaged $DMG"
fi

echo
echo "  Run:      open '$APP'"
echo "  Console:  log stream --predicate 'subsystem == \"app.andoncord\"' --level debug"
