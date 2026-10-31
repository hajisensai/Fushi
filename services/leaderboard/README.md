# Fushi 排行榜 / 公开书架 Worker

Cloudflare Worker + D1 + R2。设计与分期见
[`docs/specs/2026-09-28-leaderboard-accounts.md`](../../docs/specs/2026-09-28-leaderboard-accounts.md)。

- 账户：**邮箱验证码注册**（`src/email.js`），签名凭据是设备上生成的 ECDSA P-256 钥匙（`src/auth.js`）；
  一个账户可绑多台设备（新设备用邮箱验证码登录）。**服务端不存邮箱明文**，只存 HMAC。
  身份按规范化邮箱判定（`canonicalEmail`：Gmail / googlemail 去点与 `+tag`；Outlook / Hotmail / Live / MSN、
  iCloud / me / mac、Proton、Fastmail 去 `+tag`；其余域名只做 NFKC + 去空白 + 小写 + IDN 转 punycode）；
  验证码仍发到用户输入的地址（保留别名，域名同样转 punycode）。**只对 2026-10-17 之后的注册彼此之间成立**：
  之前以别名存下哈希的历史账户，在它自己登录一次、哈希惰性升级之前，别人用规范形式或其它别名仍能新注册——
  服务端只存 HMAC、没有明文，这是结构性限制。升级冲突见 `GET /admin/api/email-conflicts`；旧规则存下、
  而 NFKC / punycode 会改写成另一个地址的老账户不回退旧哈希（码会发去另一个收件箱），只能联系管理员。
- 书架**增量上报**（每批 ≤ 500）；跨用户作品靠匹配键（bgm / isbn / vndb / anidb / mal / tmdb / src / 标题+作者）汇合，见 `src/shelf.js` 文件头。
- 与日志服务（`services/log-backend/`）完全隔离，不共用任何凭据。
- **AI 额度消耗**：`POST /v1/ci/usage`（Bearer `USAGE_UPLOAD_TOKEN`，没配则 404）收维护者机器按「UTC 日 × 模型」汇总的 Claude Code 用量，`GET /usage` 公开展示近 30 天（只存计数，不含项目名 / 提示词）。上传端 `tool/claude_usage_upload.mjs`，计划任务安装 `tool/install_claude_usage_upload.ps1`；部署前先 `d1 migrations apply` 到 `0019_ai_usage.sql`，再 `wrangler secret put USAGE_UPLOAD_TOKEN`。

## 成本（防 Cloudflare / 发信超额计费）

**最重要的一条：把这个 Worker 留在 Workers Free 计划。** Free 计划超额只会报错（请求被拒），不会扣费。
在此之上，服务端自己设了硬上限，默认值都低于各家免费额度：

| 资源 | 免费额度 | 本服务的保护 |
|---|---|---|
| Workers 请求 | 10 万次/天 | 匿名读边缘缓存 60 秒（缓存键只含白名单参数）；`READ_LIMITER` 每 IP 每分钟 120 次；未鉴权写入口先过 `AUTH_LIMITER`（每 IP 每分钟 10 次，IPv6 按 /64）；图片走边缘缓存 |
| D1 读 | 500 万行/天 | 榜单 / 人气 / 名次读定时快照（每 30 分钟一次，只读周期汇总表的当期段）；读者数、行数、周/月计分、周/月作品读者数全部增量维护；书架 / 作品读者用游标分页（每页只读 limit+1 行）；`test/plans.test.js` 在查询计划上断言每个读接口不全表扫描、不建临时 B 树 |
| D1 写 | 10 万行/天 | 增量上报；**全局日预算 `write_rows` 8 万行**（超了 503，次日恢复）；每账户每天 2 万行；安装统计心跳另有日预算 `ping` 4000 个安装（每个约 5 行，同一安装当天第二次心跳只读不写） |
| R2 存储 | 10 GB | 头像 ≤ 64KB、封面 ≤ 96KB；反馈截图 ≤ 1.5 MiB、日志 ≤ 2 MiB（结案 90 天清）；**反馈视频 ≤ 50MB，结案 7 天 / 创建 30 天（先到者）到期清理**，流式写入不进 Worker 内存；**总配额 8 GiB**（超了 507，按声明长度预占）；删除即归还。总配额分两池：**反馈视频单独 1 GiB**（`media_usage.video_bytes`，满了 507 `video_quota`，只拒视频），头像 / 封面 / 反馈截图与日志用其余 7 GiB（满了 507 `media_quota`），两池互不挤占；**视频每上传 IP 每天 ≤ 200 MB**（按声明长度计，超了 429） |
| R2 操作 | A 类 100 万/月、B 类 1000 万/月 | 全局日预算 `media` 3000 次上传；出图先查边缘缓存 |
| 发信：Brevo SMTP（配了 `SMTP_*` 时）或 Resend | Brevo 300 封/天；Resend 100 封/天、3000 封/月 | 全局日预算 `email` 默认 90 封，`wrangler.toml` 走 Brevo 时设为 280；每 IP 每小时 5 封、每邮箱每小时 3 封 / 每天 10 封 |

代价（如实）：D1 每写一行、每个受影响索引另计一行，所以超大书架（8000 部）首次同步约 4 万行，会被拆到两三天里
续传；几百部的普通书架一次传完。榜单最多滞后 30 分钟（响应里带 `computedAt`）。

预算可用 vars 覆盖：`BUDGET_WRITE_ROWS` / `BUDGET_MEDIA` / `BUDGET_REGISTER` / `BUDGET_EMAIL` / `BUDGET_FEEDBACK`（每天新反馈条数，默认 300）/ `BUDGET_PING`（每天记入统计的安装数，默认 4000）/ `MEDIA_QUOTA_BYTES` / `VIDEO_QUOTA_BYTES`（反馈视频池，默认 1 GiB，最多切走总配额一半；从总配额里切出，不另加）。反馈截图与日志和头像 / 封面共用普通池与 `media` 预算，反馈视频另占视频池（同样扣 `media` 次数），已结案 90 天的反馈附件由定时任务清掉。

代价（如实）：视频池按「30 天保留 × 每 IP 每天 200 MB」算，五六个 IP 一天就能把视频池占满，之后到最早的视频过期前新视频一律 507 `video_quota`（App 留在待传区、24 小时补传窗口内可重试）；头像 / 封面 / 截图不受影响。

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
npx wrangler secret put FEEDBACK_CI_TOKEN          # 可选：CI 回填反馈修复 / 发布（随机长串；同一值存进 GitHub secret FEEDBACK_CI_TOKEN）
npx wrangler secret put CF_ANALYTICS_TOKEN         # 可选：处理台 /dev/project 的官网访问量（API token，Zone · Analytics · Read，限 zone fushi.moe）
npx wrangler secret put GITHUB_TOKEN               # 可选：/dev/project 走认证配额；token 有仓库 push 权限时另显示 GitHub 访问 / clone
# 在 wrangler.toml 改 EMAIL_FROM 为 Resend 上已验证的发件地址；打开 routes 并填域名（建议 rank.fushi.moe）
npx wrangler deploy
```

缺 `EMAIL_PEPPER` / `RESEND_API_KEY` 时发码与注册一律 503 `email_not_configured`（fail-closed）。

> ⚠️ **部署命令一律显式指定配置，别在别的目录裸跑 `npx wrangler deploy`**：
> `node services/leaderboard/node_modules/wrangler/bin/wrangler.js deploy --config services/leaderboard/wrangler.toml`。
> 在没有 wrangler 配置的目录里裸跑时，`npx` 会拉最新 wrangler 4，它的 autoconfig 会把当前目录当静态站点、
> **以目录名新建一个 Worker 并把某个子目录（实测是 `docs/`）当公开静态资源上传**，还会顺手写
> `wrangler.jsonc` / 改 `.gitignore`（2026-09-29 实际发生过一次，已删除，上传的只是公开仓库里已入库的文档）。

当前线上部署（2026-10-16 更新）：Worker `fushi-leaderboard`（`https://rank.fushi.moe`）、D1 `fushi-leaderboard`、
R2 `fushi-leaderboard-media`；D1 迁移已应用到 `0010_feedback_push_tokens.sql`，代码为 develop `f56c6aa`（Worker
版本 `23314599`；APNs 的 `APNS_*` secrets 尚未设置，推送按设计静默跳过）（本机按
`leaderboard-worker-deploy.yml` 同样的步骤先跑测试再部署——该 workflow 只在 develop 上、不在默认分支，GitHub
不允许对它 `workflow_dispatch`）。`ADMIN_USER` / `ADMIN_PASS` / `EMAIL_PEPPER` / `RESEND_API_KEY` /
`FEEDBACK_CI_TOKEN` 已设（`FEEDBACK_CI_TOKEN` 同值也存进了 GitHub 仓库 secret），本机副本在维护者机器
`~/.fushi/leaderboard-secrets.json`（不入库；**`EMAIL_PEPPER` 丢了所有邮箱都对不上**）。发信当前走 Resend；要换渠道时：
Workers Paid 账户用 Cloudflare Email Service（在 `wrangler.toml` 加 `[[send_email]] name = "EMAIL"`，并在
dashboard 的 Email Sending 里 Onboard 发件域名），否则用 Resend（`wrangler secret put RESEND_API_KEY`）。

> ⚠️ **新增迁移的版本必须先迁移再部署**（Actions 部署每次都会自动先迁移再部署；本机部署则先跑上面的 `d1 migrations apply --remote`）。
> `0007_feedback_video_mine.sql`（`feedback.has_video` + 两个索引）：没迁移就部署时视频补传、`GET /v1/feedback/mine` 与定时清理会 500。
> `0008_media_video_pool.sql`（`media_usage.video_bytes`，反馈视频配额池）：没迁移就部署时视频补传与视频到期清理会 500。
> 例如 `0006_feedback_dev_notes.sql`：新代码的处理台列表显式选 `ai_summary` 列，没迁移就部署时 `/v1/dev/feedback` 与网页 `/dev` 会整页 500（反馈人接口不受影响）。迁移只加列，先迁移、旧代码照跑不受影响。
> `0011_install_stats.sql`（`installs` / `install_days` 两张表 + `feedback.install_id`）：没迁移就部署时 `POST /v1/ping`、反馈提交、处理台详情与定时清理都会 500——**这条迁移碰了反馈提交，务必先迁移**。
> `0014_cover_replace_guard.sql`（`cover_votes.confirmed` / `works.cover_cleared_at` 两列 + `cover_mismatches` 表 + 一个部分索引）：纯增量，旧 Worker 在线时先迁移不受影响；没迁移就部署时封面投票 / 上传 / 物化、删号与定时任务都会 500——**务必先迁移**（Actions 部署自动先迁移）。
> `0013_install_verified.sql`（`installs.verified` / `install_days.verified` / `feedback.install_verified`，安装证明）：没迁移就部署时心跳、反馈提交、`/dev/stats` 与反馈详情都会 500——**同样碰了反馈提交，务必先迁移**。只加带默认值的列，旧 Worker 在线时先迁移不受影响。
> `0017_install_dimensions.sql`（`installs` / `install_days` 各加可空列 `country` / `locale` / `arch` / `os_version` / `source`）：没迁移就部署时心跳与 `/dev/stats` 会 500（反馈提交不受影响）——**先迁移**。纯增量，旧 Worker 在线时先迁移不受影响；迁移前的历史记录这些列为 NULL，统计页显示「未记录 / 未上报」。
> `0018_project_stats.sql`（新表 `repo_daily` / `site_daily` / `project_meta`，处理台 `/dev/project`）：没迁移就部署时定时任务的最后一步与 `/dev/project` 会 500（其余接口不受影响）——**先迁移**。纯新表。
> `0009_feedback_release.sql`（修复 / 发布追踪列）同理：处理台列表显式选 `fix_*` 列，`/v1/ci/feedback/**` 也读写这些列，没迁移就部署时都会 500（反馈人接口 `SELECT *` 不受影响，`fix` 恒为 null）。

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

- 输入：`ref`（要部署的分支 / tag / 提交，默认 `develop`）。没有迁移开关：每次部署都先执行
  `d1 migrations apply fushi-leaderboard --remote`（幂等，无待执行迁移时为空操作；迁移失败则不部署）。
  原先的 `apply_migrations` 开关默认关，漏勾就是「先部署、后迁移」，心跳等接口 500（#2433），已移除。
- 步骤：checkout `ref` → `npm ci` → `npm test`（**测试不过不部署**）→ 校验 Cloudflare token（只打状态，不用会泄露账户邮箱的 `wrangler whoami`）并打印将要部署的
  提交号 → D1 迁移 → `wrangler versions upload` + `versions deploy <id>@100%`（不用 `wrangler deploy`，见下）→
  触发器核对（`scripts/triggers_in_sync.mjs`：自定义域名 / crons / workers.dev 与 `wrangler.toml` 一致就跳过，
  否则 `wrangler triggers deploy`）→ `GET https://rank.fushi.moe/v1/health` 必须 200。
  拆开的原因（BUG-3661）：`wrangler deploy` 每次都先读 zone 的 `/workers/routes` 查冲突，只配 custom_domain
  也读，token 缺 zone 权限时 Worker 已上线、workflow 却报红。用的是 `package-lock.json` 锁定的 wrangler，不走 `npx`。
- 凭据：优先读 secret `CLOUDFLARE_WORKERS_API_TOKEN`，没配就回退到 `CLOUDFLARE_API_TOKEN`（原本给
  `mirror-releases.yml` 的 R2 镜像用）；账户 ID 读 `CLOUDFLARE_ACCOUNT_ID`。token 至少要有
  「Account → Workers Scripts: Edit」与「Account → D1: Edit」（每次都迁移）。限定 `fushi.moe` 的
  「Zone → Workers Routes: Edit」只在触发器有变更（改了 `routes` / crons）时才用到；缺它时那次部署的
  Sync triggers 步骤会报红。
  现有 token 只有 R2 权限时，二选一：在 Cloudflare 后台给它加上述权限，或另建一个 token 存成
  `CLOUDFLARE_WORKERS_API_TOKEN`（推荐，R2 镜像与 Worker 部署权限分开）。
- 跑在 environment `leaderboard-production` 里：在仓库 Settings → Environments 给它配 Required reviewers
  就变成「点了运行还要审批」；不配也能直接跑。token 也可以只存成该 environment 的 secret。
- 同一时刻只跑一次部署（concurrency 组 `leaderboard-worker-deploy`），后来者排队，不会取消正在跑的部署。
- Worker 的运行时 secret（`ADMIN_USER` / `ADMIN_PASS` / `EMAIL_PEPPER` / `RESEND_API_KEY`）已存在 Cloudflare
  上，`wrangler versions upload` 会沿用它们；这个 workflow 也不负责设置它们。

## API

签名（`[签名]`）规则见 `src/auth.js` 文件头；标「写」的请求另做防重放（同一签名串只收一次）。

| 方法 | 路径 | 鉴权 | 作用 |
|---|---|---|---|
| POST | `/v1/email/code` `{email, purpose: register\|login, lang?}` | — | 发 6 位验证码（永远 202，防探测；按 IP / 邮箱限流、扣 email 预算） |
| POST | `/v1/register` `{pubkey, nickname, email, code}` | 自签 | 注册（验证码 10 分钟有效、最多试 5 次、一次性；同钥匙重复注册幂等） |
| POST | `/v1/login` `{pubkey, email, code}` | 自签 | 新设备登录：把本机钥匙绑到该邮箱的账户（每账户 ≤ 10 台） |
| GET | `/v1/me` | 签名 | 自己的账户（含 `uploadDevice`、`shelfCount`） |
| GET | `/v1/me/devices` | 签名 | 已登录设备 `{devices:[{keyId, createdAt, lastUsedAt, current}]}` |
| POST | `/v1/me/devices` `{pubkey, time, proof}` | 签名·写 | 已登录设备代已互联配对的新设备绑定钥匙（新设备只交出公钥；`proof` = 新设备私钥对 `fushi-device-link\n<pubkey>\n<time>` 的签名，±5 分钟）。新绑 201、已在本账户 200（幂等）；满 10 台 409 `too_many_devices`、钥匙属于别的账户 409 `key_taken`；每账户每小时 ≤ 10 次 |
| DELETE | `/v1/me/devices/:keyId` | 签名·写 | 解绑另一台设备（不能解绑当前设备：400 `cannot_remove_current`；解绑上传设备会清空上传设备） |
| PATCH | `/v1/me` `{nickname?, visibility?}` | 签名·写 | 改资料 |
| DELETE | `/v1/me` | 签名·写 | 删除账户与全部数据 |
| PUT / DELETE | `/v1/me/avatar` | 签名·写 | 上传 / 删除头像 |
| POST | `/v1/shelf` `{reset?, claim?, put ≤500, remove ≤500, daily ≤400}` | 签名·写 | 增量上报书架 → `{works, shelfCount}`。同账户并发写 → 409 `conflict`（整批已回滚，重试即可）；每账户只有一台上传设备，别的设备 → 409 `upload_owned_by_other_device`，`reset + claim` 接管 |
| PUT | `/v1/works/:id/cover[?h=<dHash>]` | 签名·写 | 提交封面缩略图（投票）。带 `h`：命中相近候选只投票不存图，否则存图并投票；不带 `h`（旧客户端）：作品已有封面 409 `cover_exists` |
| POST | `/v1/works/:id/cover/vote` `{hash}` \| `{url}` | 签名·写 | 不带字节的封面投票；哈希没命中 409 `cover_bytes_required`，URL 不在白名单 400 `bad_cover_url` |
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
| POST | `/v1/ping` `{installId, version, platform, channel, locale?, arch?, osVersion?, source?}` | 可选安装证明 | 安装统计心跳 → 204。`installId` 小写 UUID v4 形状，`platform` ∈ android / windows / macos / linux（iOS 不发），`channel` ∈ stable / beta / debug；`AUTH_LIMITER` 限流，日预算 `ping`；服务端不存 IP。新客户端的 `installId` 由系统机器标识经 HMAC 派生成 P-256 钥匙、再取公钥指纹（重装不变，原始机器标识不上传），并带 `X-Fushi-Install-Key / -Time / -Sig / -Pow` 安装证明：id == 公钥指纹、签名覆盖方法 + 路径 + 时刻 + 请求体哈希（±5 分钟，签名串防重放）、工作量证明 18 位前导 0，都过了记已验证，带了但不对 401（`install_id_mismatch` / `bad_install_signature` / `stale_install_time` / `install_replayed` / `install_pow_required` / `bad_install_proof`）；不带证明（旧客户端）照收、记未验证。可选维度：`locale` App 界面语言（BCP 47）、`arch` 宿主 CPU 架构、`osVersion` 系统大版本、`source` 安装来源类别，只校验形状不校验取值表（形状不对 400 `bad_locale` / `bad_arch` / `bad_os_version` / `bad_source`）；国家 / 地区取 Cloudflare 的 `request.cf.country`（只存两位码，不存 IP / 城市 / ASN）。开发者处理台 `/dev/stats` 看日活 / 周活 / 月活、分国家日活趋势、留存（次日 / 第 7–13 天 / 第 30–59 天）、版本升级进度，以及平台 / 通道 / 版本 / 国家地区 / 界面语言 / 架构 / 系统版本 / 安装来源分布（只数已验证，未验证另列）。细节见 `src/installs.js` 文件头 |
| POST | `/v1/feedback` `{category, title, body, contact?, meta?, installId?}` | 可选签名 | 提交反馈 → 201 `{id, ticket}`（`installId` 同心跳，不合法当没带，处理台据此显示该安装的版本轨迹；可带同一套安装证明头，验过标「已验证」，带了但不对 401）（ticket 只返回这一次；带签名 = 关联账户）。每 IP 每小时 10 条，日预算 `feedback`；同来源同内容 1 小时内 409 `duplicate_feedback`；伪装字符剥掉、注入 / 链接 / 跨来源重复只打标记（`flags`，仅开发者可见） |
| PUT | `/v1/feedback/:id/attachments/:slot` | `X-Fushi-Ticket` | 补传附件：`s0`..`s2` 截图（PNG/JPEG/WebP ≤ 1.5 MiB）、`log`（gzip ≤ 2 MiB）、`v0` 视频（mp4 / mov / webm ≤ 50MB，必须带 `Content-Length`，缺 411、超限 413、类型不对 415 `unsupported_video_type` / `not_a_video`、实际长度不符 400 `bad_length`；流式写 R2）；提交后 24 小时内、每槽一次（重复 409 `slot_taken`）。只认 ticket（签名覆盖不了流式请求体） |
| POST | `/v1/feedback/status` `{items:[{id, ticket}] ≤ 50}` | — | 批量查进度（ticket 不对的条目不返回） |
| GET | `/v1/feedback/mine?cursor&limit` | 签名 | 本账户提交过的反馈（跨设备找回工单）→ `{items, next}`，摘要同 status，按创建时间倒序游标分页（limit 默认 30、上限 50） |
| GET | `/v1/feedback/:id` | ticket 或同账户签名 | 详情 + 处理时间线 |
| POST | `/v1/feedback/:id/messages` `{body}` | ticket 或同账户签名·写 | 反馈人追加说明（已结案会重新打开） |
| POST | `/v1/feedback/:id/close` | ticket 或同账户签名·写 | 反馈人标记完成（open / in_progress → closed） |
| GET | `/v1/feedback/:id/attachments/:slot` | ticket 或同账户签名 | 取回自己的截图（日志 / 视频不回传） |
| PUT / DELETE | `/v1/feedback/:id/push` `{token, lang?}` | `X-Fushi-Ticket` | 登记 / 注销本条反馈的 APNs 设备令牌（iOS 推送，见下「APNs 推送」）。每条 ≤ 5 个（满了挤掉最旧的），按令牌 SHA-256 去重；已结案 409 `feedback_closed`；单条反馈每小时 20 次 |
| GET | `/v1/dev/feedback?status&cursor&limit` | 签名·开发者 | 处理台列表（`status=active` = 未结案，`status=flagged` = 带风险标记） |
| GET | `/v1/dev/feedback/:id` | 签名·开发者 | 详情（含联系方式 / 设备信息 / 反馈人） |
| GET | `/v1/dev/feedback/:id/attachments/:slot[?view=text\|download=1]` | 签名·开发者 | 附件；日志 `view=text` 服务端流式解压；视频支持 `Range`（206），`download=1` 作附件下载 |
| POST | `/v1/dev/feedback/:id` `{status?, reply?}` | 签名·写·开发者 | 改状态 / 回复 |
| POST | `/v1/dev/feedback/:id/notes` `{aiSummary?, devNote?}` | 签名·写·开发者 | AI 总结 / 开发者批改（仅开发者可见，反馈人接口不返回；空白 = 清除）。本机 CLI：`node scripts/feedback.mjs`（list / show / summarize），见 `docs/specs/2026-10-08-feedback.md` |
| POST | `/v1/ci/feedback/fixed` `{sha, ids ≤ 50, scope: app\|none}` | Bearer `FEEDBACK_CI_TOKEN` | CI 标记修复 commit → `{updated, unchanged, missing}`（open / 处理中 → 已解决并记时间线；换了 sha 或 scope 会清空已发布记录，sha 与 scope 都没变的幂等跳过、进 `unchanged`）。没配 secret 时 `/v1/ci/**` 一律 404。手动兜底：`node scripts/feedback.mjs fixed <id> --sha <commit> [--no-app]` |
| GET | `/v1/ci/feedback/pending?channel&platform` | Bearer | 180 天内、需要新 App、该通道 / 平台还没回填的修复 `{items:[{id, sha}]}`（≤ 500） |
| POST | `/v1/ci/feedback/released` `{channel, platform, version, ids: [{id, sha}] ≤ 500}` | Bearer | 回填「哪个版本已包含修复」，只记首次 → `{updated}`；行的当前 `fix_sha` 与该条 `sha` 不同（其间被重新标记修复）的静默跳过。只写 `fixed_in`，不刷 `dev_reply_at` / `updated_at`（回填不是开发者回复，不影响红点、「新消息」与处理台排序）。反馈人 / 开发者接口的摘要带 `fix: {sha, scope, at, releases}` |
| GET/POST | `/dev/**` | 会话 Cookie | 开发者网页处理台（邮箱验证码登录，仅 role = dev；无脚本、POST 验 Origin）：`/dev` 反馈、`/dev/stats` 安装统计、`/dev/project` 项目数据（GitHub star / fork / 关注 / issue、App Release 各平台下载、官网 fushi.moe 每日页面浏览 / 访客 / 流量 / 国家；定时任务每 3 / 6 小时取一次存成每日快照画趋势，页面可「立即刷新」；细节见 `src/project_stats.js` 文件头） |

「ticket 或同账户签名」：带了非空 `X-Fushi-Ticket` 就只认 ticket；否则验 `X-Fushi-Account` 签名，反馈须是该账户提交的。
不存在 / 不是你的 / 匿名提交的 / 什么都没带一律 404（不区分）；匿名提交的反馈只能凭 ticket。

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
| GET | `/admin/api/email-conflicts` | 邮箱别名归一时没能惰性升级的账户对 `{count, rows: [{accountId, holderId, firstSeenAt, lastSeenAt, seenCount}]}`（同一收件箱在旧规则下注册过多个账户；不含邮箱） |
| POST | `/admin/api/accounts/:id` `{hidden}` | 隐藏 / 恢复账户 |
| POST | `/admin/api/works/:id` `{title?, author?, nsfw?, clearCover?}` | 改作品（改标题/作者即锁定） |
| POST | `/admin/api/snapshots/refresh` | 立刻重算榜单快照（部署后第一次、或不想等定时任务时） |
| POST | `/admin/api/accounts/:id/devices/clear` | 清空账户全部设备（用户设备名额满又没有一台还登录着时；之后用邮箱验证码重新登录） |
| POST | `/admin/api/works/merge` `{from, into}` | 合并误拆的作品 |
| POST | `/admin/api/works/split` `{ref}` | 拆出误挂的别名（`ref` 带 `kind|` 前缀） |
| POST | `/admin/api/accounts/:id/role` `{role: 'dev'\|'user'}` | 设 / 撤开发者（反馈处理台；撤销时网页会话一并作废） |

## APNs 推送（反馈有新回复）

开发者回复 / 改状态（App 处理台与网页处理台都走 `devUpdate`）写库之后，Worker 经 `ctx.waitUntil`
给反馈人登记过的 iOS 设备发 APNs 推送（`src/feedback_push.js`）：文案只有通用的「开发者回复了你的反馈 /
状态有更新」+ 反馈 id，**不带回复正文和标题**；推送失败只记日志，不影响回复写入。结案时（发完推送后）
与 APNs 回 410 / `BadDeviceToken` / `DeviceTokenNotForTopic` 时清掉令牌。Android（无 GMS）继续用 App
的后台检查，不接 FCM。

需要的 secrets（**缺任何一项 = 不发送、不报错，每个 isolate 只记一次日志**；令牌照常登记，配好后即生效）：

```bash
node services/leaderboard/node_modules/wrangler/bin/wrangler.js secret put APNS_KEY_P8 --config services/leaderboard/wrangler.toml     # .p8 全文
node services/leaderboard/node_modules/wrangler/bin/wrangler.js secret put APNS_KEY_ID --config services/leaderboard/wrangler.toml
node services/leaderboard/node_modules/wrangler/bin/wrangler.js secret put APNS_TEAM_ID --config services/leaderboard/wrangler.toml
node services/leaderboard/node_modules/wrangler/bin/wrangler.js secret put APNS_BUNDLE_ID --config services/leaderboard/wrangler.toml  # app.fushi.reader
node services/leaderboard/node_modules/wrangler/bin/wrangler.js secret put APNS_ENV --config services/leaderboard/wrangler.toml        # production | sandbox
```

Apple 侧怎么建 Auth Key、App ID 勾 Push、sandbox / production 怎么选，见
[`docs/agent/apple-signing.md`](../../docs/agent/apple-signing.md)「APNs 推送密钥」。迁移
`0010_feedback_push_tokens.sql` 要先于部署应用（规则同上）。

成本：登记扣 `write_rows`；每次处理最多 5 个出站请求（Workers Free 每请求子请求上限 50）；APNs 免费。
**未实测**：Workers 出站 `fetch` 与 APNs 的 HTTP/2 握手要等配好密钥后用真机验证一次（日志里看
`apns: push ... failed` 有没有出现）。

### Apple Music developer token

`GET /v1/musickit/token` → `{token, expiresAt}`（`src/musickit.js`）：用 secret `MUSICKIT_KEY_P8` /
`MUSICKIT_KEY_ID` / `MUSICKIT_TEAM_ID` 签 ES256 JWT，一天有效、同一 isolate 过半才重签；无账户，按 IP
过 `READ_LIMITER`，`no-store`。缺 secret 回 `503 musickit_not_configured`。密钥来历与 `secret put`
命令见 [`docs/agent/apple-signing.md`](../../docs/agent/apple-signing.md)「MusicKit 密钥」。

反馈系统（回执、附件、开发者处理、防投毒、清理策略）设计见
[`docs/specs/2026-10-08-feedback.md`](../../docs/specs/2026-10-08-feedback.md)。

## 作品封面按人数投票（迁移 0012 / 0014，`src/cover_votes.js`）

同一作品不同账户提交的封面是「候选」，一账户对一作品一票、改投即移票；作品封面 = 票数最多的候选
（平票取最早达到该票数的，再平取先提交的），`works.cover_key / cover_url` 是物化结果，读路径不变。
缩略图按 64 位 dHash 归并（汉明距离 ≤ 10 视为同一张图，只存一份）；**哈希由服务端从上传字节算**（`src/cover_hash.js`，
只做 JPEG 熵解码、按 DCT 系数直接算 9×8 格的亮度和，结果与引擎 `cover_hash.dart` 一致），客户端带的 `?h=` 只用来核对，差太多 400 `cover_hash_mismatch`，
封面只收 JPEG（否则 415 `cover_not_jpeg`）；白名单图床 URL 按 URL
相等归并，书架上报带 `coverUrl` 即投该 URL（不会冲掉已投的缩略图票）。零票且不是当前封面的候选
立即删除并归还 R2 配额。隐藏账户的票照记、不计数。

- **先迁移再部署**：`0012_cover_votes.sql` 建两张表并把存量封面回填成零票候选（不知道当初是谁传的）。
  回填的存量封面算「已有封面」，只有过了下面的替换门槛的候选才能取代它。
- 旧客户端：书架上报里的 `coverUrl` 照样计票；不带哈希的缩略图上传维持先到先得（已有封面 409），存下的候选同样带服务端哈希。
  新客户端（引擎 `leaderboard_sync.dart` 第 7 步）升级后会给每部作品补投一次（多数命中已有候选、不传字节）。
- 限流：投票接口每账户每小时 600 次（`coverVotePerHour`），带字节的上传仍按 `mediaUploadPerHour`。
- 服务端算哈希的代价：Workers Free 计划每请求 10 ms CPU，完整解码（旧实现用 `jpeg-js`）一张 ≈300px 缩略图
  在新起的 isolate 上首次调用约 14 ms，会报 1102。现在不做完整解码：只解 Huffman 熵编码，只记亮度分量；
  整块落在一个格子里的 8×8 块只用 DC（块像素和 = 64·128 + 8·F(0,0)），被格子边界 / 图像边缘切开的块按
  DCT 系数线性算每一片的像素和（不做 IDCT、不做色彩转换），色度块与其余 AC 系数只跳过。Node 本机实测
  ≈300px 缩略图冷调用 ≈ 3–5 ms、热态 ≈ 0.2–0.5 ms（**未在 workerd 上实测**）。支持 baseline / progressive
  （progressive 只解 DC 扫描）、4:4:4 / 4:2:2 / 4:2:0 / 灰度、DRI；算术编码 / 12 位 / CMYK 等拒绝（400
  `bad_cover_image`）。尺寸上限长边 320（`COVER_MAX_EDGE`）、0.1 MP（`COVER_DECODE_MAX_MP`），依据是两条生产上传路径都把封面缩到长边 ≤ 300
  （App `downsampleCardScreenshotAsync(maxLongEdge: 300)`、无头服务端 `encodeLeaderboardCoverThumb`），帧头声称超大尺寸在分配前就被拒；所有循环受
  输入字节数约束（每次 Huffman 解码至少消耗 1 个真实比特，截断即拒），另限表定义 ≤ 32 张、扫描 ≤ 64 个、被切开的块 ≤ 1600 个
  （防构造的扫描风暴 / 表风暴 / 细长图，样本在 `test/cover_vectors/adversarial/`）。先鉴权、先查「旧客户端且已有封面」再算哈希，
  架外的人和必然 409 的请求不耗 CPU。与 Dart 的对拍样本（`test/cover_vectors/`，两边测试读同一份）距离全为 0；
  与 jpeg-js 逐像素参照不同时只在两格亮度差 < 1 个灰度级的近似平局位上。`jpeg-js` 只剩测试里当参照（devDependency）。

### 替换门槛、冷却期与确认票（迁移 0014）

动机：dHash 只是感知哈希，审查实测知道公开的正版封面就能「老实地」造出服务端哈希距离很近、显示却是
另一张图的 JPEG，服务端解码挡不住。攻击方式是**收割票**：抢先用伪造图建候选，之后持正版封面的用户按哈希投票
全会投到他的图上。所以在投票侧加固：

- **替换门槛**：作品已有封面（含回填的存量封面）时，挑战者要取代它必须 ① 确认票 ≥ `COVER_REPLACE_MIN_CONFIRMED`
  （3）个不同的未隐藏账户，且这些账户**注册早于该候选创建**（不能建完候选再现注册小号凑票）；② 候选创建满
  `COVER_REPLACE_COOLDOWN_MS`（24 小时）；③ 比现封面强：现封面自己的确认票也 ≥ 门槛时比总票数（严格多于，平票留任），
  否则比确认票（挑战者确认票严格多于现封面确认票）。后一种是防「入场票收割」：伪造图若抢到首张封面，旧客户端按哈希
  投的未确认票会被它收割、把总票数撑高，正版靠确认票永远追不上总票数。
- **防护边界（如实）**：confirm 是客户端自报的，服务端验证不了比对真的做过。所以门槛的实质是「3 个注册早于候选的账户
  + 24 小时公示期 + 管理员可见的不符计数」；本机强比对防的是**诚实客户端被收割**去给伪造图投票，**不防一人多号**
  （几个号各自 confirm 就够）。剩下的靠冷却期里管理员看 `/covers` 的不符计数、清封面 / 隐藏账户反制。
- **确认票**：投票者手里确实有这张图——上传字节建出该候选的人、URL 票（URL 相等）、以及新客户端按哈希命中后
  **在本机**下载候选缩略图与本地封面强比对通过（`fushi_engine` `leaderboard/cover_compare.dart`：32×32 灰度 NCC +
  去掉 9×8 粗格均值后的细节 NCC）。比对放在投票者设备上：CPU 在用户端，而且只有他有正版原图。比对不通过记一条
  「不符」（`cover_mismatches`）：撤掉他投给该候选的票，之后对他跳过这个候选（于是他命中下一个候选或上传自己的图）。
  不符只是管理员信号，不影响排名、不阻止替换（否则几个小号刷「不符」就能把正版钉死）。
- **旧客户端**（只会按哈希投票、不比对）的票是未确认票：照常决定首张封面、现封面留任与候选排序，但**不计入替换门槛**。
  存量 URL 票迁移时直接记为确认票；存量缩略图票分不清来源，一律未确认（新客户端会对已投的作品补一次本机比对）。
- **没有封面的作品**首张不受门槛约束、立即生效（否则冷门作品永远没封面）。例外：**管理员清过封面**的作品
  （`works.cover_cleared_at`）在 `COVER_CLEAR_GUARD_MS`（30 天）内按「已有封面、现封面 0 票」处理——清封面多半是因为
  有人在抢，不能让攻击者在清掉的瞬间再抢回首张。保护期过后，该作品下一次投票时恢复「有票即生效」。
- **冷却到期的生效路径**：期间有任何投票，投票事务本身就会重新物化；没有新票时由定时任务（`*/30`）的
  `settlePendingCovers` 处理：按部分索引 `idx_cover_candidates_pending`（`created_at WHERE votes >= 3`）只读窗口内
  总票数达标的候选，每轮最多 50 部作品，回看 7 天（容忍定时任务停摆；更久的靠下一次投票）。
- 投票接口：`POST /v1/works/:id/cover/vote` 的 `{hash}` 可再带 `check: true`（只返回命中的候选 `{id, image}`、不投票）、
  `confirm: <cid>`（确认票）或 `mismatch: <cid>`（记不符并返回下一个候选 / 409 `cover_bytes_required`）；
  `PUT /v1/works/:id/cover` 命中已有候选时响应带 `candidate` 供客户端比对。缩略图走公开的 `/img/<key>`（边缘缓存）。
  `check` 只按 4 行扣全局写入预算（防重放 + 限流记录），其余投票仍按 16 行；新客户端每部作品多一次 `check` 请求，
  同受 `coverVotePerHour` 限流（超了 429，客户端本轮停下、下次续）。
- 客户端比对的阈值标定（`packages/fushi_engine/test/leaderboard/cover_compare_test.dart`，样本含审查给的伪造图）：
  同图各种重编码 / 缩放 / 调色 / 小裁切 NCC ≥ 0.991、细节 NCC ≥ 0.862；老实伪造 NCC 最高 0.930、细节 ≤ 0.221；
  夹断藏质量的伪造 Dart 解码器直接解不开（按不符处理）。阈值取 NCC ≥ 0.95 且细节 ≥ 0.70。
- 上线顺序：先迁移（0014，Actions 部署自动先做）再部署 Worker，再发新客户端。新客户端遇到旧 Worker（响应里没有 `confirmed`）
  会退化为旧的按哈希投票，每轮同步只为补确认试一次。
- 处理台：`GET /admin/api/works/:id/covers` 列出候选的票数、确认票、不符数与状态（`current` / `eligible` /
  `cooldown`（带 `eligibleAt`）/ `needs_votes` / `first`）。
