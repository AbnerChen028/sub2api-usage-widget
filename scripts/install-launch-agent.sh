#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Sub2APIUsageWidget"
PLIST_SRC="$ROOT_DIR/launchd/com.abnerchen.sub2api-usage-widget.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist"

"$ROOT_DIR/scripts/build-native-widget.sh"

mkdir -p "$APP_SUPPORT/sub2api-usage.widget/scripts" \
  "$APP_SUPPORT/sub2api-usage.widget/test" \
  "$APP_SUPPORT/logs" \
  "$HOME/Library/LaunchAgents"

cp "$ROOT_DIR/native-widget/Sub2APIUsageWidget" "$APP_SUPPORT/Sub2APIUsageWidget"
cp "$ROOT_DIR/sub2api-usage.widget/scripts/fetch-usage.mjs" "$APP_SUPPORT/sub2api-usage.widget/scripts/fetch-usage.mjs"
cp "$ROOT_DIR/sub2api-usage.widget/config.json" "$APP_SUPPORT/sub2api-usage.widget/config.json"
chmod +x "$APP_SUPPORT/Sub2APIUsageWidget"

sed "s#__APP_SUPPORT_DIR__#$APP_SUPPORT#g" "$PLIST_SRC" > "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/com.abnerchen.sub2api-usage-widget"

echo "Installed LaunchAgent: $PLIST_DST"
echo "Runtime directory: $APP_SUPPORT"
