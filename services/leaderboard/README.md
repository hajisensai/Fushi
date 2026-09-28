# Fushi 排行榜 / 公开书架 Worker

Cloudflare Worker + D1 + R2。设计与分期见
[`docs/specs/2026-09-28-leaderboard-accounts.md`](../../docs/specs/2026-09-28-leaderboard-accounts.md)。

- 账户 = 设备上生成的 ECDSA P-256 公钥，无邮箱无密码；请求签名规则见 `src/auth.js` 文件头。
- 书架整份上报、整份替换；跨用户作品靠匹配键（bgm / isbn / vndb / tmdb / anidb / src / 标题+作者）汇合，见 `src/shelf.js` 文件头。
- 与日志服务（`services/log-backend/`）完全隔离，不共用任何凭据。

## 部署（维护者手动）

```bash
cd services/leaderboard
npm ci
npx wrangler d1 create fushi-leaderboard          # 把 database_id 填进 wrangler.toml
npx wrangler d1 migrations apply fushi-leaderboard --remote
npx wrangler r2 bucket create fushi-leaderboard-media
npx wrangler secret put ADMIN_USER
npx wrangler secret put ADMIN_PASS
# 在 wrangler.toml 打开 routes 并填域名（建议 rank.fushi.moe）
npx wrangler deploy
```

读接口：匿名请求在边缘缓存 60 秒；按 IP 限流用 Workers Rate Limiting binding（可选，不配就不限），在
`wrangler.toml` 加：

```toml
[[unsafe.bindings]]
name = "READ_LIMITER"
type = "ratelimit"
namespace_id = "1001"
simple = { limit = 120, period = 60 }
```

注册与上传的限流在 Worker 内（`src/ratelimit.js`，D1 计数）。书架上限 8000 条：D1 单个绑定参数约 2MB，
超出时返回 413 `shelf_too_large`。

## API

签名（`[签名]`）规则见 `src/auth.js` 文件头；标「写」的请求另做防重放（同一签名串只收一次）。

| 方法 | 路径 | 鉴权 | 作用 |
|---|---|---|---|
| POST | `/v1/register` `{pubkey, nickname}` | 自签 | 注册（幂等；按 IP 限流） |
| GET | `/v1/me` | 签名 | 自己的账户 |
| PATCH | `/v1/me` `{nickname?, visibility?}` | 签名·写 | 改资料 |
| DELETE | `/v1/me` | 签名·写 | 删除账户与全部数据 |
| PUT / DELETE | `/v1/me/avatar` | 签名·写 | 上传 / 删除头像 |
| POST | `/v1/shelf` `{entries, daily}` | 签名·写 | 整份替换书架 |
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
