#!/bin/bash
# Builds dist/TextPolish.app and a zip. ARCHS="arm64 x86_64" makes a universal app (CI does this).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/sync-config.sh
ICONS="$(mktemp -d)"
trap 'rm -rf "$ICONS"' EXIT
swift scripts/make-icons.swift "$ICONS"
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"

ARCHS="${ARCHS:-$(uname -m)}"
BINS=()
for ARCH in $ARCHS; do
  (cd apps/macos-app && swift build -c release --arch "$ARCH" --product WhatsAppFormatter)
  BINS+=("$(cd apps/macos-app && swift build -c release --arch "$ARCH" --show-bin-path)/WhatsAppFormatter")
done
[ "$(wc -w <<<"$ARCHS")" -gt 1 ] && SUFFIX=universal || SUFFIX="$ARCHS"

APP="dist/TextPolish.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/WhatsAppFormatter"
cp apps/macos-app/Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICONS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Set SIGN_IDENTITY to a Developer ID for distribution. "-" is an ad-hoc signature.
codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify "$APP"
# The zip is what the in-app updater downloads.
ditto -c -k --keepParent "$APP" "dist/TextPolish-macOS-$SUFFIX.zip"

# Double-click installer that puts the app in /Applications.
PKGROOT="$ICONS/pkgroot"
mkdir -p "$PKGROOT"
ditto "$APP" "$PKGROOT/TextPolish.app"
pkgbuild --analyze --root "$PKGROOT" "$ICONS/component.plist" >/dev/null
# Otherwise Installer "upgrades" any other copy with the same bundle ID (such as dist/) instead of /Applications.
plutil -replace 0.BundleIsRelocatable -bool NO "$ICONS/component.plist"
pkgbuild --root "$PKGROOT" --component-plist "$ICONS/component.plist" --install-location /Applications \
  --identifier com.local.whatsapp-ai-formatter.pkg \
  --version "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" \
  "dist/TextPolish-macOS-$SUFFIX.pkg"
echo "Built $APP"
