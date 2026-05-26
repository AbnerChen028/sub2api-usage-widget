import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { test } from "node:test";
import { promisify } from "node:util";

import {
  buildStatsUrl,
  DEFAULT_CONFIG,
  extractStats,
  formatShanghaiDate,
  normalizeBaseUrl,
  parseChromeAuthToken,
  toChromeAuthErrorMessage,
} from "../scripts/fetch-usage.mjs";

const execFileAsync = promisify(execFile);

test("formatShanghaiDate returns the Asia/Shanghai calendar day", () => {
  const date = new Date("2026-05-25T16:30:00.000Z");

  assert.equal(formatShanghaiDate(date), "2026-05-26");
});

test("buildStatsUrl includes the selected date range", () => {
  const url = buildStatsUrl("2026-05-26", DEFAULT_CONFIG.baseUrl);

  assert.equal(
    url,
    "https://sub2api.example.com/api/v1/usage/stats?start_date=2026-05-26&end_date=2026-05-26",
  );
});

test("buildStatsUrl supports a custom base URL", () => {
  const url = buildStatsUrl("2026-05-26", "https://example.com/");

  assert.equal(
    url,
    "https://example.com/api/v1/usage/stats?start_date=2026-05-26&end_date=2026-05-26",
  );
});

test("normalizeBaseUrl removes trailing slashes", () => {
  assert.equal(normalizeBaseUrl("https://example.com///"), "https://example.com");
});

test("extractStats normalizes the fields used by the widget", () => {
  const result = extractStats({
    total_requests: 1234,
    total_tokens: 9876543,
    total_actual_cost: 12.34567,
  });

  assert.deepEqual(result, {
    totalRequests: 1234,
    totalTokens: 9876543,
    totalCacheTokens: 0,
    totalActualCost: 12.34567,
  });
});

test("extractStats reads stats from API response data envelope", () => {
  const result = extractStats({
    code: 0,
    message: "success",
    data: {
      total_requests: 364,
      total_tokens: 27513785,
      total_cache_tokens: 26003072,
      total_actual_cost: 19.95058985,
    },
  });

  assert.deepEqual(result, {
    totalRequests: 364,
    totalTokens: 27513785,
    totalCacheTokens: 26003072,
    totalActualCost: 19.95058985,
  });
});

test("parseChromeAuthToken trims a quoted token from osascript output", () => {
  assert.equal(parseChromeAuthToken(' "abc.def.ghi" \n'), "abc.def.ghi");
});

test("parseChromeAuthToken returns null for missing browser token values", () => {
  assert.equal(parseChromeAuthToken("missing value\n"), null);
  assert.equal(parseChromeAuthToken("null\n"), null);
  assert.equal(parseChromeAuthToken("\n"), null);
});

test("toChromeAuthErrorMessage explains blocked Chrome JavaScript automation", () => {
  const message = toChromeAuthErrorMessage("不允许访问。 (-1723)");

  assert.equal(
    message,
    "需要在 Chrome 打开并登录 Sub2API，且开启 View > Developer > Allow JavaScript from Apple Events。",
  );
});

test("CLI always prints parseable JSON", async () => {
  const { stdout } = await execFileAsync("node", ["scripts/fetch-usage.mjs"], {
    cwd: new URL("..", import.meta.url),
    timeout: 15_000,
  });

  const result = JSON.parse(stdout);

  assert.equal(typeof result.ok, "boolean");
  assert.match(result.day, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(result.fetchedAt, /^\d{4}-\d{2}-\d{2}T/);
});
