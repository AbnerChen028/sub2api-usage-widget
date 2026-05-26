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

export const DEFAULT_CONFIG = {
  baseUrl: "https://sub2api.example.com",
  chromeUrlMatch: "sub2api",
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

export function parseChromeAuthToken(stdout) {
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

export function toChromeAuthErrorMessage(detail) {
  const text = String(detail ?? "");
  if (text.includes("-1723") || text.includes("不允许访问") || text.includes("not allowed")) {
    return "需要在 Chrome 打开并登录 Sub2API，且开启 View > Developer > Allow JavaScript from Apple Events。";
  }

  return `无法从 Chrome 读取登录态：${text.trim()}`;
}

async function getChromeAuthToken(chromeUrlMatch) {
  const script = `
    tell application "Google Chrome"
      if not (exists window 1) then return ""
      repeat with w in windows
        set tabIndex to 1
        repeat with t in tabs of w
          if (URL of t contains "${chromeUrlMatch.replaceAll('"', '\\"')}") then
            set active tab index of w to tabIndex
            set tokenValue to execute active tab of w javascript "localStorage.getItem('auth_token')"
            if tokenValue is not missing value and tokenValue is not "" then return tokenValue
          end if
          set tabIndex to tabIndex + 1
        end repeat
      end repeat
      return ""
    end tell
  `;

  try {
    const { stdout } = await execFileAsync("osascript", ["-e", script], {
      timeout: 10_000,
      maxBuffer: 1024 * 1024,
    });
    return parseChromeAuthToken(stdout);
  } catch (error) {
    const detail = error?.stderr || error?.message || String(error);
    throw new Error(toChromeAuthErrorMessage(detail));
  }
}

async function requestStats(url, token) {
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${token}`,
    },
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`接口返回 ${response.status}${body ? `：${body.slice(0, 160)}` : ""}`);
  }

  return response.json();
}

async function fetchStats(token, day, baseUrl) {
  try {
    return await requestStats(buildStatsUrl(day, baseUrl), token);
  } catch (rangeError) {
    try {
      return await requestStats(buildStatsUrl(day, baseUrl, "period"), token);
    } catch (periodError) {
      throw new Error(`${rangeError.message}; fallback failed: ${periodError.message}`);
    }
  }
}

export async function main() {
  const day = formatShanghaiDate();
  const fetchedAt = new Date().toISOString();

  try {
    const config = await loadConfig();
    const token = await getChromeAuthToken(config.chromeUrlMatch || new URL(config.baseUrl).hostname);
    if (!token) {
      throw new Error("需要在 Chrome 打开并登录 Sub2API，且允许 Apple Events 执行页面 JavaScript。");
    }

    const stats = extractStats(await fetchStats(token, day, config.baseUrl));
    return {
      ok: true,
      day,
      fetchedAt,
      ...stats,
    };
  } catch (error) {
    return {
      ok: false,
      day,
      fetchedAt,
      error: error?.message || String(error),
    };
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const result = await main();
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
