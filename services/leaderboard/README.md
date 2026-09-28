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

读接口的限流交给 Cloudflare WAF 的 Rate Limiting 规则（按 IP，建议 `/v1/*` 每分钟 120 次）；
注册与上传的限流在 Worker 内（`src/ratelimit.js`）。

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
