#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sub2API Usage Widget.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

"$ROOT_DIR/scripts/build-native-widget.sh"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/native-widget/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/native-widget/Sub2APIUsageWidget" "$MACOS_DIR/Sub2APIUsageWidget"

chmod +x "$MACOS_DIR/Sub2APIUsageWidget"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

echo "Built app: $APP_DIR"
