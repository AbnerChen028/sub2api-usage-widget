import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { test } from "node:test";
import { promisify } from "node:util";

import {
  buildStatsUrl,
  DEFAULT_CONFIG,
  fetchStatsWithIndependentAuth,
  extractStats,
  formatShanghaiDate,
  isDirectRun,
  normalizeBaseUrl,
  parseSecretValue,
} from "../scripts/fetch-usage.mjs";

const execFileAsync = promisify(execFile);

test("formatShanghaiDate returns the Asia/Shanghai calendar day", () => {
  const date = new Date("2026-05-25T16:30:00.000Z");

  assert.equal(formatShanghaiDate(date), "2026-05-26");
});

test("buildStatsUrl includes the selected date range", () => {
  const url = buildStatsUrl("2026-05-26", "https://sub2api.example.com");

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

test("parseSecretValue trims a quoted secret from command output", () => {
  assert.equal(parseSecretValue(' "abc.def.ghi" \n'), "abc.def.ghi");
});

test("parseSecretValue returns null for missing secret values", () => {
  assert.equal(parseSecretValue("missing value\n"), null);
  assert.equal(parseSecretValue("null\n"), null);
  assert.equal(parseSecretValue("\n"), null);
});

test("isDirectRun handles script paths containing spaces", () => {
  assert.equal(
    isDirectRun(
      "file:///Users/example/Library/Application%20Support/Sub2APIUsageWidget/sub2api-usage.widget/scripts/fetch-usage.mjs",
      "/Users/example/Library/Application Support/Sub2APIUsageWidget/sub2api-usage.widget/scripts/fetch-usage.mjs",
    ),
    true,
  );
});

test("fetchStatsWithIndependentAuth uses cached access token first", async () => {
  const calls = [];

  const result = await fetchStatsWithIndependentAuth({
    day: "2026-05-26",
    config: {
      baseUrl: "https://sub2api.example.com",
    },
    readSecret: async (account) => {
      if (account === "access_token") return "cached-token";
      return null;
    },
    writeSecret: async () => {
      throw new Error("unchanged cached token should not be written");
    },
    login: async () => {
      throw new Error("login should not be used when cached token works");
    },
    refreshToken: async () => {
      throw new Error("refresh should not be used when cached token works");
    },
    requestJSON: async (url, token) => {
      calls.push({ url, token });
      return {
        total_requests: 10,
        total_tokens: 20,
        total_cache_tokens: 5,
        total_actual_cost: 0.12,
      };
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].token, "cached-token");
  assert.equal(result.tokenSource, "access_token");
  assert.equal(result.stats.totalRequests, 10);
});

test("fetchStatsWithIndependentAuth refreshes tokens after authorization failure", async () => {
  const tokens = [];
  const saved = new Map();

  const result = await fetchStatsWithIndependentAuth({
    day: "2026-05-26",
    config: {
      baseUrl: "https://sub2api.example.com",
    },
    readSecret: async (account) => {
      if (account === "access_token") return "expired-token";
      if (account === "refresh_token") return "refresh-token";
      return null;
    },
    writeSecret: async (account, value) => {
      saved.set(account, value);
    },
    login: async () => {
      throw new Error("login should not be used when refresh works");
    },
    refreshToken: async (_baseUrl, refreshToken) => {
      assert.equal(refreshToken, "refresh-token");
      return {
        access_token: "fresh-access-token",
        refresh_token: "fresh-refresh-token",
        expires_in: 3600,
      };
    },
    requestJSON: async (_url, token) => {
      tokens.push(token);
      if (token === "expired-token") {
        const error = new Error("接口返回 401");
        error.status = 401;
        throw error;
      }
      return {
        total_requests: 11,
        total_tokens: 22,
        total_cache_tokens: 6,
        total_actual_cost: 0.34,
      };
    },
  });

  assert.deepEqual(tokens, ["expired-token", "fresh-access-token"]);
  assert.equal(saved.get("access_token"), "fresh-access-token");
  assert.equal(saved.get("refresh_token"), "fresh-refresh-token");
  assert.equal(result.tokenSource, "refresh_token");
  assert.equal(result.stats.totalRequests, 11);
});

test("fetchStatsWithIndependentAuth logs in with Keychain credentials when no token exists", async () => {
  const saved = new Map();

  const result = await fetchStatsWithIndependentAuth({
    day: "2026-05-26",
    config: {
      baseUrl: "https://sub2api.example.com",
    },
    readSecret: async (account) => {
      if (account === "email") return "admin@example.com";
      if (account === "password") return "secret-password";
      return null;
    },
    writeSecret: async (account, value) => {
      saved.set(account, value);
    },
    login: async (_baseUrl, credentials) => {
      assert.deepEqual(credentials, {
        email: "admin@example.com",
        password: "secret-password",
      });
      return {
        access_token: "login-access-token",
        refresh_token: "login-refresh-token",
        expires_in: 3600,
      };
    },
    refreshToken: async () => {
      throw new Error("refresh should not be used without refresh token");
    },
    requestJSON: async (_url, token) => {
      assert.equal(token, "login-access-token");
      return {
        total_requests: 12,
        total_tokens: 24,
        total_cache_tokens: 7,
        total_actual_cost: 0.56,
      };
    },
  });

  assert.equal(saved.get("access_token"), "login-access-token");
  assert.equal(saved.get("refresh_token"), "login-refresh-token");
  assert.equal(result.tokenSource, "login");
  assert.equal(result.stats.totalRequests, 12);
});

test("fetchStatsWithIndependentAuth reads base URL from Keychain", async () => {
  let requestedUrl = "";

  const result = await fetchStatsWithIndependentAuth({
    day: "2026-05-26",
    config: {},
    readSecret: async (account) => {
      if (account === "base_url") return "https://custom.example.com/";
      if (account === "access_token") return "cached-token";
      return null;
    },
    writeSecret: async () => {
      throw new Error("token should not be written");
    },
    login: async () => {
      throw new Error("login should not be used when access token works");
    },
    refreshToken: async () => {
      throw new Error("refresh should not be used when access token works");
    },
    requestJSON: async (url) => {
      requestedUrl = url;
      return {
        total_requests: 13,
        total_tokens: 26,
        total_cache_tokens: 8,
        total_actual_cost: 0.78,
      };
    },
  });

  assert.equal(
    requestedUrl,
    "https://custom.example.com/api/v1/usage/stats?start_date=2026-05-26&end_date=2026-05-26",
  );
  assert.equal(result.stats.totalRequests, 13);
});

test("fetchStatsWithIndependentAuth asks for configuration when base URL is missing", async () => {
  await assert.rejects(
    fetchStatsWithIndependentAuth({
      day: "2026-05-26",
      config: {},
      readSecret: async () => null,
      writeSecret: async () => {},
      login: async () => {
        throw new Error("login should not be used without base URL");
      },
      refreshToken: async () => {
        throw new Error("refresh should not be used without base URL");
      },
      requestJSON: async () => {
        throw new Error("stats should not be requested without base URL");
      },
    }),
    (error) => error.needsCredentials === true && error.message.includes("服务地址"),
  );
});

test("CLI marks missing credentials as needing credential input", async () => {
  const { stdout } = await execFileAsync("node", ["scripts/fetch-usage.mjs"], {
    cwd: new URL("..", import.meta.url),
    timeout: 15_000,
  });

  const result = JSON.parse(stdout);

  if (!result.ok && result.error.includes("缺少 Sub2API 登录凭据")) {
    assert.equal(result.needsCredentials, true);
  }
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
