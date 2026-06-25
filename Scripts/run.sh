#!/bin/bash
# Build, (re)install and launch MacUtil.
# Usage: Scripts/run.sh [release|debug]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/MacUtil.app"

"$ROOT/Scripts/build-app.sh" "$CONFIG"

echo "▶ Relaunching…"
pkill -x MacUtil 2>/dev/null || true
sleep 0.3
open "$APP"
echo "✓ Launched MacUtil — look for the window icon in the menu bar."
