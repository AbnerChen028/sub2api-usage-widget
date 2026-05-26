#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swiftc "$ROOT_DIR/native-widget/Sub2APIUsageWidget.swift" \
  -o "$ROOT_DIR/native-widget/Sub2APIUsageWidget" \
  -framework Cocoa
