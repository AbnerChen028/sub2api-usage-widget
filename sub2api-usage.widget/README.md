# Sub2API Usage Widget

Übersicht desktop widget for today's Sub2API admin usage summary.

## Install

1. Install and open Übersicht.
2. Copy or symlink this `sub2api-usage.widget` directory into:

   ```bash
   ~/Library/Application Support/Übersicht/widgets/
   ```

3. On first native-widget launch, enter your Sub2API service address, email, and password in the macOS dialog.
4. Optional: create `config.json` with `baseUrl` if you want a file-based service-address override.

## Test

Run the fetch script manually:

```bash
node sub2api-usage.widget/scripts/fetch-usage.mjs
```

Successful output includes `ok: true`, `totalRequests`, `totalTokens`, and `totalActualCost`.
