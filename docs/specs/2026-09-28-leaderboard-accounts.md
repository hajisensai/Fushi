# 排行榜 + Fushi 账户（设计与分期计划）

状态：**已确认**（2026-09-28），按 P1→P6 逐期实施，每期一个 PR。

## 0. 用户已拍板的决定（2026-09-28）

| 问题 | 决定 |
|---|---|
| 后端 | 新建独立 Cloudflare Worker + D1（与 `logs.wrds.xyz` 日志服务完全隔离） |
| 账户 | ~~昵称 + 设备密钥：无邮箱、无密码~~ → 已被「追加 4」推翻：邮箱验证码注册 + 设备密钥（服务端只存邮箱 HMAC） |
| 排名指标 | 书 / 视频 / 游戏 / 漫画的**作品数量**，以及**字数** |
| 第一期范围 | 周/月/总榜 + 个人主页 + **好友榜 + 分享卡片** |
| 追加 1 | 榜单/主页显示对应书/视频/游戏的**作品名与封面** |
| 追加 2 | 萌メーター式**用户详情页**：读完的作品、作者、读完时间、多少人读过、谁读过 |
| 书匹配 | **两者都做**：导入时解析 EPUB ISBN（新列）+ 标题/作者归一化 + 举报纠正 |
| 可见性 | **默认公开**；只有注册（生成账户）后才会上传 |
| iOS | 与其他平台**一样全开放**（合规项照做，不加 StoreRestrictedCapability） |
| 推进 | ~~P1→P6 逐期~~ → 用户改为「全部做完」：P2–P6 叠在同一分支，统一在 PR #1745 审查 |
| 防计费（追加 3） | 「做点基础限流，别让我 CF 计费」→ 见第 11 节：Workers Free 计划 + 服务端全局日预算 / R2 配额 + 增量上报 + 榜单快照 |
| 邮箱（追加 4） | 「注册要发邮件和验证码」→ 推翻「无邮箱」：邮箱验证码注册，新设备用邮箱验证码登录（绑定新钥匙）；服务端只存邮箱 HMAC；发信用 Resend 免费档 |

## 1. 现状（调研事实）

- 统计域唯一事实表 `study_segments`，唯一读取口 `loadStatFacts`（`packages/fushi_engine/lib/stats/stat_facts.dart:310`）。
  `StatFact` 字段：`mediaKind`（book/video/game）/ `mediaKey` / `title` / `format`（epub/pdf/manga）/ `dateKey` / `ms` / `chars` / `pages`。
  **漫画不是独立 mediaKind**，是 `book` + `format == manga`（`StatFact.isManga`）。
- 统计中心 `statistics_center_page.dart:81-92` 有 4 个 tab：总览 / 阅读 / 视频 / 游戏。统计按 Profile 隔离（v105）。
- 仓库里**没有任何 Fushi 自有账户**；唯一的自有线上服务是日志 Worker，它的上传 token 已烤进入库客户端代码（实际公开），不能复用其鉴权。
- 可用依赖：`pointycastle`（ECDSA P-256）、`crypto`、`share_plus`。不新增依赖。

## 2. 核心判断（2026-09-28 用户追加需求后改写）

用户追加：榜单与主页要显示**作品名与封面**；用户详情页要像萌メーター/読書メーター那样列出**读完的作品、作者、读完时间、有多少人读过、谁读过（头像墙）**。

这推翻了初稿的「不上传标题、每账户盐不透明哈希」模型：现在作品元数据是**公开分享的内容**，且同一作品必须**跨用户对上**。因此数据模型改为「公开书架」。✅ 值得做；硬风险从「泄露标题」变为：

1. **跨用户作品匹配**：书没有 ISBN、没有系列，只能标题+作者归一化 → 会有漏配/误配，必须可人工纠正。
2. **刷榜**：客户端上报不可验证（结构性事实），只能上限 + 限流 + 举报/隐藏。
3. **UGC 与版权**：昵称/头像/上传的封面缩略图都是 UGC；galgame 封面可能是 R18。

## 3. 数据结构（先定这个，其它都是它的派生）

### 3.1 身份

> **2026-09-28 更新**：注册改为邮箱验证码（见第 12 节）。下面「钥匙 = 账户」改为「钥匙 = 设备凭据，一个账户可绑多把」；私钥存本机文件 `<support>/leaderboard/profile_<id>.json`（不进偏好表 / 备份）。

- 首次开启时为**当前 Profile** 生成 ECDSA P-256 密钥对（`pointycastle`，不新增依赖）。**账户 = 公钥**，`account_id = base64url(sha256(pubkey))[0..16]`，同时是**好友码**。
- 昵称 1–24 字符可改，展示 `昵称#1234`（服务端分配判别码）；可选头像（客户端裁成 128px JPEG 上传 R2）。
- 私钥存本机文件 `<support>/leaderboard/profile_<id>.json`（**不进偏好表**——偏好会随 Profile 快照与备份外传；Android 系统备份规则也排除该目录）。换设备：邮箱验证码登录绑定新钥匙（每账户 ≤ 10 台，可在账户页解绑旧设备）；恢复码（私钥 base64url + 校验）保留作备用。
- 请求签名：`X-Fushi-Account` / `X-Fushi-Time` / `X-Fushi-Sig`；签名串 = `METHOD\npathWithQuery\ntime\nhex(sha256(body))`，ECDSA/SHA-256，P1363（r‖s）base64url。服务端校验签名、±5 分钟；写请求另按**签名串哈希**去重（`used_sigs`）防重放——不用签名值去重（ECDSA 可延展），也不要求时刻单调（客户端并发写会乱序到达）。跨语言测试向量在 `services/leaderboard/test/vectors/`。

### 3.2 唯一上传形状：书架条目

```
ShelfEntry {
  kind: 'book'|'manga'|'video'|'game',
  work: WorkRef,            // 跨用户匹配键，见 3.3
  title, author,            // 书=EpubBooks.author；游戏=developer；视频=空或制作方
  coverUrl?,                // 有公开远端 URL 就只传 URL（TMDB/bgm/VNDB/在线漫画）
  coverThumb?,              // 只有本地封面（EPUB/本地漫画）才传 ≤300px JPEG，按 work 去重，服务端已有则跳过
  finishedAt?,              // 读完时刻；null = 在读
  chars, ms                 // 该作品累计字数/时长（来自 loadStatFacts 按 mediaKey 汇总）
}
```

- 读完时刻来源：书/漫画/PDF `EpubBooks.completedAt`；视频 `VideoBooks.completedAt`（合集取成员最晚完成，全部完成才算）；**游戏新增 `Galgames.completedAt`**（见 3.5）。
- Profile 口径：本机只有一个 Profile 时上传全部读完 / 在读的作品；有多个 Profile 时**别的 Profile 有学习记录、当前 Profile 没有**的作品不上传；哪个 Profile 都没有记录的作品照常上传（BUG-2870，`buildLocalShelf` 判定）。
  - 作品维度去重（BUG-2870）：同机 Profile 共享一个库，「哪个 Profile 都没有记录」的作品会被每个开了上传的 Profile 各报一次。这类作品只由**同机代表 Profile**（开着上传、未被别的设备顶掉的 Profile 里 id 最小的，`leaderboardUnattributedOwner`）计入作品读者数；其余 Profile 上传时带 `counted: false`。`counted: false` 的行照常上架、照常计入该账户自己的读完数与计分，只不计入作品读者数 / 作品人气 / 作品周月榜 / 作品页读者列表（服务端 `shelf.counted` 列，迁移 `0002_shelf_counted.sql`）。有学习记录的作品归记录所在 Profile，照常计入——同一本书换个 Profile 再读完一遍不去重。`counted` 只在为 false 时进上报 JSON，已有条目的内容哈希不变、不触发重传。
- 另上传按天字数汇总 `DailyChars { dateKey, chars }` 用于字数榜的周/月切窗（不带作品）。
- 上报是**幂等 upsert**：同一 `(account, work)` 覆盖；每次整份重传书架（有变更才传，按内容 hash 判），无增量游标。
- 每个条目本地可设「不公开」，被排除的作品从不上传，已上传的会被删除。

### 3.3 跨用户作品身份 WorkRef（按优先级取第一个存在的）

| 优先级 | 键 | 来源 |
|---|---|---|
| 1 | `bgm:<subjectId>` | `MediaTrackingMappings.subjectId` / `GalgameSources(bgm)` / `VideoScrapeMeta(bangumi)` |
| 2 | `vndb:v<id>` / `tmdb:tv|movie:<id>` / `anidb:<aid>` | `GalgameSources` / `VideoMetadataProviderIdentities` / `AnidbFileIdentities` |
| 1.5 | `isbn:<13位>` | `EpubBooks.isbn`（新列，导入时解析 OPF `dc:identifier`，ISBN-10 统一转 13） |
| 3 | `src:<pluginId>:<key>` | 在线漫画/小说 `sourceMetadata` |
| 4 | `t:<norm(title)>\|<norm(author)>` | 归一化：NFKC、去空白/括号内文库名、全角半角统一、小写 |

服务端 `works` 表以 WorkRef 为主键；同一作品有多个键时由**别名表**合并（客户端上传全部可得键，服务端发现任一键已存在即归入同一 work）。展示元数据取「最多用户一致的标题/作者 + 首个可用封面」。误配靠举报+管理端手动拆分/合并。

### 3.4 派生指标（服务端 SQL）

| 指标 | 定义 |
|---|---|
| 书 / 漫画 / 视频 / 游戏 数量 | 窗口内 `finishedAt` 落在窗口的条目数（按 kind）；总榜 = 全部读完数 |
| 字数 | 窗口内 `sum(DailyChars.chars)` |
| 作品人气 | 窗口内读完该 work 的不同账户数（「読書ランキング」对应物） |

### 3.5 本地 schema 变更（v115，两列）

- `EpubBooks.isbn`（text 可空，统一存 ISBN-13，校验位不对不存；规范化唯一口径 `fushi_engine/epub/isbn.dart` 的 `normalizeIsbn13`）：新导入时由 `EpubParser` 解析 OPF `dc:identifier` 写入；存量书在排行首次开启时调 `backfillEpubIsbns(db)` 后台重扫 OPF 回填（只读 OPF，不重新导入）。
- `Galgames.completedAt`（int 毫秒，可空），schema v113→v115（判据只在 DB 层 `resolveGalgameCompletedAt` 一处，经 `setGalgamePlayStatus` / `upsertGalgame` 写入；离开「玩过」清空）：`playStatus` 变为 2（玩过）时写入；迁移回填 = 该游戏 `galgame_sessions` 最后一次会话结束时刻，没有会话则留空（展示「日期未知」，不计入周/月榜，计入总榜）。

### 3.6 D1 / R2

```
accounts(id PK, pubkey, nickname, discriminator, avatar_key, created_at, last_seen_time, hidden, visibility 'public'|'friends')
works(id PK, kind, title, author, cover_url, cover_key, created_at)
work_aliases(ref PK, work_id)
shelf(account_id, work_id, finished_at, chars, ms, updated_at, PRIMARY KEY(account_id, work_id))
daily_chars(account_id, date_key, chars, PRIMARY KEY(account_id, date_key))
friends(a, b, state, created_at, PRIMARY KEY(a,b))
blocks(account_id, blocked_id, PRIMARY KEY(...))
reports(reporter, target_kind 'account'|'work', target_id, reason, created_at)
```
R2 桶 `fushi-leaderboard-media`：`avatars/<account>.jpg`、`covers/<work>.jpg`，经 Worker `/img/...` 出图（带缓存头）。

## 4. 防刷与滥用

- 上限：单日 `chars` 夹到 400,000；同一天读完**最多计 30 部**（不拒收，批量补标历史作品照常入架，只是不刷分；日期未知的各自成组）；`finishedAt` 不得晚于服务器时间 +5 分钟，`finishedDate` 必须与它的 UTC 日期相差一天以内。
- 作品匹配防抢注：每条目每命名空间至多一个键；已有强 ID（bgm/isbn/vndb/tmdb/anidb/src）的作品不再挂同命名空间的新键。标题/作者众数只计未隐藏账户。
- 限流：注册按 IP 5/小时；书架上传按账户 40 次/小时（首次同步 8000 条 = 16 批；客户端常态 ≤ 1 次/30 分钟）；头像/封面 60 次/小时；书架 ≤ 8,000 条（D1 单参数约 2MB 的硬约束）；读接口：匿名请求边缘缓存 60 秒 + 可选 CF Rate Limiting binding `READ_LIMITER`，offset ≤ 10,000。
- 举报 + 管理员隐藏账户 / 隐藏或拆分作品（不删数据）；管理端 Basic Auth 小页面。
- 昵称：长度/字符白名单 + 敏感词表。头像与上传封面可被举报后下架。

## 5. 页面（全部在 App 内；另有只读网页版）

- **排行榜**（原为统计中心 tab「排行」；2026-10-01 改为首页统计中心入口旁的独立按钮 + 独立页 `LeaderboardPage`）：全局/好友 × 周/月/总 × {书, 漫画, 视频, 游戏, 字数}；每行：名次、头像、昵称、数值。另一个子页「作品人气」：名次、封面、标题、作者、读者数、读者头像墙。
- **用户详情页**（萌メーター形态）：左侧卡片 = 头像、昵称、各类读完数（及名次）、字数（及名次）、注册日、首条记录日；右侧 = 按读完时间倒序的书架：封面、标题、作者、读完日期、「N 人」、读过此作品的其他用户头像墙（好友优先，最多 8 个）。点作品 → **作品页**：封面、标题、作者、读者数、读者列表（头像/昵称/读完日期）。
- **好友**：输入好友码申请 → 对方接受；删除、屏蔽；可见性 `friends` 时书架只对好友可见（仍计入数量榜，但榜上点进去看不到书架）。
- **分享卡片**：客户端渲染「本月读完 N 部 + 封面拼图 + 字数」PNG（`RepaintBoundary`，本地生成），附 `https://<域名>/u/<id>` 链接，经 `share_plus` 分享。
- **网页版**：Worker 直接渲染 `/u/<id>`、`/w/<workId>`、`/rank` 三个只读 HTML 页面，让分享链接在没装 App 的人那里也能打开。

## 6. 客户端落点

- 纯 Dart 协议 / 签名 / WorkRef 解析 / 书架汇总：`packages/fushi_engine/lib/leaderboard/`（纯度守卫：不 import Flutter）。
- UI 与装配：`fushi/lib/src/leaderboard/` + `pages/implementations/statistics/`；统计中心新增 tab。
- 设置 →「排行与账户」：昵称、头像、好友码、好友管理、可见性、不公开作品清单、导出/导入恢复码、上传开关、**删除账户（服务端全删，含 R2 文件）**。
- 同意弹窗：首次开启明确列出「会公开：昵称、头像、读完作品的标题/作者/封面/读完时间、字数」「不会上传：阅读位置、查词/制卡、文件路径、设备信息」，偏好 `leaderboard_consent`。
- 上传时机：统计中心打开 / 读完一部作品后 / 启动空闲，最多 10 分钟一次；失败记日志，下次整份重传（幂等，无重试循环）。
- 默认关闭：不开启的用户零网络请求。
- i18n 一律 `i18n_sync.dart --add`。

## 7. 平台合规（必须同时做，不是可选）

- **App Store 5.1.1(v)**：有账户注册就必须能在 App 内删除账户 → 已含「删除账户」。
- **App Store 1.2（UGC）**：昵称属于用户生成内容 → 必须有举报、屏蔽、过滤 → 已含。
- **R18 封面**：galgame（及部分书）封面可能是成人内容。Worker 对 VNDB 给出 `image.sexual ≥ 1` 的作品、以及用户举报的封面，统一以模糊占位展示，全平台同一规则（可点开查看）。
- 封面缩略图版权：只存 ≤300px 缩略图作识别用途（与読書メーター等同类服务一致），权利人投诉可按作品下架。
- 用户拍板 iOS 全开放：不加 `StoreRestrictedCapability`。残余风险 = 审核员仍可能以 UGC/成人封面为由拒审，届时再议。

## 8. 分期（每期可独立合并、独立验证）

| 期 | 内容 | 验证 |
|---|---|---|
| P1 | `services/leaderboard/` Worker + D1 + R2：签名校验、注册/资料/头像、书架 upsert、WorkRef 别名合并、各榜 SQL、删除账户 | vitest：签名/重放/上限/幂等/别名合并/窗口 |
| P2 | 引擎：密钥与恢复码、请求签名、WorkRef 解析、书架汇总；v115（`EpubBooks.isbn` + `Galgames.completedAt`；develop 当时已是 v113）+ ISBN 解析 | Dart 单测 + 跨语言签名测试向量；迁移测试 |
| P3 | 统计中心「排行」tab、同意弹窗、设置段、上传调度 | widget 测试；真机开页截图 |
| P4 | 用户详情页、作品页、作品人气榜 | widget 测试 |
| P5 | 好友 / 屏蔽 / 可见性 / 举报 | Worker + widget 测试 |
| P6 | 分享卡片 + Worker 只读网页 `/u` `/w` `/rank` | widget 测试 + Worker 渲染测试 |

## 9. 需要你来做的事（我做不了）

- 在 Cloudflare 上 `wrangler d1 create fushi-leaderboard`、`wrangler r2 bucket create fushi-leaderboard-media`、`wrangler deploy`，并决定域名（建议 `rank.fushi.moe`）。我会把 `wrangler.toml` 写好、database_id 留占位，客户端的服务地址做成一个常量。
- 设置管理端 Basic Auth 的 secret。

## 10. 破坏性分析

- 本地 schema 变更只有 v115 的两个可空列 `EpubBooks.isbn` / `Galgames.completedAt`（+ 回填；游戏的回填值是**最后一次游玩会话的结束时刻**，不是真实通关时刻），其余新增全在 D1/R2；密钥在本机文件（见 3.1）。
- 统计中心加 tab：tab 索引若被持久化/测试钉死需一起更新（P3 开工先查）。
- 默认关闭：不开启排行的用户零网络请求、零行为变化。

## 11. 成本控制（2026-09-28 追加）

用户要求「别让我 CF 计费」。P1 初版在规模上会烧钱（整份替换一次写 8000+ 行；榜单每请求全表扫描；图片走会扣费的 R2），改为：

- **部署在 Workers Free 计划**：超额只报错不扣费——这是最硬的保证，写进 README 与 wrangler.toml 注释。
- **有界读写**：书架增量上报（每批 ≤ 500）；作品读者数 `works.readers`、账户书架行数 `accounts.shelf_count`、每日计分 `stat_days`、总计 `account_totals` 全部增量维护；榜单 / 人气 / 名次读定时快照（每 30 分钟，`rank_snapshots` / `popular_snapshots`）+ isolate 内 60 秒内存缓存；读者墙每作品沿索引取前 8；分页 offset 有上限。
- **全局日预算熔断**（`budgets` 表）：write_rows 8 万 / media 3000 / register 2000 / email 90，超了 503、次日恢复；每账户每天 2 万行；R2 总配额 8 GiB（`media_usage`）。
- **限流**：READ_LIMITER（每 IP 每分钟 120 次，不占 D1）；上传 40 次/小时；媒体 60 次/小时；社交写 120 次/小时；发码按 IP / 邮箱。
- **代价**：超大书架首次同步要分两三天续传；榜单最多滞后 30 分钟。
- 正确性由对拍测试兜底：任意增量操作序列后，增量计数 == 从零精确重算。

## 12. 邮箱验证码（2026-09-28 追加）

- `POST /v1/email/code {email, purpose, lang}` → 永远 202（防探测：登录用途且邮箱无账户时不发信）；6 位均匀随机码，只存 HMAC，10 分钟过期，原子地最多试 5 次，一次性。
- `POST /v1/register {pubkey, nickname, email, code}`：验证码通过才建账户；同一邮箱只能注册一个账户（409 email_taken）。
- `POST /v1/login {pubkey, email, code}`：新设备把本机钥匙绑到已有账户（≤ 10 台）。请求头 `X-Fushi-Account` 是**设备钥匙 id**，账户 id 以服务端返回为准。
- 服务端只存 `HMAC(EMAIL_PEPPER, 规范化邮箱)`；发信 Resend（免费 100 封/天），缺配置 fail-closed 503。
- 需要维护者：注册 Resend、验证发件域名、设置 `EMAIL_PEPPER` / `RESEND_API_KEY` / `EMAIL_FROM`。
