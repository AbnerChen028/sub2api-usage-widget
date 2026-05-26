# Sub2API Usage Desktop Widget

A tiny macOS desktop widget for monitoring today's Sub2API usage:

- total requests
- total tokens
- cache-hit tokens
- total cost
- friendly usage reminders based on token volume

It reads the login token from an already logged-in Google Chrome tab and calls the Sub2API admin usage API.

## Requirements

- macOS
- Google Chrome
- Node.js 18+ available as `node`
- Swift toolchain / Xcode Command Line Tools for the native widget
- A Sub2API-compatible admin site that exposes:
  - `GET /api/v1/usage/stats`
  - `localStorage.auth_token` in the logged-in web app

Install command line tools if needed:

```bash
xcode-select --install
```

## Configure

Copy the example config:

```bash
cp sub2api-usage.widget/config.example.json sub2api-usage.widget/config.json
```

Edit `sub2api-usage.widget/config.json`:

```json
{
  "baseUrl": "https://your-sub2api.example.com",
  "chromeUrlMatch": "your-sub2api.example.com"
}
```

`baseUrl` is your Sub2API site origin. `chromeUrlMatch` is the string used to find the logged-in Chrome tab.

## Chrome Setup

1. Open your Sub2API admin page in Google Chrome and log in.
2. Enable Chrome Apple Events JavaScript:
   - Chrome menu: `View > Developer > Allow JavaScript from Apple Events`

The widget uses AppleScript to run:

```js
localStorage.getItem("auth_token")
```

in the matching Chrome tab. The token is not written to disk.

## Run

Build and start the native widget:

```bash
./scripts/run-native-widget.sh
```

The widget refreshes every 5 minutes. You can drag it by its background.

## Start Automatically After Login

Install the widget as a macOS LaunchAgent:

```bash
./scripts/install-launch-agent.sh
```

The installer builds the native widget, copies the runtime files to:

```text
~/Library/Application Support/Sub2APIUsageWidget
```

and registers:

```text
~/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist
```

After installation, macOS starts the widget when you log in. To restart it manually:

```bash
launchctl kickstart -k "gui/$(id -u)/com.abnerchen.sub2api-usage-widget"
```

To disable auto-start:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist"
```

Launch logs are written to:

```text
~/Library/Application Support/Sub2APIUsageWidget/logs
```

## Test Fetching

Run the fetch script directly:

```bash
node sub2api-usage.widget/scripts/fetch-usage.mjs
```

Successful output looks like:

```json
{
  "ok": true,
  "day": "2026-05-26",
  "totalRequests": 123,
  "totalTokens": 1230000,
  "totalCacheTokens": 1000000,
  "totalActualCost": 1.23
}
```

## Run Tests

```bash
node --test sub2api-usage.widget/test/fetch-usage.test.mjs
```

## Usage Reminder Thresholds

- `< 20M` tokens: healthy
- `20M-50M` tokens: reminder
- `> 50M` tokens: warning

Each refresh picks a random friendly message from the current threshold bucket.

## Notes

This repository also contains an Übersicht-compatible widget entry in `sub2api-usage.widget/index.jsx`, but the native widget is the recommended runner because it is more reliable on current macOS releases.
