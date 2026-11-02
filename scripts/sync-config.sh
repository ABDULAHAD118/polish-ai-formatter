#!/bin/bash
# Chrome and SwiftPM only load files from inside their own trees, so each gets a copy.
set -euo pipefail
cd "$(dirname "$0")/.."
cp packages/shared-config/config.json apps/chrome-extension/src/config.json
mkdir -p apps/macos-app/Sources/FormatterCore
cp packages/shared-config/config.json apps/macos-app/Sources/FormatterCore/config.json
