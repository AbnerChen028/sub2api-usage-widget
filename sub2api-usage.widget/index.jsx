export const command = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin node scripts/fetch-usage.mjs";

export const refreshFrequency = 1000 * 60 * 5;

export const className = `
  left: 28px;
  top: 72px;
  width: 260px;
  box-sizing: border-box;
  color: #f8fafc;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  pointer-events: none;
`;

const numberFormat = new Intl.NumberFormat("en-US");
const compactFormat = new Intl.NumberFormat("en-US", {
  notation: "compact",
  maximumFractionDigits: 2,
});
const moneyFormat = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 4,
  maximumFractionDigits: 4,
});

function parseOutput(output) {
  try {
    return JSON.parse(output || "{}");
  } catch {
    return {
      ok: false,
      error: "无法解析脚本输出",
    };
  }
}

function formatTime(value) {
  if (!value) return "--:--";
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

const Metric = ({ label, value, tone }) => (
  <div className={`metric ${tone || ""}`}>
    <div className="metric-label">{label}</div>
    <div className="metric-value">{value}</div>
  </div>
);

export const render = ({ output, error }) => {
  const data = error
    ? { ok: false, error: String(error) }
    : parseOutput(output);

  return (
    <div className="card">
      <div className="header">
        <div>
          <div className="title">Sub2API 今日用量</div>
          <div className="subtitle">{data.day || "今日"} · {formatTime(data.fetchedAt)} 更新</div>
        </div>
        <div className={data.ok ? "status ok" : "status bad"} />
      </div>

      {data.ok ? (
        <div className="metrics">
          <Metric label="总请求数" value={numberFormat.format(data.totalRequests || 0)} />
          <Metric label="总 Token" value={compactFormat.format(data.totalTokens || 0)} />
          <Metric label="总消费" value={moneyFormat.format(data.totalActualCost || 0)} tone="money" />
        </div>
      ) : (
        <div className="error">
          {data.error || "读取失败"}
        </div>
      )}
    </div>
  );
};

export const style = `
  .card {
    border: 1px solid rgba(148, 163, 184, 0.22);
    border-radius: 8px;
    background: rgba(15, 23, 42, 0.72);
    box-shadow: 0 18px 42px rgba(2, 6, 23, 0.32);
    -webkit-backdrop-filter: blur(18px);
    backdrop-filter: blur(18px);
    padding: 14px;
  }

  .header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 12px;
  }

  .title {
    font-size: 13px;
    line-height: 1.25;
    font-weight: 700;
    letter-spacing: 0;
  }

  .subtitle {
    margin-top: 3px;
    color: rgba(203, 213, 225, 0.72);
    font-size: 11px;
    line-height: 1.3;
    letter-spacing: 0;
  }

  .status {
    width: 8px;
    height: 8px;
    border-radius: 999px;
    margin-top: 4px;
    flex: 0 0 auto;
  }

  .status.ok {
    background: #34d399;
    box-shadow: 0 0 14px rgba(52, 211, 153, 0.75);
  }

  .status.bad {
    background: #fb7185;
    box-shadow: 0 0 14px rgba(251, 113, 133, 0.7);
  }

  .metrics {
    display: grid;
    grid-template-columns: 1fr;
    gap: 8px;
  }

  .metric {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 10px;
    border-top: 1px solid rgba(148, 163, 184, 0.14);
    padding-top: 8px;
  }

  .metric-label {
    color: rgba(203, 213, 225, 0.76);
    font-size: 11px;
    line-height: 1.2;
    letter-spacing: 0;
    white-space: nowrap;
  }

  .metric-value {
    color: #f8fafc;
    font-size: 18px;
    line-height: 1.1;
    font-weight: 750;
    letter-spacing: 0;
    text-align: right;
    word-break: break-word;
  }

  .metric.money .metric-value {
    color: #86efac;
  }

  .error {
    border-top: 1px solid rgba(251, 113, 133, 0.22);
    padding-top: 10px;
    color: #fecdd3;
    font-size: 12px;
    line-height: 1.45;
  }
`;
