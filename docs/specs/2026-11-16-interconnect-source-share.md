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

没有插件运行时的设备（iOS）经互联让 host 代跑音乐 / 歌词插件（搜索、首页、详情、取流、歌词、喜欢 /
歌单编辑），媒体字节也经 host 转发：iOS 端不执行第三方代码，也不连插件的平台去取流。

- **合规**：判据只在 `store_compliance.dart` 写一次——`interconnectPluginRelayAvailableOn` 恒 true（维护者
  2026-11-16「可以放行」）。`onlineMusicSource` 不动：iOS 依然不装插件宿主、不编入 JS 引擎、没有插件管理 /
  安装入口。`music_plugin_gate.dart` 分两道门：`isMusicPluginSourcesAvailable`（本机自己跑：安装、管理、
  共享包、替别人中继）与 `isMusicPluginSourcesUsable`（本机能用：来源列表、取流、歌词、喜欢、音质设置）。
- **插件侧**：`MusicPluginSource` 只认 `MusicPluginRuntime`（本机 `MusicPluginInstance` 或中继实例），类型化
  解析只写一次；`MusicPluginManager.relay` 非空时 `list()` 带上中继插件（`relayedVia` = 代跑设备名，本机已装的
  同 id 优先），`listInstalled()` 只列本机装的（管理页、来源共享打包用）。
- **wire**（`packages/fushi_engine/lib/sync/interconnect_plugin_relay.dart`，路由
  `fushi_sync_server/plugin_relay.part.dart`，能力位 `pluginRelay`）：
  - `GET /api/interconnect/plugin-relay` → host 上已装、启用的音乐插件清单（去掉 `login`）；
  - `POST …/invoke {plugin, method, args}` → 插件原始返回值；`login` 与清单没声明的能力拒绝；
  - `POST …/covers {plugin, urls}` → host 实例核对过的封面地址；
  - `POST …/media {plugin, url, headers}` → host 实例解析（授权、请求头白名单、逐跳重定向核对）后签一张流票，
    回 `…/stream/<票>`；
  - `GET|HEAD …/stream/<票>`：免 Basic（播放器带不了 Authorization），门是 32 字节随机流票 + 每次取流现查签发
    凭据（仍是已配对的「我的设备」、host 开关开着）。host 连接只连核对过的 IP，上游再重定向不跟，只转发
    `content-type / length / range`、`accept-ranges`、`etag`、`last-modified`，平台 Set-Cookie 不出 host。
- **门**：与 §2 相同（HTTPS → per-peer token → host 开关「把来源共享给我的设备」→「我的设备」），开关也复用
  §4 的两个：client「接收共享来源」关着时一个中继请求都不发。
- **为什么登录不经中继**：登录是在 host 那台设备上给插件授权（凭据进 host 的保险库），另一台设备既看不到
  登录页地址的核对结果，也不该替 host 主人登录 / 退出。账号状态（`account`）、喜欢、歌单编辑照常代跑，用的
  是 host 上那份登录。
- **选哪台 host**：配对表里靠前的那台；目录按 2 分钟缓存，host 说某插件已不可用时立即重拉。
- 本机能跑插件的设备不走中继（插件包由 §3 装到本机）；本机已装的同 id 插件也优先于中继。
