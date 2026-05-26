#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT_DIR/native-widget/Sub2APIUsageWidget"
FETCH_SCRIPT="$ROOT_DIR/sub2api-usage.widget/scripts/fetch-usage.mjs"

if [[ ! -x "$BINARY" ]]; then
  "$ROOT_DIR/scripts/build-native-widget.sh"
fi

pkill -f "Sub2APIUsageWidget" >/dev/null 2>&1 || true
"$BINARY" "$FETCH_SCRIPT"
