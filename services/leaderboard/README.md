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
| Workers 请求 | 10 万次/天 | 匿名读边缘缓存 60 秒（缓存键只含白名单参数）；`READ_LIMITER` 每 IP 每分钟 120 次；未鉴权写入口先过 `AUTH_LIMITER`（每 IP 每分钟 10 次，IPv6 按 /64）；图片走边缘缓存 |
| D1 读 | 500 万行/天 | 榜单 / 人气 / 名次读定时快照（每 30 分钟一次，只读周期汇总表的当期段）；读者数、行数、周/月计分、周/月作品读者数全部增量维护；书架 / 作品读者用游标分页（每页只读 limit+1 行）；`test/plans.test.js` 在查询计划上断言每个读接口不全表扫描、不建临时 B 树 |
| D1 写 | 10 万行/天 | 增量上报；**全局日预算 `write_rows` 8 万行**（超了 503，次日恢复）；每账户每天 2 万行 |
| R2 存储 | 10 GB | 头像 ≤ 64KB、封面 ≤ 96KB；**总配额 8 GiB**（超了 507）；删除即归还 |
| R2 操作 | A 类 100 万/月、B 类 1000 万/月 | 全局日预算 `media` 3000 次上传；出图先查边缘缓存 |
| Resend 发信 | 100 封/天、3000 封/月 | 全局日预算 `email` 90 封；每 IP 每小时 5 封、每邮箱每小时 3 封 / 每天 10 封 |

代价（如实）：D1 每写一行、每个受影响索引另计一行，所以超大书架（8000 部）首次同步约 4 万行，会被拆到两三天里
续传；几百部的普通书架一次传完。榜单最多滞后 30 分钟（响应里带 `computedAt`）。

预算可用 vars 覆盖：`BUDGET_WRITE_ROWS` / `BUDGET_MEDIA` / `BUDGET_REGISTER` / `BUDGET_EMAIL` / `BUDGET_FEEDBACK`（每天新反馈条数，默认 300）/ `MEDIA_QUOTA_BYTES`。反馈附件与头像 / 封面共用 R2 配额与 `media` 预算，已结案 90 天的反馈附件由定时任务清掉。

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

> ⚠️ **部署命令一律显式指定配置，别在别的目录裸跑 `npx wrangler deploy`**：
> `node services/leaderboard/node_modules/wrangler/bin/wrangler.js deploy --config services/leaderboard/wrangler.toml`。
> 在没有 wrangler 配置的目录里裸跑时，`npx` 会拉最新 wrangler 4，它的 autoconfig 会把当前目录当静态站点、
> **以目录名新建一个 Worker 并把某个子目录（实测是 `docs/`）当公开静态资源上传**，还会顺手写
> `wrangler.jsonc` / 改 `.gitignore`（2026-09-29 实际发生过一次，已删除，上传的只是公开仓库里已入库的文档）。

当前线上部署（2026-09-29）：Worker `fushi-leaderboard`（`https://rank.fushi.moe`）、D1 `fushi-leaderboard`、
R2 `fushi-leaderboard-media`；`ADMIN_USER` / `ADMIN_PASS` / `EMAIL_PEPPER` 已设，本机副本在维护者机器
`~/.fushi/leaderboard-secrets.json`（不入库；**`EMAIL_PEPPER` 丢了所有邮箱都对不上**）。发信渠道待定：
Workers Paid 账户用 Cloudflare Email Service（在 `wrangler.toml` 加 `[[send_email]] name = "EMAIL"`，并在
dashboard 的 Email Sending 里 Onboard 发件域名），否则用 Resend（`wrangler secret put RESEND_API_KEY`）。

部署后还要知道的：

- **App 默认连 `https://rank.fushi.moe`**（`fushi/lib/src/leaderboard/leaderboard_service.dart` 的
  `kLeaderboardDefaultBaseUrl`）。域名没配好之前，App 里的排行功能不可用（显示「排行服务尚未部署」）。
  换域名就改这个常量。
- **首次部署后立刻调一次 `POST /admin/api/snapshots/refresh`**（或等 30 分钟定时任务），否则榜单为空
  （客户端显示「榜单生成中」）。
- `READ_LIMITER` / `AUTH_LIMITER` / `ACCOUNT_LIMITER` 是 Workers Rate Limiting binding（`[[unsafe.bindings]]`
  `type = "ratelimit"`）；部署前确认账户可用。不可用时代码会跳过这几道限流（其余 D1 计数限流与日预算照常），
  但成本保护会变弱，**请以可用为准**。
- 仓库 CI（`.github/workflows/leaderboard-worker.yml`）**只跑测试、不部署**；上线由维护者手动触发——
  用下面的 GitHub Actions 部署，或在本机按上面的显式 `--config` 命令 `wrangler deploy`。

## 用 GitHub Actions 部署

`.github/workflows/leaderboard-worker-deploy.yml`，**只能手动触发**（Actions → leaderboard-worker-deploy →
Run workflow），push / PR 永远不会部署。维护者不需要在自己机器上 `wrangler login`。

- 输入：`ref`（要部署的分支 / tag / 提交，默认 `develop`）、`apply_migrations`（默认关；打开后先执行
  `d1 migrations apply fushi-leaderboard --remote`，新增迁移的版本要勾上）。
- 步骤：checkout `ref` → `npm ci` → `npm test`（**测试不过不部署**）→ 打印 `wrangler whoami` 与将要部署的
  提交号 →（可选）D1 迁移 → `wrangler deploy --config services/leaderboard/wrangler.toml` →
  `GET https://rank.fushi.moe/v1/health` 必须 200。用的是 `package-lock.json` 锁定的 wrangler，不走 `npx`。
- 凭据：优先读 secret `CLOUDFLARE_WORKERS_API_TOKEN`，没配就回退到 `CLOUDFLARE_API_TOKEN`（原本给
  `mirror-releases.yml` 的 R2 镜像用）；账户 ID 读 `CLOUDFLARE_ACCOUNT_ID`。token 至少要有
  「Account → Workers Scripts: Edit」，勾 `apply_migrations` 还要「Account → D1: Edit」；若 deploy 报
  自定义域名 / route 相关的权限错误，再加限定 `fushi.moe` 的「Zone → Workers Routes: Edit」。
  现有 token 只有 R2 权限时，二选一：在 Cloudflare 后台给它加上述权限，或另建一个 token 存成
  `CLOUDFLARE_WORKERS_API_TOKEN`（推荐，R2 镜像与 Worker 部署权限分开）。
- 跑在 environment `leaderboard-production` 里：在仓库 Settings → Environments 给它配 Required reviewers
  就变成「点了运行还要审批」；不配也能直接跑。token 也可以只存成该 environment 的 secret。
- 同一时刻只跑一次部署（concurrency 组 `leaderboard-worker-deploy`），后来者排队，不会取消正在跑的部署。
- Worker 的运行时 secret（`ADMIN_USER` / `ADMIN_PASS` / `EMAIL_PEPPER` / `RESEND_API_KEY`）已存在 Cloudflare
  上，`wrangler deploy` 不会动它们；这个 workflow 也不负责设置它们。

## API

签名（`[签名]`）规则见 `src/auth.js` 文件头；标「写」的请求另做防重放（同一签名串只收一次）。

| 方法 | 路径 | 鉴权 | 作用 |
|---|---|---|---|
| POST | `/v1/email/code` `{email, purpose: register\|login, lang?}` | — | 发 6 位验证码（永远 202，防探测；按 IP / 邮箱限流、扣 email 预算） |
| POST | `/v1/register` `{pubkey, nickname, email, code}` | 自签 | 注册（验证码 10 分钟有效、最多试 5 次、一次性；同钥匙重复注册幂等） |
| POST | `/v1/login` `{pubkey, email, code}` | 自签 | 新设备登录：把本机钥匙绑到该邮箱的账户（每账户 ≤ 10 台） |
| GET | `/v1/me` | 签名 | 自己的账户（含 `uploadDevice`、`shelfCount`） |
| GET | `/v1/me/devices` | 签名 | 已登录设备 `{devices:[{keyId, createdAt, lastUsedAt, current}]}` |
| DELETE | `/v1/me/devices/:keyId` | 签名·写 | 解绑另一台设备（不能解绑当前设备：400 `cannot_remove_current`；解绑上传设备会清空上传设备） |
| PATCH | `/v1/me` `{nickname?, visibility?}` | 签名·写 | 改资料 |
| DELETE | `/v1/me` | 签名·写 | 删除账户与全部数据 |
| PUT / DELETE | `/v1/me/avatar` | 签名·写 | 上传 / 删除头像 |
| POST | `/v1/shelf` `{reset?, claim?, put ≤500, remove ≤500, daily ≤400}` | 签名·写 | 增量上报书架 → `{works, shelfCount}`。同账户并发写 → 409 `conflict`（整批已回滚，重试即可）；每账户只有一台上传设备，别的设备 → 409 `upload_owned_by_other_device`，`reset + claim` 接管 |
| PUT | `/v1/works/:id/cover` | 签名·写 | 缺封面的作品补缩略图 |
| GET | `/v1/rank?metric&window&scope&limit&offset` | 可选 | 榜单 |
| GET | `/v1/works/popular?window&kind&limit&offset` | — | 作品人气 |
| GET | `/v1/works/:id?limit&cursor` | 可选 | 作品页（读者列表游标分页，响应带 `next`） |
| GET | `/v1/users/:id` / `/v1/users/:id/shelf?status&kind&limit&cursor` | 可选 | 用户卡片 / 书架（游标分页，响应带 `next`） |
| GET | `/v1/friends` | 签名 | `{friends:[{account, since}], incoming:[{account, at}], outgoing:[{account, at}]}` |
| POST | `/v1/friends/:id` | 签名·写 | 对方已申请 → `accepted`，否则建 `pending`；返回 `{state}`。自己 400、不存在/隐藏 404、任一方屏蔽 403 `blocked` |
| DELETE | `/v1/friends/:id` | 签名·写 | 删好友 / 撤回 / 拒绝，204（不存在也 204） |
| GET | `/v1/blocks` | 签名 | `{blocked:[account]}` |
| POST | `/v1/blocks/:id` | 签名·写 | 屏蔽并删掉双方好友关系与申请，204 |
| DELETE | `/v1/blocks/:id` | 签名·写 | 解除屏蔽，204 |
| POST | `/v1/reports` `{targetKind, targetId, reason}` | 签名·写 | 举报账户 / 作品（理由 ≤ 500 字符、目标须存在）→ 201 `{id}`；同一目标未处理举报去重 |
| GET | `/img/<key>` | — | R2 出图 |
| GET | `/u/:id`、`/w/:id`、`/rank?metric&window` | — | 只读 HTML 落地页（分享链接；匿名渲染、无脚本、边缘缓存） |
| POST | `/v1/feedback` `{category, title, body, contact?, meta?}` | 可选签名 | 提交反馈 → 201 `{id, ticket}`（ticket 只返回这一次；带签名 = 关联账户）。每 IP 每小时 10 条，日预算 `feedback`；同来源同内容 1 小时内 409 `duplicate_feedback`；伪装字符剥掉、注入 / 链接 / 跨来源重复只打标记（`flags`，仅开发者可见） |
| PUT | `/v1/feedback/:id/attachments/:slot` | `X-Fushi-Ticket` | 补传附件：`s0`..`s2` 截图（PNG/JPEG/WebP ≤ 1.5 MiB）、`log`（gzip ≤ 2 MiB）；提交后 24 小时内、每槽一次（重复 409 `slot_taken`） |
| POST | `/v1/feedback/status` `{items:[{id, ticket}] ≤ 50}` | — | 批量查进度（ticket 不对的条目不返回） |
| GET | `/v1/feedback/:id` | `X-Fushi-Ticket` | 详情 + 处理时间线 |
| POST | `/v1/feedback/:id/messages` `{body}` | `X-Fushi-Ticket` | 反馈人追加说明（已结案会重新打开） |
| GET | `/v1/dev/feedback?status&cursor&limit` | 签名·开发者 | 处理台列表（`status=active` = 未结案，`status=flagged` = 带风险标记） |
| GET | `/v1/dev/feedback/:id` | 签名·开发者 | 详情（含联系方式 / 设备信息 / 反馈人） |
| GET | `/v1/dev/feedback/:id/attachments/:slot[?view=text]` | 签名·开发者 | 附件；日志 `view=text` 服务端流式解压 |
| POST | `/v1/dev/feedback/:id` `{status?, reply?}` | 签名·写·开发者 | 改状态 / 回复 |
| POST | `/v1/dev/feedback/:id/notes` `{aiSummary?, devNote?}` | 签名·写·开发者 | AI 总结 / 开发者批改（仅开发者可见，反馈人接口不返回；空白 = 清除）。本机 CLI：`node scripts/feedback.mjs`（list / show / summarize），见 `docs/specs/2026-10-08-feedback.md` |
| GET/POST | `/dev/**` | 会话 Cookie | 开发者网页处理台（邮箱验证码登录，仅 role = dev；无脚本、POST 验 Origin） |

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
| POST | `/admin/api/snapshots/refresh` | 立刻重算榜单快照（部署后第一次、或不想等定时任务时） |
| POST | `/admin/api/accounts/:id/devices/clear` | 清空账户全部设备（用户设备名额满又没有一台还登录着时；之后用邮箱验证码重新登录） |
| POST | `/admin/api/works/merge` `{from, into}` | 合并误拆的作品 |
| POST | `/admin/api/works/split` `{ref}` | 拆出误挂的别名（`ref` 带 `kind|` 前缀） |
| POST | `/admin/api/accounts/:id/role` `{role: 'dev'\|'user'}` | 设 / 撤开发者（反馈处理台；撤销时网页会话一并作废） |

反馈系统（回执、附件、开发者处理、防投毒、清理策略）设计见
[`docs/specs/2026-10-08-feedback.md`](../../docs/specs/2026-10-08-feedback.md)。
