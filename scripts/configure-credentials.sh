#!/usr/bin/env bash
set -euo pipefail

SERVICE="sub2api-usage-widget"

read -r -p "Sub2API base URL: " BASE_URL
BASE_URL="${BASE_URL%/}"
if [[ -z "$BASE_URL" ]]; then
  echo "Base URL is required." >&2
  exit 1
fi

read -r -p "Sub2API email: " EMAIL
if [[ -z "$EMAIL" ]]; then
  echo "Email is required." >&2
  exit 1
fi

read -r -s -p "Sub2API password: " PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then
  echo "Password is required." >&2
  exit 1
fi

security add-generic-password -U -s "$SERVICE" -a "base_url" -w "$BASE_URL"
security add-generic-password -U -s "$SERVICE" -a "email" -w "$EMAIL"
security add-generic-password -U -s "$SERVICE" -a "password" -w "$PASSWORD"

security delete-generic-password -s "$SERVICE" -a "access_token" >/dev/null 2>&1 || true
security delete-generic-password -s "$SERVICE" -a "refresh_token" >/dev/null 2>&1 || true

echo "Saved Sub2API credentials to macOS Keychain service: $SERVICE"
echo "Cached tokens were cleared; the next widget refresh will log in independently."
