#!/bin/bash
# Chrome and SwiftPM only load files from inside their own trees, so each gets a copy.
set -euo pipefail
cd "$(dirname "$0")/.."
cp packages/shared-config/config.json apps/chrome-extension/src/config.json
mkdir -p apps/macos-app/Sources/FormatterCore
cp packages/shared-config/config.json apps/macos-app/Sources/FormatterCore/config.json
# The Windows and Linux apps reuse the extension's AI client and settings page.
for APP in apps/windows-app apps/linux-app; do
  rm -rf "$APP/shared"
  mkdir -p "$APP/shared/src"
  cp packages/desktop-core/* "$APP/shared/"
  cp apps/chrome-extension/src/ai-core.js packages/shared-config/config.json "$APP/shared/src/"
  cp -R apps/chrome-extension/options apps/chrome-extension/icons "$APP/shared/"
done
