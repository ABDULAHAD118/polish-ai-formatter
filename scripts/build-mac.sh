#!/bin/bash
# Builds dist/WhatsApp AI Formatter.app and a zip, for this Mac's architecture.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/sync-config.sh
ICONS="$(mktemp -d)"
trap 'rm -rf "$ICONS"' EXIT
swift scripts/make-icons.swift "$ICONS"
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"

(cd apps/macos-app && swift build -c release --product WhatsAppFormatter)
BIN="$(cd apps/macos-app && swift build -c release --show-bin-path)/WhatsAppFormatter"

APP="dist/WhatsApp AI Formatter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhatsAppFormatter"
cp apps/macos-app/Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICONS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Set SIGN_IDENTITY to a Developer ID for distribution. "-" is an ad-hoc signature.
codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify "$APP"
ditto -c -k --keepParent "$APP" "dist/WhatsApp-AI-Formatter-macOS-$(uname -m).zip"
echo "Built $APP"
