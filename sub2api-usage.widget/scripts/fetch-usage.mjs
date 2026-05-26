#!/usr/bin/env node

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const TIME_ZONE = "Asia/Shanghai";
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const WIDGET_DIR = resolve(SCRIPT_DIR, "..");
const KEYCHAIN_SERVICE = "sub2api-usage-widget";

export const DEFAULT_CONFIG = {
  baseUrl: "https://sub2api.example.com",
};

export function normalizeBaseUrl(value) {
  return String(value || DEFAULT_CONFIG.baseUrl).replace(/\/+$/, "");
}

export async function loadConfig(configPath = resolve(WIDGET_DIR, "config.json")) {
  try {
    const raw = await readFile(configPath, "utf8");
    const parsed = JSON.parse(raw);
    return {
      ...DEFAULT_CONFIG,
      ...parsed,
      baseUrl: normalizeBaseUrl(parsed.baseUrl || DEFAULT_CONFIG.baseUrl),
    };
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw new Error(`配置文件读取失败：${error.message}`);
    }
    return {
      ...DEFAULT_CONFIG,
      baseUrl: normalizeBaseUrl(DEFAULT_CONFIG.baseUrl),
    };
  }
}

export function formatShanghaiDate(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);

  const values = Object.fromEntries(
    parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]),
  );

  return `${values.year}-${values.month}-${values.day}`;
}

export function buildStatsUrl(day, baseUrl = DEFAULT_CONFIG.baseUrl, mode = "range") {
  const url = new URL(`${normalizeBaseUrl(baseUrl)}/api/v1/usage/stats`);
  if (mode === "period") {
    url.searchParams.set("period", "today");
    return url.toString();
  }

  url.searchParams.set("start_date", day);
  url.searchParams.set("end_date", day);
  return url.toString();
}

export function parseSecretValue(stdout) {
  const value = String(stdout ?? "")
    .trim()
    .replace(/^"(.*)"$/, "$1")
    .trim();

  if (!value || value === "missing value" || value === "null" || value === "undefined") {
    return null;
  }

  return value;
}

export function extractStats(payload) {
  const stats = payload?.data && typeof payload.data === "object" ? payload.data : payload;
  return {
    totalRequests: Number(stats?.total_requests ?? 0),
    totalTokens: Number(stats?.total_tokens ?? 0),
    totalCacheTokens: Number(stats?.total_cache_tokens ?? 0),
    totalActualCost: Number(stats?.total_actual_cost ?? 0),
  };
}

function createCredentialError(message) {
  const error = new Error(message);
  error.needsCredentials = true;
  return error;
}

async function readKeychainSecret(account) {
  try {
    const { stdout } = await execFileAsync(
      "security",
      ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
      {
        timeout: 10_000,
        maxBuffer: 1024 * 1024,
      },
    );
    return parseSecretValue(stdout);
  } catch (error) {
    if (error?.code === 44) return null;
    return null;
  }
}

async function writeKeychainSecret(account, value) {
  if (!value) return;
  await execFileAsync(
    "security",
    [
      "add-generic-password",
      "-U",
      "-s",
      KEYCHAIN_SERVICE,
      "-a",
      account,
      "-w",
      value,
    ],
    {
      timeout: 10_000,
      maxBuffer: 1024 * 1024,
    },
  );
}

export async function requestStats(url, token) {
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${token}`,
    },
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    const error = new Error(`接口返回 ${response.status}${body ? `：${body.slice(0, 160)}` : ""}`);
    error.status = response.status;
    throw error;
  }

  return response.json();
}

async function requestAuth(baseUrl, path, body) {
  const response = await fetch(`${normalizeBaseUrl(baseUrl)}/api/v1${path}`, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const payload = await response.json().catch(async () => {
    const text = await response.text().catch(() => "");
    return { message: text };
  });

  if (!response.ok) {
    const error = new Error(`认证接口返回 ${response.status}${payload?.message ? `：${payload.message}` : ""}`);
    error.status = response.status;
    throw error;
  }

  if (payload && typeof payload === "object" && "code" in payload) {
    if (payload.code === 0) return payload.data;
    throw new Error(payload.message || "认证失败");
  }

  return payload?.data && typeof payload.data === "object" ? payload.data : payload;
}

export async function loginWithPassword(baseUrl, credentials) {
  return requestAuth(baseUrl, "/auth/login", credentials);
}

export async function refreshAccessToken(baseUrl, refreshToken) {
  return requestAuth(baseUrl, "/auth/refresh", { refresh_token: refreshToken });
}

async function fetchStats(token, day, baseUrl, requestJSON = requestStats) {
  try {
    return await requestJSON(buildStatsUrl(day, baseUrl), token);
  } catch (rangeError) {
    if (rangeError?.status === 401 || rangeError?.status === 403) {
      throw rangeError;
    }
    try {
      return await requestJSON(buildStatsUrl(day, baseUrl, "period"), token);
    } catch (periodError) {
      throw new Error(`${rangeError.message}; fallback failed: ${periodError.message}`);
    }
  }
}

function isAuthorizationError(error) {
  return error?.status === 401 || error?.status === 403;
}

async function saveAuthTokens(writeSecret, authPayload) {
  if (authPayload?.access_token) {
    await writeSecret("access_token", authPayload.access_token);
  }
  if (authPayload?.refresh_token) {
    await writeSecret("refresh_token", authPayload.refresh_token);
  }
}

export async function fetchStatsWithIndependentAuth({
  day,
  config,
  readSecret = readKeychainSecret,
  writeSecret = writeKeychainSecret,
  login = loginWithPassword,
  refreshToken = refreshAccessToken,
  requestJSON = requestStats,
} = {}) {
  const baseUrl = normalizeBaseUrl(config?.baseUrl || DEFAULT_CONFIG.baseUrl);

  const accessToken = await readSecret("access_token");
  if (accessToken) {
    try {
      return {
        tokenSource: "access_token",
        stats: extractStats(await fetchStats(accessToken, day, baseUrl, requestJSON)),
      };
    } catch (error) {
      if (!isAuthorizationError(error)) {
        throw error;
      }
    }
  }

  const storedRefreshToken = await readSecret("refresh_token");
  if (storedRefreshToken) {
    try {
      const refreshed = await refreshToken(baseUrl, storedRefreshToken);
      await saveAuthTokens(writeSecret, refreshed);
      return {
        tokenSource: "refresh_token",
        stats: extractStats(await fetchStats(refreshed.access_token, day, baseUrl, requestJSON)),
      };
    } catch (error) {
      if (!isAuthorizationError(error)) {
        throw error;
      }
    }
  }

  const email = await readSecret("email");
  const password = await readSecret("password");
  if (!email || !password) {
    throw createCredentialError("缺少 Sub2API 登录凭据。请输入邮箱和密码。");
  }

  let loginResult;
  try {
    loginResult = await login(baseUrl, { email, password });
  } catch (error) {
    throw createCredentialError(`登录失败，请重新输入 Sub2API 邮箱和密码。${error?.message ? `(${error.message})` : ""}`);
  }
  if (loginResult?.requires_2fa) {
    throw createCredentialError("当前账号开启了 2FA，小组件暂不支持独立完成二次验证。建议为挂件准备一个只读管理员账号。");
  }
  if (!loginResult?.access_token) {
    throw createCredentialError("登录成功但没有返回 access_token，请重新确认账号权限。");
  }

  await saveAuthTokens(writeSecret, loginResult);
  return {
    tokenSource: "login",
    stats: extractStats(await fetchStats(loginResult.access_token, day, baseUrl, requestJSON)),
  };
}

export async function main() {
  const day = formatShanghaiDate();
  const fetchedAt = new Date().toISOString();

  try {
    const config = await loadConfig();
    const { stats, tokenSource } = await fetchStatsWithIndependentAuth({ day, config });
    return {
      ok: true,
      day,
      fetchedAt,
      tokenSource,
      ...stats,
    };
  } catch (error) {
    return {
      ok: false,
      day,
      fetchedAt,
      needsCredentials: error?.needsCredentials === true,
      error: error?.message || String(error),
    };
  }
}

export function isDirectRun(importMetaUrl, argvPath) {
  if (!argvPath) return false;
  return fileURLToPath(importMetaUrl) === resolve(argvPath);
}

if (isDirectRun(import.meta.url, process.argv[1])) {
  const result = await main();
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
