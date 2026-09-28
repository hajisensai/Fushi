# Anki 待发制卡队列、落地设备与 AnkiWeb / 自建服务器同步

日期：2026-09-28 · 状态：第 1 期实施中

## 目标

让卡片进入用户的 Anki（AnkiWeb 或用户自建的 Anki 同步服务器），**制卡设备本身不必装 Anki、不必在线、不必切 app**。

来源：Discord 用户反馈（e-ink 设备切 app 痛苦、个人电脑做不到 24/7 常开、AnkiMobile 不支持批量加卡、AnkiDroid 的 sync-on-add 漏媒体）。

## 已核实的外部事实

- AnkiWeb 用户协议（Ankitects Pty Ltd，Last updated 2018-10-17）「Access to the Service」：
  同步只对 Anki / AnkiMobile / AnkiDroid / AnkiUniversal 开放，「does not currently allow access from browser extensions or other third-party clients」，
  并保留「suspend or remove your access」的权利。风险落在**用户账号**上。
- 自建同步服务器（官方 `anki --syncserver` / `anki-sync-server`）不受该协议约束；官方桌面 2.1.57+、AnkiMobile、AnkiDroid 2.16+ 都可配置自定义同步地址（Anki 手册 sync-server 一节）。
- 同步协议 v11：增量同步要求本地持有完整 collection；空库首次只能整库下载；schema 变更（增删字段/模板）强制整库同步；单媒体文件上限 100MB；collection 超过 2GB 整库同步失败。
- rslib 许可证 AGPL-3.0-or-later；Fushi 为 GPL-3.0。

## 决策（用户 2026-09-28 拍板）

1. 三期都做。
2. Fushi 作为同步客户端连 AnkiWeb 时**如实标识为 fushi**（版本串 `fushi,<版本>,<平台>`），不冒充官方客户端；AnkiWeb 若拒绝如实标识的客户端，则该端点不可用，不做绕过。
3. 连 AnkiWeb 是**用户显式开启**的选项，开启时明示「违反 AnkiWeb 条款、账号可能被封停」；自建服务器直接可用。
4. 不做 `fushi-anki-bridge`（远端制卡已有 `mineForward` 通道）；不把活库放进云盘同步目录。

## 数据安全硬规则（所有期共用）

- **永不整库上传**。服务器要求整库同步时 Fushi 只下载。
- 卡片先落本地待发队列，**确认送达后才出队**；被迫整库下载后，重放尚未送达的卡。
- 只加卡，不增删字段/模板（避免 schema 变更触发整库同步）。
- 首次接入前检查库体积，接近 2GB 时提示。

## 第 1 期：本地待发制卡队列

- 一张卡 = 一条**创建后不可变**的记录：id、来源设备、创建时间，以及**未渲染**的制卡请求（`ForwardedMinePayload`：弹窗字段 JSON + 上下文文本 + 全部媒体字节）。
  补发时按**执行补发的那台设备当时的** Anki 配置（牌组、笔记类型、字段映射）渲染——这正是第 2 期「由落地设备按自己的配置落卡」需要的语义；
  代价是入队后切 Profile / 换牌组，卡会落到新配置里。
- 状态：`pending` → `sending` → 出队（送达或 Anki 判重复）；`failed`（Anki 拒收，记录原因，等用户重试 / 删除）。
  进程在 `sending` 中途退出，下次补发按 `pending` 处理——重放若已落卡，Anki 会判重复，照样出队。
- 入队时机：只收**确定没送到**的失败（`connectionRefused`、`pairedDeviceUnreachable`）；
  `connectionTimeout` / `connectionUnknown`（含 AnkiConnect「提交结果未知」）可能已落卡，仍按失败报给用户，不自动重发。
  「批量制卡」开启时一律入队、不碰后端。
- 补发时机：直接制卡成功（说明后端可达）后、app 回前台时自动补发，串行、遇不可达即停；
  AnkiMobile（`switchesAppPerNote`）绝不自动补发——用户点「全部发送」拉起一张，行留在 `sending`；
  只有 `fushi://ankiSuccess` 回跳（词条对得上）才出队并拉起下一张，队列清空后才打开 `anki://x-callback-url/sync`。
  用户在 AnkiMobile 里取消（没有回跳）卡不丢，下次「全部发送」重发它。回前台对 AnkiMobile 不做任何事。
- 互联转发（`mineForward`）只有「确定没送到」（无已配对设备 / 全部候选建连失败）才返回 null 进而入队；
  对端回过话或请求发出后超时抛 `RemoteMineOutcomeUnknown`（主机可能已落卡），按失败报给用户。
  互联客户端设 10 s 建连超时（`kInterconnectConnectTimeout`）：对端关机时快速以建连失败收尾（可入队），
  而不是吃满 60 s 整次超时后被当成「可能已送达」。残余风险：请求发出后连接被重置仍会被当成没送到，由主机端 Anki 查重兜底。
- AnkiMobile「正在等哪张」只看库里的 `sending` 行（不靠内存）：Fushi 被 iOS 杀掉、回跳冷启动照样确认；
  「全部发送」先核对残留 `sending` 行——后端认得（账本记过）即出队，否则退回 pending；连发链结束（发完或下一张拉不起）
  且本次确认过至少一张时打开 sync。词条为空的卡回跳不带参数、无法确认，只能手动删。
- 补发中任何意外（载荷丢失、后端违约抛异常）把该卡标 `failed`，不挡住后续卡；补发前清理孤儿载荷与半截 `.tmp`（与入队共用一把 I/O 锁）。
- 入队后弹窗按钮走 `MinePopupResult.queued()`（画 ✓、不回查 Anki），视频页与「看完再制卡」队列同口径。
- 实现：仓库层装饰器 `PendingMiningAnkiRepository`（最外层，包住自动重排），公共委派基类 `DelegatingAnkiRepository`
  （委派清单只写一次）；载荷复用 `ForwardedMinePayload` 与 `forwarded_mine_codec.dart`（与互联转发同一套打包 / 还原）；
  表 `pending_mine_queue`（schema v114，设备本地）+ `<support>/pending_mine_queue/<id>.json`。
- 统计口径：入队按「已收下」处理（清草稿、画 ✓、计入制卡统计与句子历史）；补发时若被 Anki 判重复，统计会多算一张。
- UI：Anki 设置页「批量制卡」开关、「待发卡片」入口（张数）→ 列表（全部发送 / 失败重试 / 删除）。
- 已知未覆盖：直接调用 `createAnkiRepository()` 绕过 provider 的入口（Windows 全局查词浮窗、Android 悬浮词典、galgame 制卡）不经过队列。

## 第 2 期：队列接入现有同步 + 落地设备

**不进聚合快照**（调研结论：旧端按类型化字段重序列化会丢未知段，经旧互联 host 的记录传不出去；
快照每台设备全量上传合并后的并集，载荷会被复制 N 份且每次变化全量重传）。改走 `SyncAssetStore` 的独立命名空间
`__pending_mines__`（云与互联同一套资产层），全部是**写一次**的文件、没有合并逻辑，旧端根本不碰这个命名空间：

- `landing.json`：落地设备认领 `{deviceId, deviceName, claimedAt}`；只有一份，`claimedAt` 大者胜（后打开「本机落地」的设备胜）。
  设置存 `SyncRepository` 的设备本地偏好 `sync_pending_mine_landing_claimed_at`（登记进 `deviceLocalPrefKeys`，随备份换设备会出现两台落地设备）。
- `<id>.json`：一张待发卡 `{id, createdAt, expression, reading, originDeviceId, payload}`（payload 即 `ForwardedMinePayload` JSON），由制卡设备写。
  **没有任何设备认领落地时不上传**——没人要的卡不外流，每轮同步只多一次 `listChildren`。
- `<id>.landed.json`：落地回执，落地设备交给 Anki 后写，并撤掉 `<id>.json`；制卡设备看到回执删本地行与回执。
- 本地表：`originDeviceId`（null = 本机制的）、`uploaded`、状态 `landed`（已交给 Anki / 用户已删，但远端还有记录待清理，不在待发列表显示）。
  交给 Anki 时：本机制且没上传过的直接出队；否则标 `landed` 由下一轮中转清远端。用户删除已上传的卡同理（`discard`）。
- 制卡设备自己先把卡交给了本机 Anki：下一轮撤远端记录；落地设备发现记录已撤就删掉手上那份，不再落。
- 挂载点：`SyncOrchestrator` 完整 sweep 在删除墓碑之后跑 `PendingMineRelay.run(backend)`，失败只记 `report.errors`。
  落地设备收到新卡经进程级广播 `PendingMineRelay.arrivals` 通知根组件（持有 Riverpod ref）补发。
- 重复落地兜底：落地后、写回执前进程被杀会再落一次，由落地设备 Anki 查重判重复、按已送达出队。
- 已知小泄漏：制卡设备在回执写出前已删掉该行时，回执无人清理（几十字节，可接受）。
- 认领为**每台设备一份** `landing.<deviceId>.json`（只写 / 删自己那份，读时取 `claimedAt` 最大者）：关掉开关即撤销；
  避免多台设备抢写同一文件、Google Drive 同名重复文件。命名空间登记为同步保留目录（`isReservedSyncFolderName`），
  本机没认领且没有要中转的行时一个请求都不发、连目录都不建。
- 收敛：上传前先落库 `uploaded`、处理回执前先落库 `landed`，`markDelivered` 按库里此刻的行判断；
  单张卡读取 / 上传 / 删除失败只记错误不打断本轮；单张卡超过 9 MB（各后端 JSON 读取上限 10 MB）不走中转并标 failed 说明原因。
- 落地设备易主：新落地设备认领的那一轮就收下远端记录；老落地设备下一轮交出手上还没交的卡。
  这两轮之间两边都持有同一张卡，若恰好都补发会各落一次，由 Anki 查重兜底。
- **桌面 app 当互联主机时不当落地设备**（见第 3b 期「为什么 app 主机不做目录落地」）；与它配对的手机改用
  「制卡到 Fushi 互联服务端」（主机不在线时卡先进手机的待发队列，连上自动补发）。无头服务端可以当（第 3b 期）。
- 落地的卡按**落地设备自己的** Anki 配置（牌组 / 笔记类型 / 字段映射）渲染。

## 第 3 期：Fushi 作为 Anki 同步客户端（官方 rslib）

- 形态：独立子进程 `fushi-anki-sync`（Rust，依赖官方 `anki` crate），stdin/stdout JSON 行协议；AGPL 义务限于该程序，随包附源码链接。
- 先落在 fushi_server（Linux / Windows），作为「落地后端」之一：读取待发记录 → 写本地 collection → 同步到 AnkiWeb 或自建服务器；之后再评估编入 app。
- 端点：自建服务器 URL；AnkiWeb（显式开启 + 风险提示）。
- 版本串如实标识 fushi；整库同步只下载；同步成功才出队。

### 2026-09-28 原型实测（anki 26.09.3，commit 29bb700b）

- git 依赖 `anki = { git = "https://github.com/ankitects/anki", tag = "26.09.3", features = ["rustls"] }` 可在外部 crate 编译；cargo 自动拉子模块。
  构建需要 `protoc`（官方钉 v31.1，`PROTOC` 指定），不需要 Python / TS。`rustls` feature 必开（reqwest 默认无 TLS）。
- Windows x64 release（`opt-level="z"`、LTO、strip、`panic=abort`）产物 13.9 MB。
- 已对本机官方 sync server 实测：登录 → 加卡 → 增量同步 → 媒体同步 → 另一新库拉到卡与媒体、查重命中。
- API：`CollectionBuilder::new(path).with_desktop_media_paths().build()`、`sync_login`（返回的 `SyncAuth.endpoint` 为 None，需调用方回填）、
  `normal_sync`、`full_download`（消费 collection，之后须重开）、`media().add_file`、`sync_media`、`add_note`、`note_fields_check`（第一字段 + notetype 查重）。全部 async，需 tokio。
- 版本串：`rslib/src/version.rs` 的长串 `anki,{ver} ({buildhash}),{platform}` 与短串 `{ver},{buildhash},{os}` 编译期写死，
  如实标识 fushi 必须 vendor rslib 并改这两处 `format!`（`[patch."https://github.com/ankitects/anki"]`）。自建服务器不校验版本串，AnkiWeb 服务端闭源、行为未知。
- endpoint 填根 URL（不带 `/sync/`），库自行拼 `sync/`、`msync/`；308 时 `SyncOutput.new_endpoint` 需持久化。
- **坑 1**：新建本地库对空服务器首次同步返回 NoChanges 而 schema 未对齐，之后一加卡就要求整库同步且 `download_ok=false`，永远推不上去。
  解法：新库在加卡前无条件 `full_download` 一次（空服务器也可下载）。
- **坑 2**：本地有未推送的卡时遇到整库同步，`full_download` 会静默丢弃这些卡（已复现）。
  所以卡片真相源必须是 Fushi 的待发队列：只有同步成功后才出队；整库下载后重放未出队的卡。

### 第 3b 期（已做）

- **app「Anki 同步客户端」后端**（`AnkiSyncClientRepository`，桌面、本机带 helper 时出现）：Anki 设置 › 连接面板
  「Anki 同步（无需安装 Anki）」开关 + 登录（自建地址或留空为 AnkiWeb，AnkiWeb 先弹条款风险确认）。
  凭据（hkey，不存密码）只落 `<support>/anki_sync/account.json`，不进偏好 / 备份 / 跨设备同步；数据目录跟着用户可配的数据根走。
  切换后端不清牌组 / 字段映射（两边是同一份库、写卡只认名字），刷新后按名字对回。
- **未同步日志**（`fushi_engine/anki_sync/anki_sync_journal.dart`，两轮审查返工后的规则）：
  - 先写日志再写本地库；加卡失败回滚日志条目。
  - **出日志的唯一判据**：一次同步成功之后，立刻用 helper 的 `existing_notes` 核对这张卡的 (note id, guid)
    确实在本地库里（不比字段内容：rslib 写库时会删控制字符、转 NFC，内容比较会把在库的卡永远认成不在）——同步成功 = 本地库里的一切都在服务器上（或本来就是从服务器拉下来的）。
    不在的（被整库下载冲掉、helper 在整库下载后的媒体同步里出错、从没写进去）一律重新写进去再同步，
    不靠「我以为写进去了」的记账。第一轮代号 / 同步中途标记方案被复审指出「整库下载成功后媒体同步失败」
    仍会丢卡，已由此判据取代。
  - helper 的 `sync` 在牌组集合同步成功后，媒体同步失败只作为 `media_error` 附带返回，不让整条命令失败——
    否则已经推上服务器的卡不出日志，之后在别的设备删掉 / 改掉它，Fushi 会把它复活。
  - 本地库目录里的 `downloaded` 只表示「整库下载完成过」：没有它的库（新建 / 下载失败留下的空库）先整库下载。
  - 写回失败的条目标 `lastError`、下次重试，不挡会话；状态里带失败张数与原因（设置页 / WebUI 显示）。
  - 没有 note id 的条目（撞上同步只进了日志、或写日志后进程被杀）写回前用 `find_notes`（`dupe:`，与 Anki
    查重同口径）兜底；有 note id 的按 id 判断，「允许重复」的卡不会被重复写。
  - 同步 / 下载进行中（首次可能要拉整个媒体库）：查重直接放行、加卡只进日志，结束时补进本地库再同步。
  - helper 死了自动换新进程；关闭会话时有请求在飞就直接结束 helper 进程（整库下载原子替换、加卡有事务，杀进程安全），
    不排在长同步后面，之后不再拉起。
  - 账号分开存「用户填的服务器」与「当前分片地址」（AnkiWeb 308），同账号重登只换凭据；换账号期间制卡直接报错。
  - 有未同步的卡时拒绝换账号；退出要用户确认放弃这些卡。加卡后 5 秒去抖同步；启动与回前台补一次。
  - 已知：本地库会镜像服务器上的完整媒体目录（官方客户端同样如此），首次同步可能很慢、占空间。
- **helper 新命令 `find_notes`**（`dupe:` 搜索）：`findMatchingNotes`（点 ✓ 反查）可用，首字段带 HTML 也能命中。
- **渲染零 Flutter 化**：`BaseAnkiRepository` 的渲染整段搬进 `AnkiNoteComposer` mixin，媒体命名搬进 `anki_media_naming.dart`，
  都进 `fushi_anki_core`；同步客户端的「渲染 → 查重 → 写库」是 `AnkiSyncMiner`，app 后端与服务端共用一份。
- **无头服务端当落地设备**（`fushi_server/lib/src/anki_landing.dart`）：`PendingMineStore` / `PendingMineRelay` 搬进
  fushi_engine；`LocalDirectoryAssetStore` 让服务端直接对自己磁盘上的 `<sync-data>/fushi-data/__pending_mines__/`
  跑**同一份**中转协议（认领 / 收卡 / 回执 / 易主零新协议代码），收下的卡还原媒体后经 `AnkiSyncMiner` 写库、同步。
  WebDAV PUT 非原子：读到半截 JSON 当不存在、下一轮再读。字段映射空时卡留着等（不标失败）。关落地立刻撤认领
  （主机从不制卡，中转层不会顺带撤）。WebUI 新增 Anki 页；admin API `/api/admin/anki*`。
- **CI**：composite action 装钉版 Rust 1.97.1 + protoc v31.1（SHA-256 校验）；Windows / macOS（universal）app、
  Linux / Windows 服务端随包 `fushi-anki-sync` + AGPL `fushi-anki-sync.SOURCE.txt`；PR 检查三平台 debug 构建。

#### 为什么 app 主机不做目录落地

中转层收尾时，对本机收下的每张别人的卡检查「当前这个 store 里记录还在不在」，不在就当制卡设备已撤回、删行。
桌面 app 若同时是互联主机、又经云盘等后端同步，两路中转共用同一张待发表：从主机目录收下的卡在云盘那一路看来
「记录不在」，会在落地前被删。要支持得给行记来源通道（schema 改动）。而 app 主机的场景已被
「制卡到 Fushi 互联服务端」+ 待发队列覆盖（主机不在线时卡在手机上等），所以不做。无头服务端只有目录这一路，没有这个问题。

## 验证

- 第 1 期：队列仓储单测（入队/出队/状态迁移/媒体复制）、后端不可达自动入队的 widget/单元测试、Drift 迁移测试。
- 第 2 期：合并与墓碑单测、旧客户端保留未知记录的兼容测试。
- 第 3 期：对本机官方 `anki-sync-server` 的端到端：登录 → 首次整库下载 → 加卡 → 增量同步 → 官方客户端可见。
  **已做**（`packages/fushi_engine/test/anki_sync_e2e_test.dart`，正式代码 + 真实 helper + 官方 anki-sync-server 26.09.3）：
  设备 A 登录 → 整库下载 → 带媒体加卡 → 同步；设备 B 从零登录拉到同一张卡与媒体。服务器日志里客户端身份为
  `fushi-0.1.0,26.09.3,windows`。
- 第 3b 期：会话日志 / 重放 / 整库上传被拦的单测（假 helper，含变异实测）；app 后端渲染单测；
  服务端落地的「手机上传 → 主机落地 → 回执 → 手机出队」集成测试（真实 store + relay，本地目录资产层）；
  服务端 `ServerAnkiLanding` 单测（映射为空不标失败，经变异实测）。未做：真机、CI 上的实际构建（workflow 未在 CI 跑过）。
