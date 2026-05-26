# Sub2API Usage Widget

Übersicht desktop widget for today's Sub2API admin usage summary.

## Install

1. Install and open Übersicht.
2. Copy or symlink this `sub2api-usage.widget` directory into:

   ```bash
   ~/Library/Application Support/Übersicht/widgets/
   ```

3. Copy `config.example.json` to `config.json` and set your Sub2API domain.
4. Open Chrome, log in to your Sub2API admin usage page, and keep a matching tab open.
5. If macOS prompts for automation permission, allow Übersicht or Terminal to control Google Chrome.

## Test

Run the fetch script manually:

```bash
node sub2api-usage.widget/scripts/fetch-usage.mjs
```

Successful output includes `ok: true`, `totalRequests`, `totalTokens`, and `totalActualCost`.
