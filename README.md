# Sub2API Usage Desktop Widget

[中文文档](README.zh-CN.md)

A tiny macOS desktop widget for monitoring today's Sub2API usage:

- total requests
- total tokens
- cache-hit tokens
- total cost
- friendly usage reminders based on token volume

It logs in directly through the Sub2API API, stores secrets in macOS Keychain, and refreshes usage without needing a browser.

## Requirements

- macOS
- Node.js 18+ available as `node`
- Swift toolchain / Xcode Command Line Tools for the native widget
- A Sub2API-compatible admin site that exposes:
  - `GET /api/v1/usage/stats`
  - `POST /api/v1/auth/login`
  - `POST /api/v1/auth/refresh`

Install command line tools if needed:

```bash
xcode-select --install
```

## Configure

On first launch, the native widget prompts for your Sub2API service address, email, and password in a macOS dialog.
The service address is your Sub2API site origin, for example `https://your-sub2api.example.com`.

The service address and credentials are stored in Keychain service `sub2api-usage-widget`.
The widget then logs in directly, stores `access_token` and `refresh_token` in the same Keychain service,
and refreshes tokens automatically. Secrets are not written to the repository config.

Advanced users can still create `sub2api-usage.widget/config.json` with a `baseUrl` value to override the Keychain service address.

If the service address or password later changes, or login fails, the widget prompts again and overwrites the saved values.
If you cancel the prompt, double-click the widget to retry.

For headless setup or troubleshooting, you can still save credentials from a shell:

```bash
./scripts/configure-credentials.sh
```

## Run

Build and start the native widget for local development:

```bash
./scripts/run-native-widget.sh
```

The widget refreshes every 5 minutes. You can drag it by its background, double-click it to refresh immediately, click the top-right collapse control to tuck it against the nearest left/right screen edge, and click the compact `T` icon to restore it. The expanded/collapsed state and position are remembered across restarts.

## Build the macOS App

Build a lightweight app bundle:

```bash
./scripts/build-app.sh
```

The app is created at:

```text
dist/Sub2API Usage Widget.app
```

You can copy the app to `/Applications` or any folder and launch it with Finder. This lightweight app still requires Node.js 18+ on the machine because it runs the bundled `fetch-usage.mjs` script internally.

## Start Automatically After Login

Install the app as a macOS LaunchAgent:

```bash
./scripts/install-launch-agent.sh
```

The installer builds the app, copies it to:

```text
~/Library/Application Support/Sub2APIUsageWidget
```

and registers:

```text
~/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist
```

After installation, macOS starts the app when you log in. To restart it manually:

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

The current app bundle is intentionally lightweight. A future fully native version can move the API fetch and auth refresh logic into Swift and remove the Node.js requirement.
