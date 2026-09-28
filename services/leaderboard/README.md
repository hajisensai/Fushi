# Fushi 排行榜 / 公开书架 Worker

Cloudflare Worker + D1 + R2。设计与分期见
[`docs/specs/2026-09-28-leaderboard-accounts.md`](../../docs/specs/2026-09-28-leaderboard-accounts.md)。

- 账户：**邮箱验证码注册**（`src/email.js`），签名凭据是设备上生成的 ECDSA P-256 钥匙（`src/auth.js`）；
  一个账户可绑多台设备（新设备用邮箱验证码登录）。**服务端不存邮箱明文**，只存 HMAC。
- 书架**增量上报**（每批 ≤ 500）；跨用户作品靠匹配键（bgm / isbn / vndb / anidb / mal / tmdb / src / 标题+作者）汇合，见 `src/shelf.js` 文件头。
- 与日志服务（`services/log-backend/`）完全隔离，不共用任何凭据。

## 成本（防 Cloudflare / 发信超额计费）

**最重要的一条：把这个 Worker 留在 Workers Free 计划。** Free 计划超额只会报错（请求被拒），不会扣费。
在此之上，服务端自己设了硬上限，默认值都低于各家免费额度：

| 资源 | 免费额度 | 本服务的保护 |
|---|---|---|
| Workers 请求 | 10 万次/天 | 匿名读边缘缓存 60 秒；`READ_LIMITER` 每 IP 每分钟 120 次；图片走边缘缓存 |
| D1 读 | 500 万行/天 | 榜单 / 人气 / 名次读定时快照（每 30 分钟一次）；读者数、行数、计分全部增量维护；每个读接口的读行数有界，与用户总数无关 |
| D1 写 | 10 万行/天 | 增量上报；**全局日预算 `write_rows` 8 万行**（超了 503，次日恢复）；每账户每天 2 万行 |
| R2 存储 | 10 GB | 头像 ≤ 64KB、封面 ≤ 96KB；**总配额 8 GiB**（超了 507）；删除即归还 |
| R2 操作 | A 类 100 万/月、B 类 1000 万/月 | 全局日预算 `media` 3000 次上传；出图先查边缘缓存 |
| Resend 发信 | 100 封/天、3000 封/月 | 全局日预算 `email` 90 封；每 IP 每小时 5 封、每邮箱每小时 3 封 / 每天 10 封 |

代价（如实）：D1 每写一行、每个受影响索引另计一行，所以超大书架（8000 部）首次同步约 4 万行，会被拆到两三天里
续传；几百部的普通书架一次传完。榜单最多滞后 30 分钟（响应里带 `computedAt`）。

预算可用 vars 覆盖：`BUDGET_WRITE_ROWS` / `BUDGET_MEDIA` / `BUDGET_REGISTER` / `BUDGET_EMAIL` / `MEDIA_QUOTA_BYTES`。

## 部署（维护者手动）

1. **发信**：在 [Resend](https://resend.com) 注册（免费档，不绑卡就不会扣费），验证发件域名（如 `fushi.moe`），拿到 API key。
2. **Cloudflare**：

```bash
cd services/leaderboard
npm ci
npx wrangler d1 create fushi-leaderboard          # 把 database_id 填进 wrangler.toml
npx wrangler d1 migrations apply fushi-leaderboard --remote
npx wrangler r2 bucket create fushi-leaderboard-media
npx wrangler secret put ADMIN_USER
npx wrangler secret put ADMIN_PASS
npx wrangler secret put EMAIL_PEPPER               # 随机长串（如 openssl rand -hex 32）；设了就别换，换了所有邮箱都对不上
npx wrangler secret put RESEND_API_KEY
# 在 wrangler.toml 改 EMAIL_FROM 为 Resend 上已验证的发件地址；打开 routes 并填域名（建议 rank.fushi.moe）
npx wrangler deploy
```

缺 `EMAIL_PEPPER` / `RESEND_API_KEY` 时发码与注册一律 503 `email_not_configured`（fail-closed）。

## API

签名（`[签名]`）规则见 `src/auth.js` 文件头；标「写」的请求另做防重放（同一签名串只收一次）。

| 方法 | 路径 | 鉴权 | 作用 |
|---|---|---|---|
| POST | `/v1/email/code` `{email, purpose: register\|login, lang?}` | — | 发 6 位验证码（永远 202，防探测；按 IP / 邮箱限流、扣 email 预算） |
| POST | `/v1/register` `{pubkey, nickname, email, code}` | 自签 | 注册（验证码 10 分钟有效、最多试 5 次、一次性；同钥匙重复注册幂等） |
| POST | `/v1/login` `{pubkey, email, code}` | 自签 | 新设备登录：把本机钥匙绑到该邮箱的账户（每账户 ≤ 10 台） |
| GET | `/v1/me` | 签名 | 自己的账户 |
| PATCH | `/v1/me` `{nickname?, visibility?}` | 签名·写 | 改资料 |
| DELETE | `/v1/me` | 签名·写 | 删除账户与全部数据 |
| PUT / DELETE | `/v1/me/avatar` | 签名·写 | 上传 / 删除头像 |
| POST | `/v1/shelf` `{reset?, put ≤500, remove ≤500, daily ≤400}` | 签名·写 | 增量上报书架 → `{works, shelfCount}` |
| PUT | `/v1/works/:id/cover` | 签名·写 | 缺封面的作品补缩略图 |
| GET | `/v1/rank?metric&window&scope&limit&offset` | 可选 | 榜单 |
| GET | `/v1/works/popular?window&kind&limit&offset` | — | 作品人气 |
| GET | `/v1/works/:id?limit&offset` | 可选 | 作品页 |
| GET | `/v1/users/:id` / `/v1/users/:id/shelf?status&kind&limit&offset` | 可选 | 用户卡片 / 书架 |
| GET | `/v1/friends` | 签名 | `{friends:[{account, since}], incoming:[{account, at}], outgoing:[{account, at}]}` |
| POST | `/v1/friends/:id` | 签名·写 | 对方已申请 → `accepted`，否则建 `pending`；返回 `{state}`。自己 400、不存在/隐藏 404、任一方屏蔽 403 `blocked` |
| DELETE | `/v1/friends/:id` | 签名·写 | 删好友 / 撤回 / 拒绝，204（不存在也 204） |
| GET | `/v1/blocks` | 签名 | `{blocked:[account]}` |
| POST | `/v1/blocks/:id` | 签名·写 | 屏蔽并删掉双方好友关系与申请，204 |
| DELETE | `/v1/blocks/:id` | 签名·写 | 解除屏蔽，204 |
| POST | `/v1/reports` `{targetKind, targetId, reason}` | 签名·写 | 举报账户 / 作品（理由 ≤ 500 字符、目标须存在）→ 201 `{id}`；同一目标未处理举报去重 |
| GET | `/img/<key>` | — | R2 出图 |
| GET | `/u/:id`、`/w/:id`、`/rank?metric&window` | — | 只读 HTML 落地页（分享链接；匿名渲染、无脚本、边缘缓存） |

社交写（好友 / 屏蔽 / 举报）按账户每小时 120 次限流（`LIMITS.socialWritePerHour`）。被管理员隐藏的账户
不出现在任何列表里，也不能被加好友或屏蔽。

## 测试

```bash
npm test
```

测试在 Node 22+ 的 `node:sqlite` 上跑真实迁移和全部 SQL（`test/harness.js`），不需要 Cloudflare 账号。
`test/vectors/` 是跨语言签名向量：Dart 客户端生成的向量也放这里，由 `vectors.test.js` 验证 Worker 能验过。

## 管理端

HTTP Basic Auth（`ADMIN_USER` / `ADMIN_PASS`，未配置时 503 fail-closed），JSON API：

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/admin/api/reports` | 未处理举报 |
| POST | `/admin/api/reports/:id/resolve` | 标记已处理 |
| POST | `/admin/api/accounts/:id` `{hidden}` | 隐藏 / 恢复账户 |
| POST | `/admin/api/works/:id` `{title?, author?, nsfw?, clearCover?}` | 改作品（改标题/作者即锁定） |
| POST | `/admin/api/works/merge` `{from, into}` | 合并误拆的作品 |
| POST | `/admin/api/works/split` `{ref}` | 拆出误挂的别名（`ref` 带 `kind|` 前缀） |
