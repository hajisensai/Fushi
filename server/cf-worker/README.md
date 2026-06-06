# Hibiki 报错日志接收 Worker（Cloudflare Worker + D1）

CF 边缘上的报错日志接收端点，**零服务器、免备案、免费额度内即可用**。App 上传 JSON 日志，Worker 把它当字符串存进 D1（serverless SQLite）；管理员经浏览器用 HTTP Basic Auth 查看列表与单条日志。

存储用 D1 而非 Workers KV：**D1 强一致**（上传后立刻可在列表读到，KV 是最终一致），写入上限更高（约 10 万次/天，免绑卡），且天然支持按 SQL 做保留数清理。

这是 Go 自有服务器版（`server/log-collector/`）的**无服务器替代方案**，两者择一部署即可。

## 安全模型

- **上传**：验 `X-Upload-Token`（与 secret 常数时间比较）。
- **查看**：HTTP Basic Auth（列表 `/` 与单条 `/log/<id>`）。
- **日志只存取不执行**：正文一律以 `text/plain; charset=utf-8` 原样吐回，浏览器当纯文本，脚本不执行；并发 `X-Content-Type-Options: nosniff` / `Content-Security-Policy: default-src 'none'` / `Cache-Control: no-store`。
- **列表 HTML 转义**：列表页对 id 做 HTML 转义，杜绝注入。
- **白名单 id**：读取前过 `^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$` 正则；D1 用参数化查询（`?1` 绑定），无字符串拼接，SQL 注入与路径穿越天然不存在，但仍做白名单兜底。
- **fail-closed**：缺任一关键 secret（`UPLOAD_TOKEN`/`BASIC_USER`/`BASIC_PASS`）时整体返回 500，绝不带病服务（避免空 secret 让鉴权门洞开）。
- **限大小**：先看 `Content-Length`，再读 body 后用 `TextEncoder` 复核字节数，超 512KB 返回 413（防客户端少报 Content-Length）。
- token 可被逆向，但只授权写入，无法读取或越权。

> 注意：Worker 本身就是 CF 边缘端点，没有「源站」概念，因此**不需要** Go 版里的 `X-EO-Secret` 防绕过头。

## 前置

- 一个 Cloudflare 账号。
- 一个已托管在 Cloudflare 的域名（用于绑自定义域名；该域名免备案）。
- 本机 Node ≥ 18 / npm。

## 部署步骤

```bash
cd server/cf-worker
npm install

# 登录 Cloudflare
npx wrangler login

# 创建 D1 数据库，把返回的 database_id 填进 wrangler.toml 的 database_id 字段
npx wrangler d1 create hibiki-logs

# 建表（远端）
npx wrangler d1 execute hibiki-logs --remote --file=schema.sql

# 设 3 个 secret（各生成高熵值）
#   生成示例：openssl rand -hex 32
npx wrangler secret put UPLOAD_TOKEN
npx wrangler secret put BASIC_USER
npx wrangler secret put BASIC_PASS

# 部署
npx wrangler deploy
```

### 保留数清理（RETAIN）

每次上传后会按 SQL `DELETE` 只保留最近 N 条日志（按 id DESC，最新在前）。N 由环境变量 `RETAIN` 控制，**默认 2000**。可在 `wrangler.toml` 加 `[vars]` 段设置：

```toml
[vars]
RETAIN = "2000"
```

也可用 `wrangler secret put RETAIN` 或部署环境变量设置；非正整数/缺失时回落默认 2000。

### 绑自定义域名

Workers & Pages → 你的 Worker → Settings → Domains & Routes → 添加 `logs.你的域名.com`（该域名需已托管在 Cloudflare）。

### 安全 / 限流（可选）

- CF 控制台对 `/api/logs` 加 Rate limiting rule，防滥用上传。
- 查看页已发 `Cache-Control: no-store`，CF 不会缓存鉴权内容。

## App 构建

```bash
flutter build apk --release \
  --dart-define=HIBIKI_LOG_ENDPOINT=https://logs.你的域名.com/api/logs \
  --dart-define=HIBIKI_LOG_TOKEN=<UPLOAD_TOKEN>
```

## 测试

```bash
npm test
```

vitest 在 Node 下直接 `import worker from '../src/worker.js'` 调 `worker.fetch(request, env)`，D1 用假 DB（SQL 前缀感知）注入，覆盖纯函数与路由（含路径穿越、XSS 惰化、fail-closed、413、强一致、RETAIN 保留数清理等）。

## 与 Go 自有服务器版对比

| 维度 | CF Worker 版（本目录） | Go 源站版（`server/log-collector/`） |
|---|---|---|
| 服务器 | 零服务器 | 需自有服务器 |
| 备案 | 免（CF 边缘） | 视部署而定 |
| 成本 | 免费额度内 | 服务器成本 |
| 大陆访问 | 可能慢 | 可控（取决于机房） |
| 存储 | D1（serverless SQLite，强一致） | 本地文件 |

两者择一部署即可。
