#!/bin/bash
# Builds dist/TextPolish-extension (Load unpacked) and a zip of it.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/sync-config.sh
EXT=apps/chrome-extension
if [ ! -f "$EXT/icons/icon128.png" ]; then
  ICONS="$(mktemp -d)"
  swift scripts/make-icons.swift "$ICONS"
  mkdir -p "$EXT/icons"
  cp "$ICONS"/icon16.png "$ICONS"/icon48.png "$ICONS"/icon128.png "$EXT/icons/"
  rm -rf "$ICONS"
fi
OUT=dist/TextPolish-extension
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
cp -R "$EXT/manifest.json" "$EXT/src" "$EXT/options" "$EXT/icons" "$OUT/"
(cd "$OUT" && zip -qr "../TextPolish-extension.zip" .)
echo "Built $OUT"
