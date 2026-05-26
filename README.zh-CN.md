# Sub2API 今日 Token 用量桌面挂件

[English](README.md)

一个 macOS 桌面小挂件，用来查看 Sub2API 今天的用量数据：

- 总请求数
- 总 Token
- 缓存命中 Token
- 总消费
- 根据今日 Token 用量给出轻量提醒

挂件会直接调用 Sub2API 接口登录和刷新数据，不依赖 Chrome 或其他浏览器。服务地址、登录凭据和 token 都保存在 macOS Keychain 中，不会写入仓库配置文件。

## 环境要求

- macOS
- Node.js 18+，命令行可使用 `node`
- Swift 工具链 / Xcode Command Line Tools
- 一个兼容 Sub2API 的管理站点，并提供：
  - `GET /api/v1/usage/stats`
  - `POST /api/v1/auth/login`
  - `POST /api/v1/auth/refresh`

如果没有安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

## 配置方式

首次启动原生挂件时，会弹出 macOS 输入框，让你填写：

- Sub2API 服务地址，例如 `https://your-sub2api.example.com`
- 登录邮箱
- 登录密码

这些信息会保存到 Keychain 的 `sub2api-usage-widget` 服务下。挂件之后会自动登录、保存 `access_token` 和 `refresh_token`，并在 token 过期后自动续期。

如果服务地址或密码后续发生变化，或者登录失败，挂件会再次弹出配置窗口。取消后不会卡住，双击挂件可以再次刷新并触发配置。

高级用户也可以创建 `sub2api-usage.widget/config.json`，通过 `baseUrl` 覆盖 Keychain 中保存的服务地址。

无界面环境或排障时，也可以使用脚本保存配置：

```bash
./scripts/configure-credentials.sh
```

## 手动运行

本地开发时，构建并启动原生挂件：

```bash
./scripts/run-native-widget.sh
```

挂件每 5 分钟自动刷新一次。可以拖动挂件背景移动位置，也可以双击挂件立即刷新。点击右上角折叠按钮后，挂件会缩成 `T` 图标并贴到最近的左/右屏幕边缘；再次点击小图标即可恢复。展开/折叠状态和位置会在重启后保留。

## 构建 macOS App

构建轻量 App：

```bash
./scripts/build-app.sh
```

构建产物位置：

```text
dist/Sub2API Usage Widget.app
```

你可以把这个 App 复制到 `/Applications` 或任意目录，然后双击启动。当前 App 是轻量封装，内部仍会调用打包进去的 `fetch-usage.mjs`，所以机器上仍需要安装 Node.js 18+。

## 登录后自动启动

把 App 安装为 macOS LaunchAgent：

```bash
./scripts/install-launch-agent.sh
```

安装脚本会构建 App，并把它复制到：

```text
~/Library/Application Support/Sub2APIUsageWidget
```

同时注册：

```text
~/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist
```

安装后，macOS 登录时会自动启动 App。

手动重启挂件：

```bash
launchctl kickstart -k "gui/$(id -u)/com.abnerchen.sub2api-usage-widget"
```

关闭自启动：

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.abnerchen.sub2api-usage-widget.plist"
```

启动日志位置：

```text
~/Library/Application Support/Sub2APIUsageWidget/logs
```

## 测试取数

直接运行取数脚本：

```bash
node sub2api-usage.widget/scripts/fetch-usage.mjs
```

成功输出类似：

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

## 运行测试

```bash
node --test sub2api-usage.widget/test/fetch-usage.test.mjs
```

## 用量提醒规则

- `< 20M` Token：健康
- `20M-50M` Token：提醒
- `> 50M` Token：警告

每次刷新时，挂件会从当前档位随机选择一条更自然的提醒文案。

## 说明

仓库中仍保留了 Übersicht 版本入口 `sub2api-usage.widget/index.jsx`。不过推荐使用原生挂件，因为它在当前 macOS 上更稳定，并支持首次配置弹窗、自启动和拖动。

当前 App 是轻量封装版。未来如果要做完全原生版，可以把 API 取数和 token 刷新逻辑迁移到 Swift 中，进一步移除 Node.js 依赖。
