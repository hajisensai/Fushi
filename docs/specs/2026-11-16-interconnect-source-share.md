# 互联来源共享与插件中继（2026-11-16）

拍板台 `wOMR4_Er7s`（维护者自提）：已安装的插件和云端来源应自动通过 Fushi 互联共享，部分共享账密、
部分经 Fushi 中继，iOS 也可接收。维护者 2026-11-16 拍「a、b」并留言「可以放行」（iOS 审核风险接受）。

- **a 共享账密 / 配置**：本文 §1～§4，PR `dec/interconnect-source-share`。
- **b 经 Fushi 中继**：本文 §5，单独一个 PR（`dec/interconnect-plugin-relay`）。

## 1. 共享什么

| 种类（wire `kind`） | 本机存放 | 共享内容 |
|---|---|---|
| `opds` | 偏好 `discovery_opds_servers` | 一条服务器配置（含 base64 密码 / API key） |
| `alist` | 偏好 `discovery_alist_sites` | 同上 |
| `kavita` | 偏好 `kavita_servers` | 同上 |
| `subsonic` | 偏好 `music_subsonic_servers` | 同上 |
| `mediaServer` | 偏好 `sync_jellyfin_servers`（Jellyfin / Emby / Plex，冻结名） | 同上；`activeServerUrl`（这台设备走哪条线路）不出境、不进摘要，更新时保留本机值 |
| `musicPlugin` | `<数据库目录>/music_plugins/<id>/` | 安装包（已装目录原样打回 `.fushiplug`）；插件存储与凭据保险库在包目录外，不出境 |
| `trackingPlugin` | `<数据库目录>/tracking_plugins/<id>/` | 同上；随 app 自带的 Bangumi（内置）与 AniList / MangaBaka（预装）两端都不碰 |

登记表只有一处：`fushi/lib/src/sync/interconnect_source_share_kinds.dart`。

**刻意不在内**：Audiobookshelf（refresh token 会轮换，两台设备共用一枚会互相挤下线，留给中继）；SFTP / FTP
网络来源库（Drift 行 + 本机扫描索引，不是一条可移植配置）；云同步后端自己的凭据（`sync_*`，设备本地）；
插件的登录凭据（每台设备各自登录，换签名者时宿主还会清空它）。

## 2. 传输与门

- 引擎：`packages/fushi_engine/lib/sync/interconnect_source_share.dart`（wire 形状、`InterconnectSourceShareHost`
  接口、配置摘要 = 键排序规范 JSON 的 sha256），路由 `fushi_sync_server/source_share.part.dart`：
  - `GET /api/interconnect/source-share` → 目录；
  - `GET /api/interconnect/source-share/package?kind=&id=` → 插件包 zip（上限 16 MiB）。
- 门（缺一不可，按顺序）：未装配 404 → 明文 403 `https_required` → 非 per-peer token 403 `paired_peer_required` →
  host 开关关 403 `disabled` → 不是 host 主人标过「我的设备」的 peer 403 `not_owner_device`。
  「我的设备」与「跟随已配对设备自动登录」共用同一个判据（配对审批时选「这是我的设备」或之后手动标记），
  这就是「凭据由用户逐设备授权」：只配对、没标「我的设备」的设备拿不到任何账密。
- client 遇 404 / 明文 / `disabled` / `not_owner_device` 一律当「对端此刻不给」，不计同步失败（BUG-1311 同理）。
- 能力位：`/api/capabilities` 的 features 里 `sourceShare`（TLS 且装配了才 true）。
- 无头服务端不装配（`docs/agent/server-parity-gaps.md`）。

## 3. 合并规则（自动，`interconnect_source_share_sync.dart` 的 `planSourceShare`）

每轮互联同步在 service-config 之后跑一次。设备本地账本 `interconnect_source_share_ledger` 记
「从哪台 host（hostId）收下了哪条、收下时的摘要」：

| host 目录 | 本机 | 账本 | 结果 |
|---|---|---|---|
| 有 | 没有 | 没有 | 新增，记账 |
| 有 | 没有 | 有 | 用户在本机删了：记「不再接收」，以后不再加回来（这就是逐条退订） |
| 有 | 有、摘要 = host | 没有 | 认领 |
| 有 | 有、摘要 ≠ host | 没有 | 本机自己的那份，不动 |
| 有、摘要变了 | 有、摘要 = 账本 | 有 | 跟随 host 更新 |
| 有 | 有、摘要 ≠ 账本 | 有 | 用户在本机改过：脱离跟随，不再覆盖 |
| 没有 | 有、摘要 = 账本 | 有 | host 删了 / 不再共享：本机跟着删（卸载传播） |
| 没有 | 摘要 ≠ 账本或已删 | 有 | 销账 |

- 插件更新前核对签名者：变了（含有签名 ↔ 无签名）不自动装，手动同步摘要里列出插件名，要用户在本机自己装
  （换签名者 = 换了发布者，宿主会清掉插件的登录凭据与存储，不能替用户决定）。
- 插件包装前照常 inspect：摘要必须等于 host 目录里的那份（host 上用户确认安装的就是它），否则不装、
  记一条错误、下一轮重试。新插件自动装不再弹确认框：同一个包、同一个摘要，用户已在 host 上确认过。
- 失败的一步不记账，下一轮按同一规则重试；一轮里单条失败不中断其余条目。
- 本机没有某插件体系（iOS、原生库不带插件运行时）时这一类整类跳过，账本原样保留；iOS 用 §5 的中继。

## 4. 开关（都是设备本地键，默认开）

- client「接收共享来源」`interconnect_sync_source_share`：设置 › 互联（作为客户端那一节），关掉连请求都不发，
  已收下的不回滚。
- host「把来源共享给我的设备」`interconnect_source_share_host`：设置 › 互联（作为主机那一节），每个请求现读。

为什么默认开：维护者要的是「自动共享」；凭据只发给主人显式标过「我的设备」的已配对设备，
走 HTTPS + per-peer token（端到端：只在这两台设备之间，不经任何第三方）。

## 5. 中继（方案 b）

见 PR `dec/interconnect-plugin-relay`：没有插件运行时的设备（iOS）经互联让 host 代跑音乐 / 歌词插件
（搜索、详情、取流、歌词），媒体字节也经 host 转发，iOS 端不执行第三方代码、不直连第三方平台。
合规判据仍只在 `store_compliance.dart`：维护者 2026-11-16「可以放行」后，iOS 上「经互联中继用对端插件」
是一条独立的能力判据，不改 `onlineMusicSource`（iOS 依然不装插件宿主、不编入 JS 引擎）。
