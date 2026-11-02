#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/sync-config.sh
cd apps/macos-app
swift run CoreChecks
swift run WhatsAppFormatter --self-test
